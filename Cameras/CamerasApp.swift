import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .camerasCommand, object: urls)
    }
}

extension HotkeyModifiers {
    var eventModifiers: EventModifiers {
        switch self {
        case .controlOption: return [.control, .option]
        case .commandOption: return [.command, .option]
        case .controlCommand: return [.control, .command]
        }
    }
}

@main
struct CamerasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = CameraManager()

    private var statusIcon: String {
        if manager.rageQuitArmed || manager.rageQuitting { return "flame.fill" }
        if manager.standbyActive { return "moon.circle.fill" }
        if manager.frozen { return "pause.circle.fill" }
        if manager.onAir { return "record.circle" }
        return "video.fill"
    }

    var body: some Scene {
        MenuBarExtra("Cameras", systemImage: statusIcon) {
            MenuContent(manager: manager)
        }
        Window("Aperçu Cameras", id: "preview") {
            PreviewPane(manager: manager)
                .frame(minWidth: 320, minHeight: 180)
                .onAppear { manager.setPreviewActive(true) }
                .onDisappear { manager.setPreviewActive(false) }
        }
        .defaultSize(width: 960, height: 540)
        Window("Aperçu compact", id: "hud") {
            PreviewView(manager: manager)
                .frame(minWidth: 200, minHeight: 112)
                .background(FloatingWindowConfigurator())
                .onAppear { manager.setPreviewActive(true) }
                .onDisappear { manager.setPreviewActive(false) }
        }
        .defaultSize(width: 320, height: 180)
    }
}

struct MenuContent: View {
    @ObservedObject var manager: CameraManager
    @Environment(\.openWindow) private var openWindow

    private var mods: EventModifiers { manager.hotkeyModifiers.eventModifiers }

    var body: some View {
        if manager.denied {
            Text("Accès caméra refusé — Réglages Système › Confidentialité")
        } else if manager.devices.isEmpty {
            Text("Aucune caméra détectée")
        }
        ForEach(Array(manager.devices.enumerated()), id: \.element.uniqueID) { index, device in
            Button {
                manager.select(device)
            } label: {
                if device.uniqueID == manager.activeID {
                    Text("✓ \(device.localizedName)")
                } else {
                    Text(device.localizedName)
                }
            }
            .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: mods) : nil)
        }
        if manager.onAir {
            Text("🔴 On air — un client lit la caméra virtuelle")
        } else if !manager.devices.isEmpty, !manager.capturing {
            Text("Caméra en veille — reprend dès qu'un client regarde")
        }
        Divider()
        Toggle("Figer l'image", isOn: $manager.frozen)
            .keyboardShortcut("0", modifiers: mods)
        Toggle("Écran d'attente", isOn: $manager.standbyActive)
            .keyboardShortcut("i", modifiers: mods)
        Button("Capturer l'image (PNG)") {
            manager.captureSnapshot()
        }
        .keyboardShortcut("s", modifiers: mods)
        Button("Rage quit") {
            manager.rageQuit()
        }
        .keyboardShortcut("x", modifiers: mods)
        .disabled(manager.rageQuitting)
        sceneMenu
        if manager.devices.count > 1 {
            if manager.pipID != nil {
                Button("Échanger caméra ↔ PiP") {
                    manager.swapWithPiP()
                }
                .keyboardShortcut("p", modifiers: mods)
            }
            Menu("Incrustation (PiP)") {
                Picker("Caméra", selection: $manager.pipID) {
                    Text("Aucune").tag(String?.none)
                    ForEach(manager.devices.filter { $0.uniqueID != manager.activeID }, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                Picker("Position", selection: $manager.pipCorner) {
                    Text("En bas à droite").tag(PiPCorner.bottomRight)
                    Text("En bas à gauche").tag(PiPCorner.bottomLeft)
                    Text("En haut à droite").tag(PiPCorner.topRight)
                    Text("En haut à gauche").tag(PiPCorner.topLeft)
                }
                Picker("Taille", selection: $manager.pipScale) {
                    Text("Petite").tag(0.2)
                    Text("Moyenne").tag(0.28)
                    Text("Grande").tag(0.36)
                }
            }
        }
        Divider()
        Menu("Caméra active") {
            Toggle("Miroir", isOn: $manager.mirror)
            Picker("Rotation", selection: $manager.rotation) {
                Text("0°").tag(0)
                Text("90°").tag(90)
                Text("180°").tag(180)
                Text("270°").tag(270)
            }
            Toggle("Rotation continue", isOn: $manager.spinning)
            Picker("Vitesse de rotation", selection: $manager.spinSpeed) {
                ForEach(SpinSpeed.allCases, id: \.self) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            Toggle("Sens horaire", isOn: $manager.spinClockwise)
            Button("Zoom +") { manager.adjustZoom(by: 0.1) }
            Button("Zoom −") { manager.adjustZoom(by: -0.1) }
            Button("Réinitialiser le cadrage") { manager.resetFraming() }
            Button("Réinitialiser la couleur") { manager.resetColor() }
            Text("Zoom \(manager.zoom, specifier: "%.1f")× — cadrage et couleur dans l'aperçu")
        }
        Menu("Réglages") {
            Picker("Transition", selection: $manager.transitionStyle) {
                Text("Fondu").tag(TransitionStyle.dissolve)
                Text("Cut").tag(TransitionStyle.cut)
                Text("Slide").tag(TransitionStyle.slide)
                Text("Volet").tag(TransitionStyle.wipe)
                Text("Punch").tag(TransitionStyle.punch)
                Text("Fondu flouté").tag(TransitionStyle.blur)
            }
            if manager.transitionStyle != .cut {
                Picker("Durée de transition", selection: $manager.transitionDuration) {
                    Text("300 ms").tag(0.3)
                    Text("450 ms").tag(0.45)
                    Text("600 ms").tag(0.6)
                }
            }
            Picker("Résolution de sortie", selection: $manager.outputHeight) {
                Text("720p").tag(720)
                Text("1080p").tag(1080)
            }
            Picker("Fréquence de sortie", selection: $manager.frameRate) {
                Text("30 ips").tag(30)
                Text("24 ips").tag(24)
                Text("15 ips").tag(15)
            }
            Picker("Raccourcis", selection: $manager.hotkeyModifiers) {
                ForEach(HotkeyModifiers.allCases, id: \.self) { modifiers in
                    Text(modifiers.symbols).tag(modifiers)
                }
            }
            watermarkMenu
            if manager.standbyImageSet {
                Button("Changer l'image d'attente…") { manager.chooseStandbyImage() }
                Button("Retirer l'image d'attente") { manager.removeStandbyImage() }
            } else {
                Button("Choisir une image d'attente…") { manager.chooseStandbyImage() }
            }
            Toggle("Lancer à la connexion", isOn: $manager.launchAtLogin)
        }
        Divider()
        Button("Mode Studio (régie)") {
            StudioWindowController.shared.show(manager)
        }
        .keyboardShortcut("r", modifiers: mods)
        Button("Ouvrir l'aperçu") {
            openWindow(id: "preview")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Aperçu compact (flottant)") {
            openWindow(id: "hud")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        VirtualCameraMenu(manager: manager)
        Divider()
        Text(versionLabel)
        Button("Quitter") {
            NSApp.terminate(nil)
        }
    }

    private var sceneMenu: some View {
        Menu("Scènes") {
            ForEach(1...HotKeys.sceneCount, id: \.self) { slot in
                if let label = manager.sceneLabel(slot) {
                    Button("Scène \(slot) — \(label)") {
                        manager.recallScene(slot)
                    }
                    .keyboardShortcut(KeyboardShortcut(KeyEquivalent(Character(String(slot))), modifiers: mods.union(.shift)))
                }
            }
            Menu("Enregistrer la scène actuelle") {
                ForEach(1...HotKeys.sceneCount, id: \.self) { slot in
                    Button("Dans la scène \(slot)") {
                        manager.saveScene(slot)
                    }
                }
            }
        }
    }

    private var watermarkMenu: some View {
        Menu("Filigrane") {
            if manager.watermarkImageSet {
                Toggle("Afficher le filigrane", isOn: $manager.watermarkEnabled)
                Picker("Position", selection: $manager.watermarkCorner) {
                    Text("En bas à droite").tag(PiPCorner.bottomRight)
                    Text("En bas à gauche").tag(PiPCorner.bottomLeft)
                    Text("En haut à droite").tag(PiPCorner.topRight)
                    Text("En haut à gauche").tag(PiPCorner.topLeft)
                }
                Picker("Taille", selection: $manager.watermarkScale) {
                    Text("Petite").tag(0.1)
                    Text("Moyenne").tag(0.15)
                    Text("Grande").tag(0.22)
                }
                Button("Changer l'image du filigrane…") { manager.chooseWatermarkImage() }
                Button("Retirer le filigrane") { manager.removeWatermarkImage() }
            } else {
                Button("Choisir l'image du filigrane…") { manager.chooseWatermarkImage() }
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Cameras v\(version) (build \(build)) — \(Bundle.main.bundlePath)"
    }
}

struct VirtualCameraMenu: View {
    @ObservedObject var manager: CameraManager
    @ObservedObject var systemExtension: SystemExtensionManager

    init(manager: CameraManager) {
        self.manager = manager
        self.systemExtension = manager.systemExtension
    }

    var body: some View {
        if manager.virtualCameraRunning {
            Text("Caméra virtuelle active — choisir « Cameras » dans Teams/Zoom")
        } else {
            status
        }
        if showsReinstall {
            Button("Réinstaller la caméra virtuelle") {
                manager.reinstallVirtualCamera()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch systemExtension.state {
        case .installing:
            Text("Installation de la caméra virtuelle…")
        case .needsApproval:
            approvalButton
        case .needsReboot:
            Text("Redémarrez le Mac pour activer la caméra virtuelle")
        case .failed(let message):
            Button("Échec caméra virtuelle : \(message) — réessayer") {
                manager.reinstallVirtualCamera()
            }
        case .idle, .active:
            switch systemExtension.installation {
            case .unknown:
                Text("Vérification de la caméra virtuelle…")
            case .missing:
                Button("Installer la caméra virtuelle") {
                    manager.installVirtualCamera()
                }
            case .awaitingApproval:
                approvalButton
            case .disabled:
                Button("Caméra virtuelle désactivée — l'activer dans Réglages Système…") {
                    openExtensionSettings()
                }
            case .uninstalling:
                Text("Caméra virtuelle en cours de suppression — redémarrez le Mac")
            case .enabled(let version, let build):
                Text("Caméra virtuelle \(version) (\(build)) installée mais non détectée")
            }
        }
    }

    private var showsReinstall: Bool {
        switch systemExtension.state {
        case .installing, .failed:
            return false
        default:
            return systemExtension.installation != .missing
        }
    }

    private var approvalButton: some View {
        Button("Autoriser dans Réglages Système › Général › Connexion…") {
            openExtensionSettings()
        }
    }

    private func openExtensionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
