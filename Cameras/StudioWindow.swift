import AppKit
import AVFoundation
import SwiftUI

enum StudioCommand {
    case program(Int)
    case pip(Int)
    case pipOff
    case swap
    case pipCorner
    case pipSize
    case recallScene(Int)
    case saveScene(Int)
    case freeze
    case standby
    case mirror
    case orientation
    case spin
    case spinSpeed
    case spinDirection
    case transitionStyle
    case transitionDuration
    case watermark
    case snapshot
    case zoom(Double)
    case pan(Double, Double)
    case brightness(Double)
    case warmth(Double)
    case resetFraming
    case resetColor
    case rageQuit

    private static let digitKeyCodes: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    var repeats: Bool {
        switch self {
        case .zoom, .pan, .brightness, .warmth: return true
        default: return false
        }
    }

    init?(event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        if let digit = Self.digitKeyCodes[event.keyCode] {
            switch (digit, shift, option) {
            case (0, _, false): self = .pipOff
            case (1...4, true, true): self = .saveScene(digit)
            case (1...4, false, true): self = .recallScene(digit)
            case (1...9, true, false): self = .pip(digit - 1)
            case (1...9, false, false): self = .program(digit - 1)
            default: return nil
            }
            return
        }
        switch event.keyCode {
        case 123: self = option ? .warmth(-0.1) : .pan(-0.1, 0)
        case 124: self = option ? .warmth(0.1) : .pan(0.1, 0)
        case 125: self = option ? .brightness(-0.05) : shift ? .zoom(-0.1) : .pan(0, -0.1)
        case 126: self = option ? .brightness(0.05) : shift ? .zoom(0.1) : .pan(0, 0.1)
        case 49: self = .freeze
        case 51, 117: self = option ? .resetColor : .resetFraming
        case 69: self = .zoom(0.1)
        case 78: self = .zoom(-0.1)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "b": self = .standby
            case "m": self = .mirror
            case "o": self = .orientation
            case "r": self = shift ? .spinSpeed : option ? .spinDirection : .spin
            case "t": self = shift ? .transitionDuration : .transitionStyle
            case "c": self = shift ? .pipSize : .pipCorner
            case "p": self = .swap
            case "l": self = .watermark
            case "s": self = .snapshot
            case "x": self = .rageQuit
            case "+", "=": self = .zoom(0.1)
            case "-", "_": self = .zoom(-0.1)
            default: return nil
            }
        }
    }
}

@MainActor
final class StudioDesk: ObservableObject {
    static let pipScales = [0.2, 0.28, 0.36]
    static let transitionDurations = [0.3, 0.45, 0.6]
    static let cornerCycle: [PiPCorner] = [.bottomRight, .bottomLeft, .topLeft, .topRight]

    @Published private(set) var toast: String?
    @Published var floating: Bool {
        didSet {
            UserDefaults.standard.set(floating, forKey: "studioFloating")
            onFloatingChange?(floating)
        }
    }

    let manager: CameraManager
    var onFloatingChange: (@MainActor (Bool) -> Void)?
    private var toastTask: Task<Void, Never>?

    init(manager: CameraManager) {
        self.manager = manager
        floating = UserDefaults.standard.bool(forKey: "studioFloating")
    }

    func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        guard let command = StudioCommand(event: event) else { return true }
        if !event.isARepeat || command.repeats {
            perform(command)
        }
        return true
    }

    func perform(_ command: StudioCommand) {
        switch command {
        case .program(let index):
            guard let device = camera(at: index) else { return }
            manager.select(device)
            flash("PGM · \(device.localizedName)")
        case .pip(let index):
            guard let device = camera(at: index), device.uniqueID != manager.activeID else { return }
            let enabling = manager.pipID != device.uniqueID
            manager.pipID = enabling ? device.uniqueID : nil
            flash(enabling ? "PiP · \(device.localizedName)" : "PiP · OFF")
        case .pipOff:
            manager.pipID = nil
            flash("PiP · OFF")
        case .swap:
            guard manager.pipID != nil else { return }
            manager.swapWithPiP()
            flash("PGM ⇄ PiP")
        case .pipCorner:
            manager.pipCorner = Self.next(in: Self.cornerCycle, after: manager.pipCorner)
            flash("PiP · \(manager.pipCorner.label)")
        case .pipSize:
            manager.pipScale = Self.next(in: Self.pipScales, after: manager.pipScale)
            flash("PiP · \(Self.pipSizeLabel(manager.pipScale))")
        case .recallScene(let slot):
            guard manager.sceneLabel(slot) != nil else { return }
            manager.recallScene(slot)
            flash(String(localized: "Scène \(slot)"))
        case .saveScene(let slot):
            manager.saveScene(slot)
            flash(String(localized: "Scène \(slot) enregistrée"))
        case .freeze:
            manager.frozen.toggle()
            flash(String(localized: "Figer l'image"), manager.frozen)
        case .standby:
            manager.standbyActive.toggle()
            flash(String(localized: "Écran d'attente"), manager.standbyActive)
        case .mirror:
            manager.mirror.toggle()
            flash(String(localized: "Miroir"), manager.mirror)
        case .orientation:
            manager.rotation = (manager.rotation + 90) % 360
            flash("\(String(localized: "Rotation")) · \(manager.rotation)°")
        case .spin:
            manager.spinning.toggle()
            flash(String(localized: "Rotation continue"), manager.spinning)
        case .spinSpeed:
            manager.spinSpeed = Self.next(in: SpinSpeed.allCases, after: manager.spinSpeed)
            flash("\(String(localized: "Vitesse")) · \(manager.spinSpeed.label)")
        case .spinDirection:
            manager.spinClockwise.toggle()
            flash(manager.spinClockwise ? String(localized: "Sens horaire") : String(localized: "Sens anti-horaire"))
        case .transitionStyle:
            manager.transitionStyle = Self.next(in: TransitionStyle.allCases, after: manager.transitionStyle)
            flash("\(String(localized: "Transition")) · \(manager.transitionStyle.label)")
        case .transitionDuration:
            manager.transitionDuration = Self.next(in: Self.transitionDurations, after: manager.transitionDuration)
            flash("\(String(localized: "Durée de transition")) · \(Int(manager.transitionDuration * 1000)) ms")
        case .watermark:
            guard manager.watermarkImageSet else {
                flash(String(localized: "Aucune image de filigrane"))
                return
            }
            manager.watermarkEnabled.toggle()
            flash(String(localized: "Filigrane"), manager.watermarkEnabled)
        case .snapshot:
            manager.captureSnapshot()
            flash(String(localized: "Capture enregistrée sur le Bureau"))
        case .zoom(let delta):
            manager.adjustZoom(by: delta)
            flash(String(format: "Zoom %.1f×", manager.zoom))
        case .pan(let dx, let dy):
            guard manager.zoom > 1.001 else {
                flash(String(localized: "Zoomez d'abord pour recadrer"))
                return
            }
            manager.panX = Self.nudge(manager.panX, by: manager.mirror ? -dx : dx, limit: 1)
            manager.panY = Self.nudge(manager.panY, by: dy, limit: 1)
        case .brightness(let delta):
            manager.brightness = Self.nudge(manager.brightness, by: delta, limit: 0.5)
            flash("\(String(localized: "Luminosité")) \(String(format: "%+.2f", manager.brightness))")
        case .warmth(let delta):
            manager.warmth = Self.nudge(manager.warmth, by: delta, limit: 1)
            flash("\(String(localized: "Température")) \(String(format: "%+.1f", manager.warmth))")
        case .resetFraming:
            manager.resetFraming()
            flash(String(localized: "Réinitialiser le cadrage"))
        case .resetColor:
            manager.resetColor()
            flash(String(localized: "Réinitialiser la couleur"))
        case .rageQuit:
            let firing = manager.rageQuitArmed
            manager.armOrFireRageQuit()
            flash(firing ? "RAGE QUIT" : String(localized: "Rage quit armé — rappuyez sur X"))
        }
    }

    static func pipSizeLabel(_ scale: Double) -> String {
        switch scale {
        case ..<0.24: return String(localized: "Petite")
        case ..<0.32: return String(localized: "Moyenne")
        default: return String(localized: "Grande")
        }
    }

    private static func next<T: Equatable>(in values: [T], after current: T) -> T {
        guard let index = values.firstIndex(of: current) else { return values[0] }
        return values[(index + 1) % values.count]
    }

    private static func nudge(_ value: Double, by delta: Double, limit: Double) -> Double {
        min(max(((value + delta) * 100).rounded() / 100, -limit), limit)
    }

    private func camera(at index: Int) -> AVCaptureDevice? {
        manager.devices.indices.contains(index) ? manager.devices[index] : nil
    }

    private func flash(_ title: String, _ on: Bool) {
        flash("\(title) · \(on ? "ON" : "OFF")")
    }

    private func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

final class StudioWindow: NSWindow {
    var onKeyDown: (@MainActor (NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    static let shared = StudioWindowController()

    private var window: StudioWindow?
    private var desk: StudioDesk?
    private var open = false

    func show(_ manager: CameraManager) {
        let desk = self.desk ?? StudioDesk(manager: manager)
        let window = self.window ?? makeWindow(desk: desk)
        self.desk = desk
        self.window = window
        if !open {
            open = true
            let host = NSHostingView(rootView: StudioView(manager: manager, desk: desk))
            host.sizingOptions = [.minSize]
            window.contentView = host
            manager.setPreviewActive(true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard open else { return }
        open = false
        window?.contentView = nil
        desk?.manager.setPreviewActive(false)
    }

    private func makeWindow(desk: StudioDesk) -> StudioWindow {
        let window = StudioWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "Régie Cameras")
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: 960, height: 640)
        window.level = desk.floating ? .floating : .normal
        window.delegate = self
        window.onKeyDown = { [weak desk] event in desk?.handle(event) ?? false }
        desk.onFloatingChange = { [weak window] floating in
            window?.level = floating ? .floating : .normal
        }
        window.center()
        window.setFrameAutosaveName("StudioWindow")
        return window
    }
}

struct StudioView: View {
    @ObservedObject var manager: CameraManager
    @ObservedObject var desk: StudioDesk
    @Environment(\.controlActiveState) private var activeState

    private var cameras: [AVCaptureDevice] { Array(manager.devices.prefix(9)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                monitor
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        effectsSection
                        transitionSection
                        framingSection
                        colorSection
                    }
                }
                .frame(width: 290)
            }
            .frame(maxHeight: .infinity)
            buses
        }
        .padding(16)
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Tally(title: "ON AIR", lit: manager.onAir)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "PGM · \(name(of: manager.activeID) ?? "—")")
                    .font(.system(size: 15, weight: .bold))
                Text(verbatim: "PiP · \(name(of: manager.pipID) ?? "OFF")")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.6))
            }
            Spacer()
            keyboardStatus
                .font(.system(size: 12, weight: .medium))
            Toggle(isOn: $desk.floating) {
                Image(systemName: desk.floating ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help("Toujours au premier plan")
            rageQuitPanel
        }
    }

    @ViewBuilder
    private var keyboardStatus: some View {
        if activeState == .key {
            Label("Clavier actif", systemImage: "keyboard")
                .foregroundColor(.green)
        } else {
            Label("Clavier inactif — cliquez dans la fenêtre", systemImage: "keyboard")
                .foregroundColor(.orange)
        }
    }

    private var monitor: some View {
        ZStack(alignment: .topLeading) {
            PreviewView(manager: manager)
            HStack(spacing: 6) {
                if manager.frozen { Badge(title: "FIGÉ", color: .blue) }
                if manager.standbyActive { Badge(title: "ATTENTE", color: .orange) }
                if manager.spinning { Badge(title: "ROTATION", color: .purple) }
                if manager.mirror { Badge(title: "MIROIR", color: .gray) }
                if manager.rageQuitting { Badge(title: "RAGE QUIT", color: .red) }
            }
            .padding(10)
            if let toast = desk.toast {
                Text(toast)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(Rectangle().stroke(manager.onAir ? Color.red : Color(white: 0.25), lineWidth: manager.onAir ? 3 : 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionTitle("EFFETS")
            KeyRow(keys: ["␣"], title: "Figer l'image", lit: manager.frozen) { desk.perform(.freeze) }
            KeyRow(keys: ["B"], title: "Écran d'attente", lit: manager.standbyActive) { desk.perform(.standby) }
            KeyRow(keys: ["M"], title: "Miroir", lit: manager.mirror) { desk.perform(.mirror) }
            KeyRow(keys: ["O"], title: "Rotation", value: "\(manager.rotation)°") { desk.perform(.orientation) }
            KeyRow(keys: ["R"], title: "Rotation continue", lit: manager.spinning) { desk.perform(.spin) }
            KeyRow(keys: ["⇧R"], title: "Vitesse", value: manager.spinSpeed.label) { desk.perform(.spinSpeed) }
            KeyRow(keys: ["⌥R"], title: "Sens", value: manager.spinClockwise ? String(localized: "Horaire") : String(localized: "Anti-horaire")) { desk.perform(.spinDirection) }
            KeyRow(keys: ["L"], title: "Filigrane", lit: manager.watermarkImageSet ? manager.watermarkEnabled : nil) { desk.perform(.watermark) }
            KeyRow(keys: ["S"], title: "Capturer l'image (PNG)") { desk.perform(.snapshot) }
        }
    }

    private var transitionSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionTitle("TRANSITION")
            KeyRow(keys: ["T"], title: "Style", value: manager.transitionStyle.label) { desk.perform(.transitionStyle) }
            KeyRow(keys: ["⇧T"], title: "Durée", value: "\(Int(manager.transitionDuration * 1000)) ms") { desk.perform(.transitionDuration) }
        }
    }

    private var framingSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionTitle("CADRAGE")
            KeyRow(keys: ["+", "−"], title: "Zoom", value: String(format: "%.1f×", manager.zoom))
            KeyRow(keys: ["←↑↓→"], title: "Recadrer")
            KeyRow(keys: ["⌫"], title: "Réinitialiser le cadrage") { desk.perform(.resetFraming) }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionTitle("COULEUR")
            KeyRow(keys: ["⌥↑", "⌥↓"], title: "Luminosité", value: String(format: "%+.2f", manager.brightness))
            KeyRow(keys: ["⌥←", "⌥→"], title: "Température", value: String(format: "%+.1f", manager.warmth))
            KeyRow(keys: ["⌥⌫"], title: "Réinitialiser la couleur") { desk.perform(.resetColor) }
        }
    }

    private var buses: some View {
        VStack(alignment: .leading, spacing: 10) {
            busRow("PROGRAMME") {
                if cameras.isEmpty {
                    Text("Aucune caméra détectée")
                        .foregroundColor(Color(white: 0.5))
                }
                ForEach(Array(cameras.enumerated()), id: \.element.uniqueID) { index, device in
                    BusButton(key: "\(index + 1)", title: device.localizedName, lit: device.uniqueID == manager.activeID ? .red : nil) {
                        desk.perform(.program(index))
                    }
                }
            }
            busRow("INCRUSTATION") {
                BusButton(key: "0", title: String(localized: "Aucune"), lit: manager.pipID == nil ? .green : nil) {
                    desk.perform(.pipOff)
                }
                ForEach(Array(cameras.enumerated()), id: \.element.uniqueID) { index, device in
                    BusButton(key: "⇧\(index + 1)", title: device.localizedName, lit: device.uniqueID == manager.pipID ? .green : nil, enabled: device.uniqueID != manager.activeID) {
                        desk.perform(.pip(index))
                    }
                }
                BusButton(key: "P", title: String(localized: "Échanger"), enabled: manager.pipID != nil) {
                    desk.perform(.swap)
                }
                BusButton(key: "C", title: manager.pipCorner.label) {
                    desk.perform(.pipCorner)
                }
                BusButton(key: "⇧C", title: StudioDesk.pipSizeLabel(manager.pipScale)) {
                    desk.perform(.pipSize)
                }
            }
            busRow("SCÈNES") {
                ForEach(1...HotKeys.sceneCount, id: \.self) { slot in
                    BusButton(key: "⌥\(slot)", title: manager.sceneLabel(slot) ?? String(localized: "Vide"), enabled: manager.sceneLabel(slot) != nil) {
                        desk.perform(.recallScene(slot))
                    }
                }
                Text("⌥⇧ + chiffre : enregistrer")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
            }
        }
    }

    private var rageQuitPanel: some View {
        Button {
            desk.perform(.rageQuit)
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: "RAGE QUIT")
                    .font(.system(size: 17, weight: .black))
                if manager.rageQuitArmed {
                    Text("Rappuyez sur X")
                } else {
                    Text("X deux fois")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(manager.rageQuitArmed || manager.rageQuitting ? Color.red : Color(red: 0.32, green: 0.04, blue: 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.rageQuitting)
    }

    private func busRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(Color(white: 0.5))
                .frame(width: 104, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    content()
                }
            }
        }
    }

    private func name(of id: String?) -> String? {
        manager.devices.first { $0.uniqueID == id }?.localizedName
    }
}

private struct Tally: View {
    let title: String
    let lit: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundColor(lit ? .white : Color(white: 0.4))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.red : Color(white: 0.14)))
    }
}

private struct Badge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .heavy))
            .foregroundColor(Color(white: 0.5))
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.34), lineWidth: 1))
    }
}

private struct KeyRow: View {
    let keys: [String]
    let title: LocalizedStringKey
    var lit: Bool? = nil
    var value: String? = nil
    var action: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KeyCap(label: $0) }
            }
            .frame(width: 70, alignment: .leading)
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let value {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
            }
            if let lit {
                Circle()
                    .fill(lit ? Color.green : Color(white: 0.22))
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(lit == true ? Color.green.opacity(0.14) : Color(white: 0.11)))
        .contentShape(Rectangle())
    }
}

private struct BusButton: View {
    let key: String
    let title: String
    var lit: Color? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(key)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(lit == nil ? Color(white: 0.55) : .white)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: 120, height: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit ?? Color(white: 0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: lit == nil ? 0.26 : 0.85), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

extension TransitionStyle {
    var label: String {
        switch self {
        case .dissolve: return String(localized: "Fondu")
        case .cut: return String(localized: "Cut")
        case .slide: return String(localized: "Slide")
        case .wipe: return String(localized: "Volet")
        case .punch: return String(localized: "Punch")
        case .blur: return String(localized: "Fondu flouté")
        }
    }
}

extension PiPCorner {
    var label: String {
        switch self {
        case .bottomRight: return String(localized: "En bas à droite")
        case .bottomLeft: return String(localized: "En bas à gauche")
        case .topRight: return String(localized: "En haut à droite")
        case .topLeft: return String(localized: "En haut à gauche")
        }
    }
}

extension SpinSpeed {
    var label: String {
        switch self {
        case .slow: return String(localized: "Lente")
        case .medium: return String(localized: "Moyenne")
        case .fast: return String(localized: "Rapide")
        }
    }
}
