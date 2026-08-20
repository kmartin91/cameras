import Foundation
import CoreMediaIO

let providerSource = CameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
