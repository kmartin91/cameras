import AppIntents

struct SelectCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Sélectionner une caméra"
    static let description = IntentDescription("Bascule la caméra active de Cameras.")

    @Parameter(title: "Numéro de caméra (1-9)")
    var index: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        if let manager = CameraManager.shared, manager.devices.indices.contains(index - 1) {
            manager.select(manager.devices[index - 1])
        }
        return .result()
    }
}

struct ToggleFreezeIntent: AppIntent {
    static let title: LocalizedStringResource = "Figer/défiger l'image"
    static let description = IntentDescription("Fige ou défige le flux diffusé par Cameras.")

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraManager.shared?.frozen.toggle()
        return .result()
    }
}

struct ToggleStandbyIntent: AppIntent {
    static let title: LocalizedStringResource = "Écran d'attente"
    static let description = IntentDescription("Affiche ou masque l'écran d'attente de Cameras.")

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraManager.shared?.standbyActive.toggle()
        return .result()
    }
}

struct SwapPiPIntent: AppIntent {
    static let title: LocalizedStringResource = "Échanger caméra et PiP"
    static let description = IntentDescription("Échange la caméra active et l'incrustation de Cameras.")

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraManager.shared?.swapWithPiP()
        return .result()
    }
}

struct RecallSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Rappeler une scène"
    static let description = IntentDescription("Rappelle une scène enregistrée de Cameras.")

    @Parameter(title: "Numéro de scène (1-4)")
    var slot: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraManager.shared?.recallScene(slot)
        return .result()
    }
}

struct SnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Capturer une image"
    static let description = IntentDescription("Enregistre l'image diffusée par Cameras en PNG sur le Bureau.")

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraManager.shared?.captureSnapshot()
        return .result()
    }
}
