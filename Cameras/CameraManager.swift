@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import IOKit.audio
import ServiceManagement
import UniformTypeIdentifiers
import os.log

private let camLog = Logger(subsystem: "studio.kma.Cameras", category: "capture")

extension Notification.Name {
    static let camerasCommand = Notification.Name("studio.kma.Cameras.command")
}

struct CameraScene: Codable {
    var cameraID: String
    var cameraName: String
    var pipID: String?
    var pipCorner: String
    var pipScale: Double
    var mirror: Bool
    var zoom: Double
    var panX: Double
    var panY: Double
    var rotation: Int
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var warmth: Double
}

@MainActor
final class CameraManager: ObservableObject {
    static private(set) weak var shared: CameraManager?
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var activeID: String?
    @Published var denied = false
    @Published private(set) var virtualCameraRunning = false
    @Published private(set) var capturing = false
    @Published private(set) var onAir = false
    @Published private(set) var standbyImageSet = false
    @Published var frozen = false {
        didSet {
            pipeline.setFrozen(frozen)
            updateCaptureState()
        }
    }
    @Published var standbyActive = false {
        didSet {
            pipeline.setStandby(standbyActive)
            updateCaptureState()
        }
    }
    @Published var mirror = false {
        didSet { persistActiveTransform() }
    }
    @Published var zoom = 1.0 {
        didSet { persistActiveTransform() }
    }
    @Published var panX = 0.0 {
        didSet { persistActiveTransform() }
    }
    @Published var panY = 0.0 {
        didSet { persistActiveTransform() }
    }
    @Published var rotation = 0 {
        didSet { persistActiveTransform() }
    }
    @Published var brightness = 0.0 {
        didSet { persistActiveTransform() }
    }
    @Published var contrast = 1.0 {
        didSet { persistActiveTransform() }
    }
    @Published var saturation = 1.0 {
        didSet { persistActiveTransform() }
    }
    @Published var warmth = 0.0 {
        didSet { persistActiveTransform() }
    }
    @Published private(set) var scenes: [Int: CameraScene] = [:]
    @Published var hotkeyModifiers: HotkeyModifiers {
        didSet {
            UserDefaults.standard.set(hotkeyModifiers.rawValue, forKey: "hotkeyModifiers")
            HotKeys.register(modifiers: hotkeyModifiers)
        }
    }
    @Published private(set) var watermarkImageSet = false
    @Published var watermarkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(watermarkEnabled, forKey: "watermarkEnabled")
            pushWatermark()
        }
    }
    @Published var watermarkCorner: PiPCorner {
        didSet {
            UserDefaults.standard.set(watermarkCorner.rawValue, forKey: "watermarkCorner")
            pushWatermark()
        }
    }
    @Published var watermarkScale: Double {
        didSet {
            UserDefaults.standard.set(watermarkScale, forKey: "watermarkScale")
            pushWatermark()
        }
    }
    @Published var pipID: String? {
        didSet {
            UserDefaults.standard.set(pipID, forKey: "pipCamera")
            restartPiPSession()
        }
    }
    @Published var pipCorner: PiPCorner {
        didSet {
            UserDefaults.standard.set(pipCorner.rawValue, forKey: "pipCorner")
            pipeline.setPiPLayout(corner: pipCorner, scale: pipScale)
        }
    }
    @Published var pipScale: Double {
        didSet {
            UserDefaults.standard.set(pipScale, forKey: "pipScale")
            pipeline.setPiPLayout(corner: pipCorner, scale: pipScale)
        }
    }
    @Published var outputHeight: Int {
        didSet {
            UserDefaults.standard.set(outputHeight, forKey: "outputHeight")
            pipeline.setOutputSize(CGSize(width: outputHeight * 16 / 9, height: outputHeight))
            restartActiveSession()
        }
    }
    @Published var frameRate: Int {
        didSet {
            UserDefaults.standard.set(frameRate, forKey: "frameRate")
            applyFrameRates()
        }
    }
    @Published var transitionDuration: Double {
        didSet {
            pipeline.setTransitionDuration(transitionDuration)
            UserDefaults.standard.set(transitionDuration, forKey: "transitionDuration")
        }
    }
    @Published var transitionStyle: TransitionStyle {
        didSet {
            pipeline.setTransitionStyle(transitionStyle)
            UserDefaults.standard.set(transitionStyle.rawValue, forKey: "transitionStyle")
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    let pipeline = Pipeline()
    let systemExtension = SystemExtensionManager()

    private let discovery: AVCaptureDevice.DiscoverySession
    private var observation: NSKeyValueObservation?
    private var activeSession: AVCaptureSession?
    private var fadingSession: AVCaptureSession?
    private var pipSession: AVCaptureSession?
    private let virtualCamera = VirtualCameraSink()
    private var previewConsumers = 0
    private var clientsWatching = false
    private var thermalThrottled = false
    private var watermarkImage: CIImage?

    init() {
        let defaults = UserDefaults.standard
        transitionDuration = defaults.object(forKey: "transitionDuration") as? Double ?? 0.45
        transitionStyle = TransitionStyle(rawValue: defaults.string(forKey: "transitionStyle") ?? "") ?? .dissolve
        outputHeight = defaults.object(forKey: "outputHeight") as? Int ?? 720
        frameRate = defaults.object(forKey: "frameRate") as? Int ?? 30
        pipID = defaults.string(forKey: "pipCamera")
        pipCorner = PiPCorner(rawValue: defaults.string(forKey: "pipCorner") ?? "") ?? .bottomRight
        pipScale = defaults.object(forKey: "pipScale") as? Double ?? 0.28
        hotkeyModifiers = HotkeyModifiers(rawValue: defaults.string(forKey: "hotkeyModifiers") ?? "") ?? .controlOption
        watermarkEnabled = defaults.object(forKey: "watermarkEnabled") as? Bool ?? false
        watermarkCorner = PiPCorner(rawValue: defaults.string(forKey: "watermarkCorner") ?? "") ?? .bottomRight
        watermarkScale = defaults.object(forKey: "watermarkScale") as? Double ?? 0.15
        launchAtLogin = SMAppService.mainApp.status == .enabled

        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)

        Self.shared = self
        loadScenes()

        pipeline.setTransitionDuration(transitionDuration)
        pipeline.setTransitionStyle(transitionStyle)
        pipeline.setOutputSize(CGSize(width: outputHeight * 16 / 9, height: outputHeight))
        pipeline.setPiPLayout(corner: pipCorner, scale: pipScale)
        loadStandbyImage()
        loadWatermarkImage()
        pipeline.onTransitionEnded = { [weak self] in
            Task { @MainActor in
                self?.fadingSession?.stopRunning()
                self?.fadingSession = nil
            }
        }
        HotKeys.install({ [weak self] index in
            Task { @MainActor in
                guard let self else { return }
                switch index {
                case HotKeys.freezeIndex:
                    self.frozen.toggle()
                case HotKeys.swapIndex:
                    self.swapWithPiP()
                case HotKeys.standbyIndex:
                    self.standbyActive.toggle()
                case HotKeys.snapshotIndex:
                    self.captureSnapshot()
                case HotKeys.sceneBaseIndex...(HotKeys.sceneBaseIndex + HotKeys.sceneCount - 1):
                    self.recallScene(index - HotKeys.sceneBaseIndex + 1)
                default:
                    guard self.devices.indices.contains(index) else { return }
                    self.select(self.devices[index])
                }
            }
        }, modifiers: hotkeyModifiers)
        NotificationCenter.default.addObserver(forName: .camerasCommand, object: nil, queue: .main) { [weak self] note in
            let urls = note.object as? [URL] ?? []
            Task { @MainActor in
                for url in urls { self?.handleCommand(url) }
            }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            let throttled = state == .serious || state == .critical
            Task { @MainActor in
                guard let self, throttled != self.thermalThrottled else { return }
                self.thermalThrottled = throttled
                camLog.notice("thermalState: \(throttled ? "réduction à 15 ips" : "retour à la fréquence normale")")
                self.applyFrameRates()
            }
        }
        systemExtension.onActivated = { [weak self] in
            self?.virtualCamera.rescan()
        }
        virtualCamera.start { [weak self] connected, watching in
            Task { @MainActor in
                self?.virtualCameraStateChanged(connected: connected, watching: watching)
            }
        }
        systemExtension.activateIfInstalled()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                self.denied = !granted
                guard granted else { return }
                self.observation = self.discovery.observe(\.devices, options: [.initial]) { [weak self] _, _ in
                    Task { @MainActor in self?.devicesChanged() }
                }
            }
        }
    }

    func select(_ device: AVCaptureDevice) {
        guard device.uniqueID != activeID || activeSession == nil else { return }
        if device.uniqueID == pipID { pipID = nil }
        activeID = device.uniqueID
        UserDefaults.standard.set(device.uniqueID, forKey: "preferredCamera")
        restoreTransform(for: device.uniqueID)
        guard shouldCapture else { return }
        startSession(for: device)
        if pipSession == nil, pipID != nil { restartPiPSession() }
    }

    func swapWithPiP() {
        guard let currentPip = pipID, let target = devices.first(where: { $0.uniqueID == currentPip }) else { return }
        let previousActive = activeID
        select(target)
        if let previousActive, previousActive != activeID {
            pipID = previousActive
        }
    }

    func adjustZoom(by delta: Double) {
        zoom = min(max(zoom + delta, 1), 2)
    }

    func resetFraming() {
        zoom = 1
        panX = 0
        panY = 0
    }

    func resetColor() {
        brightness = 0
        contrast = 1
        saturation = 1
        warmth = 0
    }

    func setPreviewActive(_ active: Bool) {
        previewConsumers = max(0, previewConsumers + (active ? 1 : -1))
        camLog.notice("setPreviewActive(\(active)) consumers=\(self.previewConsumers) clientsWatching=\(self.clientsWatching)")
        updateCaptureState()
    }

    func saveScene(_ slot: Int) {
        guard let activeID, let device = devices.first(where: { $0.uniqueID == activeID }) else { return }
        scenes[slot] = CameraScene(
            cameraID: activeID,
            cameraName: device.localizedName,
            pipID: pipID,
            pipCorner: pipCorner.rawValue,
            pipScale: pipScale,
            mirror: mirror,
            zoom: zoom,
            panX: panX,
            panY: panY,
            rotation: rotation,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            warmth: warmth)
        persistScenes()
    }

    func recallScene(_ slot: Int) {
        guard let scene = scenes[slot], let device = devices.first(where: { $0.uniqueID == scene.cameraID }) else { return }
        pipCorner = PiPCorner(rawValue: scene.pipCorner) ?? .bottomRight
        pipScale = scene.pipScale
        select(device)
        mirror = scene.mirror
        zoom = scene.zoom
        panX = scene.panX
        panY = scene.panY
        rotation = scene.rotation
        brightness = scene.brightness
        contrast = scene.contrast
        saturation = scene.saturation
        warmth = scene.warmth
        if let pip = scene.pipID, pip != scene.cameraID, devices.contains(where: { $0.uniqueID == pip }) {
            if pipID != pip { pipID = pip }
        } else if pipID != nil {
            pipID = nil
        }
    }

    func sceneLabel(_ slot: Int) -> String? {
        scenes[slot]?.cameraName
    }

    private func persistScenes() {
        let payload = Dictionary(uniqueKeysWithValues: scenes.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: "scenes")
        }
    }

    private func loadScenes() {
        guard let data = UserDefaults.standard.data(forKey: "scenes"),
              let payload = try? JSONDecoder().decode([String: CameraScene].self, from: data) else { return }
        scenes = Dictionary(uniqueKeysWithValues: payload.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    func captureSnapshot() {
        pipeline.snapshotBuffer { buffer in
            guard let buffer else { return }
            let context = CIContext(options: [.cacheIntermediates: false])
            let image = CIImage(cvPixelBuffer: buffer)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let url = desktop.appendingPathComponent("Cameras \(formatter.string(from: Date())).png")
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            do {
                try context.writePNGRepresentation(of: image, to: url, format: .BGRA8, colorSpace: colorSpace)
                camLog.notice("snapshot: \(url.lastPathComponent)")
                DispatchQueue.main.async { NSSound(named: "Pop")?.play() }
            } catch {
                camLog.error("snapshot: échec (\(error.localizedDescription))")
            }
        }
    }

    func installVirtualCamera() {
        systemExtension.install()
    }


    func chooseStandbyImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = Self.standbyImageURL
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            camLog.error("chooseStandbyImage: copie impossible (\(error.localizedDescription))")
            return
        }
        loadStandbyImage()
    }

    func removeStandbyImage() {
        try? FileManager.default.removeItem(at: Self.standbyImageURL)
        standbyImageSet = false
        pipeline.setStandbyImage(nil)
    }

    private static var standbyImageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cameras", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("standby-image")
    }

    private func loadStandbyImage() {
        let image = CIImage(contentsOf: Self.standbyImageURL)
        standbyImageSet = image != nil
        pipeline.setStandbyImage(image)
    }

    func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = Self.watermarkImageURL
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            camLog.error("chooseWatermarkImage: copie impossible (\(error.localizedDescription))")
            return
        }
        loadWatermarkImage()
        watermarkEnabled = true
    }

    func removeWatermarkImage() {
        try? FileManager.default.removeItem(at: Self.watermarkImageURL)
        watermarkImage = nil
        watermarkImageSet = false
        watermarkEnabled = false
    }

    private static var watermarkImageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cameras", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watermark-image")
    }

    private func loadWatermarkImage() {
        watermarkImage = CIImage(contentsOf: Self.watermarkImageURL)
        watermarkImageSet = watermarkImage != nil
        pushWatermark()
    }

    private func pushWatermark() {
        pipeline.setWatermark(watermarkEnabled ? watermarkImage : nil, corner: watermarkCorner, scale: watermarkScale)
    }


    private func handleCommand(_ url: URL) {
        guard url.scheme?.lowercased() == "cameras" else { return }
        let action = url.host?.lowercased() ?? ""
        let argument = url.pathComponents.count > 1 ? url.pathComponents[1].lowercased() : nil
        switch action {
        case "select":
            if let argument, let index = Int(argument), devices.indices.contains(index - 1) {
                select(devices[index - 1])
            }
        case "freeze":
            frozen = boolValue(argument, current: frozen)
        case "standby":
            standbyActive = boolValue(argument, current: standbyActive)
        case "swap":
            swapWithPiP()
        case "pip":
            if argument == "none" || argument == "off" {
                pipID = nil
            } else if let argument, let index = Int(argument), devices.indices.contains(index - 1) {
                let id = devices[index - 1].uniqueID
                if id != activeID { pipID = id }
            }
        case "scene":
            if let argument, let slot = Int(argument), (1...HotKeys.sceneCount).contains(slot) {
                if url.pathComponents.count > 2, url.pathComponents[2].lowercased() == "save" {
                    saveScene(slot)
                } else {
                    recallScene(slot)
                }
            }
        case "snapshot":
            captureSnapshot()
        default:
            camLog.error("handleCommand: action inconnue \(url.absoluteString)")
        }
    }

    private func boolValue(_ argument: String?, current: Bool) -> Bool {
        switch argument {
        case "on": return true
        case "off": return false
        default: return !current
        }
    }


    private var shouldCapture: Bool { (previewConsumers > 0 || clientsWatching) && !frozen && !standbyActive }

    private var currentTransform: SourceTransform {
        SourceTransform(
            mirror: mirror,
            zoom: zoom,
            panX: panX,
            panY: panY,
            rotation: rotation,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            warmth: warmth)
    }

    private var effectiveFrameRate: Double { Double(thermalThrottled ? min(frameRate, 15) : frameRate) }

    private var pipFrameRate: Double { min(effectiveFrameRate, 15) }

    private func applyFrameRates() {
        if activeSession != nil, let activeID, let device = devices.first(where: { $0.uniqueID == activeID }) {
            Self.capFrameRate(device, target: effectiveFrameRate)
        }
        if pipSession != nil, let pipID, let device = devices.first(where: { $0.uniqueID == pipID }) {
            Self.capFrameRate(device, target: pipFrameRate)
        }
    }

    private func virtualCameraStateChanged(connected: Bool, watching: Bool) {
        if connected != virtualCameraRunning {
            virtualCameraRunning = connected
            if connected {
                pipeline.setVirtualSink { [virtualCamera] buffer in virtualCamera.send(buffer) }
            } else {
                pipeline.setVirtualSink(nil)
            }
        }
        onAir = watching
        if clientsWatching != watching {
            clientsWatching = watching
            updateCaptureState()
        }
    }

    private func updateCaptureState() {
        if shouldCapture {
            if activeSession == nil, let device = devices.first(where: { $0.uniqueID == activeID }) ?? devices.first {
                if activeID != device.uniqueID {
                    activeID = device.uniqueID
                    restoreTransform(for: device.uniqueID)
                }
                startSession(for: device)
            }
            if pipSession == nil, pipID != nil {
                restartPiPSession()
            }
        } else {
            guard activeSession != nil || fadingSession != nil || pipSession != nil else { return }
            activeSession?.stopRunning()
            activeSession = nil
            fadingSession?.stopRunning()
            fadingSession = nil
            pipSession?.stopRunning()
            pipSession = nil
            pipeline.reset()
            pipeline.setPiPOutput(nil)
            capturing = false
        }
    }

    private func startSession(for device: AVCaptureDevice) {
        camLog.notice("startSession: capture démarrée sur \(device.localizedName)")
        guard let session = makeSession(for: device, preset: outputHeight == 1080 ? .hd1920x1080 : .hd1280x720) else { return }
        fadingSession?.stopRunning()
        fadingSession = activeSession
        activeSession = session.0
        capturing = true
        pipeline.activate(session.1, transform: currentTransform)
        startInBackground(session.0, device: device, rate: effectiveFrameRate)
    }

    private func restartActiveSession() {
        guard activeSession != nil, let device = devices.first(where: { $0.uniqueID == activeID }) else { return }
        activeSession?.stopRunning()
        activeSession = nil
        fadingSession?.stopRunning()
        fadingSession = nil
        pipeline.reset()
        startSession(for: device)
    }

    private func restartPiPSession() {
        pipSession?.stopRunning()
        pipSession = nil
        pipeline.setPiPOutput(nil)
        guard shouldCapture, let pipID, pipID != activeID,
              let device = devices.first(where: { $0.uniqueID == pipID }),
              let session = makeSession(for: device, preset: .vga640x480) else { return }
        pipSession = session.0
        pipeline.setPiPOutput(session.1, transform: storedTransform(for: pipID))
        startInBackground(session.0, device: device, rate: pipFrameRate)
    }

    private func makeSession(for device: AVCaptureDevice, preset: AVCaptureSession.Preset) -> (AVCaptureSession, AVCaptureVideoDataOutput)? {
        guard let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(pipeline, queue: pipeline.queue)
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        return (session, output)
    }

    private func startInBackground(_ session: AVCaptureSession, device: AVCaptureDevice, rate: Double) {
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            Self.capFrameRate(device, target: rate)
        }
    }

    private nonisolated static func capFrameRate(_ device: AVCaptureDevice, target: Double) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= target && target <= $0.maxFrameRate }),
              (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: Int32(target))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func storedTransform(for id: String) -> SourceTransform {
        let defaults = UserDefaults.standard
        return SourceTransform(
            mirror: defaults.bool(forKey: "mirror.\(id)"),
            zoom: defaults.object(forKey: "zoom.\(id)") as? Double ?? 1.0,
            panX: defaults.object(forKey: "panX.\(id)") as? Double ?? 0.0,
            panY: defaults.object(forKey: "panY.\(id)") as? Double ?? 0.0,
            rotation: defaults.object(forKey: "rotation.\(id)") as? Int ?? 0,
            brightness: defaults.object(forKey: "brightness.\(id)") as? Double ?? 0.0,
            contrast: defaults.object(forKey: "contrast.\(id)") as? Double ?? 1.0,
            saturation: defaults.object(forKey: "saturation.\(id)") as? Double ?? 1.0,
            warmth: defaults.object(forKey: "warmth.\(id)") as? Double ?? 0.0)
    }

    private func restoreTransform(for id: String) {
        let t = storedTransform(for: id)
        mirror = t.mirror
        zoom = t.zoom
        panX = t.panX
        panY = t.panY
        rotation = t.rotation
        brightness = t.brightness
        contrast = t.contrast
        saturation = t.saturation
        warmth = t.warmth
    }

    private func persistActiveTransform() {
        guard let activeID else { return }
        let defaults = UserDefaults.standard
        defaults.set(mirror, forKey: "mirror.\(activeID)")
        defaults.set(zoom, forKey: "zoom.\(activeID)")
        defaults.set(panX, forKey: "panX.\(activeID)")
        defaults.set(panY, forKey: "panY.\(activeID)")
        defaults.set(rotation, forKey: "rotation.\(activeID)")
        defaults.set(brightness, forKey: "brightness.\(activeID)")
        defaults.set(contrast, forKey: "contrast.\(activeID)")
        defaults.set(saturation, forKey: "saturation.\(activeID)")
        defaults.set(warmth, forKey: "warmth.\(activeID)")
        pipeline.updateActiveTransform(currentTransform)
    }

    private nonisolated static func isVirtualCamera(_ device: AVCaptureDevice) -> Bool {
        if device.transportType == Int32(kIOAudioDeviceTransportTypeVirtual) { return true }
        if device.uniqueID.contains("studio.kma.Cameras") || device.localizedName == "Cameras" { return true }
        return device.localizedName.localizedCaseInsensitiveContains("virtual")
    }

    private func devicesChanged() {
        devices = discovery.devices.filter { !Self.isVirtualCamera($0) }
        if let activeID, !devices.contains(where: { $0.uniqueID == activeID }) {
            self.activeID = nil
            activeSession?.stopRunning()
            activeSession = nil
            capturing = false
            pipeline.reset()
        }
        if let pipID, !devices.contains(where: { $0.uniqueID == pipID }) {
            self.pipID = nil
        }
        if activeID == nil {
            let preferred = UserDefaults.standard.string(forKey: "preferredCamera")
            if let device = devices.first(where: { $0.uniqueID == preferred }) ?? devices.first {
                select(device)
            }
        }
    }
}
