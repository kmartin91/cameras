import SystemExtensions

@MainActor
final class SystemExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let identifier = "studio.kma.Cameras.CameraExtension"

    enum State: Equatable {
        case idle
        case installing
        case needsApproval
        case active
        case needsReboot
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var installed = UserDefaults.standard.bool(forKey: "virtualCameraInstalled")
    var onActivated: (() -> Void)?

    func install() {
        state = .installing
        submitActivation()
    }

    func activateIfInstalled() {
        submitActivation()
    }

    private func submitActivation() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.state = .active
                self.markInstalled()
                self.onActivated?()
            case .willCompleteAfterReboot:
                self.state = .needsReboot
                self.markInstalled()
            @unknown default:
                self.state = .active
                self.markInstalled()
            }
        }
    }

    private func markInstalled() {
        installed = true
        UserDefaults.standard.set(true, forKey: "virtualCameraInstalled")
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}
