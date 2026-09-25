import SystemExtensions
import os.log

private let extensionLog = Logger(subsystem: "studio.kma.Cameras", category: "extension")

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

    enum Installation: Equatable {
        case unknown
        case missing
        case enabled(version: String, build: String)
        case disabled
        case awaitingApproval
        case uninstalling
    }

    private enum Kind: String {
        case activation
        case deactivation
        case properties
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var installation: Installation = .unknown
    var onActivated: (() -> Void)?

    private var pending: [ObjectIdentifier: (request: OSSystemExtensionRequest, kind: Kind)] = [:]
    private var synchronizing = false

    private var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "virtualCameraInstalled") }
        set { UserDefaults.standard.set(newValue, forKey: "virtualCameraInstalled") }
    }

    private static var bundledBuild: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension")
        return Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String
    }

    func install() {
        wanted = true
        state = .installing
        submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .activation)
    }

    func reinstall() {
        wanted = true
        state = .installing
        extensionLog.notice("reinstall: désactivation puis réactivation")
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .deactivation)
    }

    func synchronize() {
        synchronizing = true
        refresh()
    }

    func refresh() {
        guard !pending.values.contains(where: { $0.kind == .properties }) else { return }
        submit(.propertiesRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .properties)
    }

    private func submit(_ request: OSSystemExtensionRequest, _ kind: Kind) {
        pending[ObjectIdentifier(request)] = (request, kind)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func found(_ id: ObjectIdentifier, _ result: Installation) {
        pending[id] = nil
        installation = result
        extensionLog.notice("état: \(String(describing: result), privacy: .public)")
        guard synchronizing else { return }
        synchronizing = false
        switch result {
        case .missing, .uninstalling:
            guard wanted else { return }
            extensionLog.notice("synchronize: caméra virtuelle absente, réinstallation")
            install()
        case .enabled(_, let build):
            guard build != Self.bundledBuild else { return }
            extensionLog.notice("synchronize: mise à niveau de l'extension \(build, privacy: .public) → \(Self.bundledBuild ?? "?", privacy: .public)")
            submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .activation)
        case .awaitingApproval:
            state = .needsApproval
        case .disabled, .unknown:
            break
        }
    }

    private func finished(_ id: ObjectIdentifier, _ result: OSSystemExtensionRequest.Result) {
        guard let kind = pending.removeValue(forKey: id)?.kind else { return }
        switch kind {
        case .deactivation:
            extensionLog.notice("deactivation: \(result == .completed ? "terminée" : "effective au redémarrage", privacy: .public)")
            submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .activation)
        case .activation:
            wanted = true
            if result == .willCompleteAfterReboot {
                state = .needsReboot
            } else {
                state = .active
                onActivated?()
            }
            refresh()
        case .properties:
            break
        }
    }

    private func failed(_ id: ObjectIdentifier, _ message: String) {
        guard let kind = pending.removeValue(forKey: id)?.kind else { return }
        extensionLog.error("\(kind.rawValue, privacy: .public): échec (\(message, privacy: .public))")
        switch kind {
        case .deactivation:
            submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .activation)
        case .activation:
            state = .failed(message)
            refresh()
        case .properties:
            installation = .unknown
            guard synchronizing else { return }
            synchronizing = false
            if wanted {
                submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .activation)
            }
        }
    }

    private nonisolated static func installation(from properties: [OSSystemExtensionProperties]) -> Installation {
        if properties.contains(where: { $0.isAwaitingUserApproval }) { return .awaitingApproval }
        if let enabled = properties.first(where: { $0.isEnabled && !$0.isUninstalling }) {
            return .enabled(version: enabled.bundleShortVersion, build: enabled.bundleVersion)
        }
        if properties.contains(where: { $0.isUninstalling }) { return .uninstalling }
        return properties.isEmpty ? .missing : .disabled
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        Task { @MainActor in self.finished(id, result) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let id = ObjectIdentifier(request)
        let message = error.localizedDescription
        let superseded = (error as NSError).domain == OSSystemExtensionErrorDomain && (error as NSError).code == OSSystemExtensionError.requestSuperseded.rawValue
        Task { @MainActor in
            if superseded {
                self.pending[id] = nil
            } else {
                self.failed(id, message)
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let id = ObjectIdentifier(request)
        let result = Self.installation(from: properties)
        Task { @MainActor in self.found(id, result) }
    }
}
