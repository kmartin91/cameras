import Foundation
import CoreMediaIO
import IOKit.audio
import CoreGraphics
import CoreText

let kFrameRate = 30
let kWidth = 1280
let kHeight = 720
let kDeviceName = "Cameras"
let kDeviceUID = "studio.kma.Cameras.virtual-device"
let kClientsWatchingProperty = CMIOExtensionProperty(rawValue: "4cc_kact_glob_0000")

class CameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormats = streamFormats
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return _streamFormats
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        (device.source as? CameraExtensionDeviceSource)?.noteSourceClient(client)
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? CameraExtensionDeviceSource else { return }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? CameraExtensionDeviceSource else { return }
        deviceSource.stopStreaming()
    }
}

class CameraExtensionStreamSink: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormats: [CMIOExtensionStreamFormat]
    private(set) var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormats = streamFormats
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return _streamFormats
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 5
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? CameraExtensionDeviceSource, let client = client else { return }
        deviceSource.startStreamingSink(client: client)
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? CameraExtensionDeviceSource else { return }
        deviceSource.stopStreamingSink()
    }
}

class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: CameraExtensionStreamSource!
    private var _streamSink: CameraExtensionStreamSink!

    private let _stateQueue = DispatchQueue(label: "studio.kma.Cameras.extension.state", qos: .userInteractive)
    private var _sourceClients = Set<UUID>()
    private var _pendingSourceClient: UUID?
    private var _streamingSinkCounter: UInt32 = 0
    private enum TimerMode { case placeholder, watchdog }
    private var _timerMode = TimerMode.placeholder
    private var _timer: DispatchSourceTimer?
    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!
    private var _placeholderWidth = Int32(kWidth)
    private var _placeholderHeight = Int32(kHeight)
    private var _frameCounter: UInt64 = 0
    private var _lastSinkTime: Double = 0
    private let _watchingLock = NSLock()
    private var _watchingValue: UInt32 = 0

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: "8A3F6C2E-2B7D-4E5A-9C11-4C1B7C0A9F33")!
        self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: kDeviceUID, source: self)

        rebuildPlaceholderResources(width: Int32(kWidth), height: Int32(kHeight))

        var videoDescription1080: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: 1920, height: 1080,
            extensions: nil, formatDescriptionOut: &videoDescription1080)

        let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        var streamFormats = [CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil)]
        if let videoDescription1080 {
            streamFormats.append(CMIOExtensionStreamFormat(
                formatDescription: videoDescription1080,
                maxFrameDuration: frameDuration,
                minFrameDuration: frameDuration,
                validFrameDurations: nil))
        }

        _streamSource = CameraExtensionStreamSource(localizedName: "Cameras.Video", streamID: UUID(), streamFormats: streamFormats, device: device)
        _streamSink = CameraExtensionStreamSink(localizedName: "Cameras.Video.Sink", streamID: UUID(), streamFormats: streamFormats, device: device)
        do {
            try device.addStream(_streamSource.stream)
            try device.addStream(_streamSink.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel, kClientsWatchingProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Cameras Virtual"
        }
        if properties.contains(kClientsWatchingProperty) {
            deviceProperties.setPropertyState(clientsWatchingState(), forProperty: kClientsWatchingProperty)
        }
        return deviceProperties
    }

    private func clientsWatchingState() -> CMIOExtensionPropertyState<AnyObject> {
        _watchingLock.lock()
        let value = _watchingValue
        _watchingLock.unlock()
        return CMIOExtensionPropertyState(value: NSNumber(value: value))
    }

    private func updateClientsWatching() {
        let value: UInt32 = _sourceClients.isEmpty ? 0 : 1
        _watchingLock.lock()
        _watchingValue = value
        _watchingLock.unlock()
        device.notifyPropertiesChanged([kClientsWatchingProperty: clientsWatchingState()])
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
    }

    func noteSourceClient(_ client: CMIOExtensionClient) {
        let clientID = client.clientID
        _stateQueue.async { self._pendingSourceClient = clientID }
    }

    func clientDisconnected(_ client: CMIOExtensionClient) {
        let clientID = client.clientID
        _stateQueue.async {
            guard self._sourceClients.remove(clientID) != nil else { return }
            if self._sourceClients.isEmpty { self.stopTimer() }
            self.updateClientsWatching()
        }
    }

    func startStreaming() {
        _stateQueue.async {
            guard self._bufferPool != nil else { return }
            if let pending = self._pendingSourceClient {
                self._sourceClients.insert(pending)
                self._pendingSourceClient = nil
            }
            self.startTimerIfNeeded()
            self.updateClientsWatching()
        }
    }

    func stopStreaming() {
        _stateQueue.async {
            if self._sourceClients.count <= 1 {
                self._sourceClients.removeAll()
                self.stopTimer()
            }
            self.updateClientsWatching()
        }
    }

    private func startTimerIfNeeded() {
        guard _timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: _stateQueue)
        timer.setEventHandler { [weak self] in
            self?.timerFired()
        }
        _timer = timer
        _timerMode = .placeholder
        scheduleTimer()
        timer.resume()
    }

    private func scheduleTimer() {
        guard let timer = _timer else { return }
        switch _timerMode {
        case .placeholder:
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(5))
        case .watchdog:
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(100))
        }
    }

    private func timerFired() {
        if sinkIsFeeding() {
            if _timerMode != .watchdog {
                _timerMode = .watchdog
                scheduleTimer()
            }
            return
        }
        if _timerMode != .placeholder {
            _timerMode = .placeholder
            scheduleTimer()
        }
        emitPlaceholder()
    }

    private func sinkIsFeeding() -> Bool {
        guard _lastSinkTime != 0 else { return false }
        let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - _lastSinkTime
        return elapsed >= 0 && elapsed < 0.4
    }

    private func stopTimer() {
        _timer?.cancel()
        _timer = nil
    }

    func startStreamingSink(client: CMIOExtensionClient) {
        _stateQueue.async {
            self._streamingSinkCounter += 1
            self.consumeBuffer(client)
        }
    }

    func stopStreamingSink() {
        _stateQueue.async {
            if self._streamingSinkCounter > 1 {
                self._streamingSinkCounter -= 1
            } else {
                self._streamingSinkCounter = 0
            }
        }
    }

    private func consumeBuffer(_ client: CMIOExtensionClient) {
        guard _streamingSinkCounter > 0 else { return }
        _streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, _ in
            guard let self = self else { return }
            self._stateQueue.async {
                if let sampleBuffer = sampleBuffer {
                    self.relaySinkBuffer(sampleBuffer, sequenceNumber: sequenceNumber)
                }
                self.consumeBuffer(client)
            }
        }
    }

    private func relaySinkBuffer(_ sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64) {
        let hostTime = UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        _lastSinkTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if _timer != nil, _timerMode != .watchdog {
            _timerMode = .watchdog
            scheduleTimer()
        }
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            if dims.width != _placeholderWidth || dims.height != _placeholderHeight {
                rebuildPlaceholderResources(width: dims.width, height: dims.height)
            }
        }
        if !_sourceClients.isEmpty {
            _streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
        }
        let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: hostTime)
        _streamSink.stream.notifyScheduledOutputChanged(output)
    }

    private func rebuildPlaceholderResources(width: Int32, height: Int32) {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width, height: height,
            extensions: nil, formatDescriptionOut: &description)
        guard let description else { return }
        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: description.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &pool)
        guard let pool else { return }
        _videoDescription = description
        _bufferPool = pool
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 6]
        _placeholderWidth = width
        _placeholderHeight = height
    }

    private func emitPlaceholder() {
        guard !_sourceClients.isEmpty, let pool = _bufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, _bufferAuxAttributes, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else { return }

        drawPlaceholder(into: pixelBuffer)
        _frameCounter += 1

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let err = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: _videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard err == noErr, let sampleBuffer = sampleBuffer else { return }
        _streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    private func drawPlaceholder(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let bars: [CGColor] = [
            CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.75, blue: 0.0, alpha: 1),
            CGColor(red: 0.0, green: 0.75, blue: 0.75, alpha: 1),
            CGColor(red: 0.0, green: 0.75, blue: 0.0, alpha: 1),
            CGColor(red: 0.75, green: 0.0, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.0, blue: 0.0, alpha: 1),
            CGColor(red: 0.0, green: 0.0, blue: 0.75, alpha: 1),
        ]
        let barWidth = w / CGFloat(bars.count)
        for (index, color) in bars.enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: h))
        }

        for _ in 0..<2500 {
            let g = CGFloat(arc4random_uniform(256)) / 255.0
            ctx.setFillColor(CGColor(red: g, green: g, blue: g, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(arc4random_uniform(UInt32(width))), y: CGFloat(arc4random_uniform(UInt32(height))), width: 2, height: 2))
        }

        let fontSize = h * 0.11
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "NO SIGNAL", attributes: attributes))
        let textBounds = CTLineGetBoundsWithOptions(line, [])
        let tx = (w - textBounds.width) / 2
        let ty = (h - textBounds.height) / 2
        let pad = fontSize * 0.5
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: tx - pad, y: ty - pad, width: textBounds.width + pad * 2, height: textBounds.height + pad * 2))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: tx, y: ty)
        CTLineDraw(line, ctx)
    }
}

class CameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraExtensionDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraExtensionDeviceSource(localizedName: kDeviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
    }

    func disconnect(from client: CMIOExtensionClient) {
        deviceSource.clientDisconnected(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "KMA Studio"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
    }
}
