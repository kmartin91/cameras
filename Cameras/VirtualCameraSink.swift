import CoreMediaIO
import CoreVideo
import os.log

private let sinkLog = Logger(subsystem: "studio.kma.Cameras", category: "sink")

final class VirtualCameraSink {
    private let lock = NSLock()
    private var deviceID: CMIODeviceID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var connected = false

    private let monitorQueue = DispatchQueue(label: "studio.kma.cameras.sink.monitor", qos: .utility)
    private var onStateChange: ((_ connected: Bool, _ watching: Bool) -> Void)?
    private var watchedDevice: CMIODeviceID?
    private var watchListener: CMIOObjectPropertyListenerBlock?

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    func start(onStateChange: @escaping (_ connected: Bool, _ watching: Bool) -> Void) {
        monitorQueue.async {
            self.onStateChange = onStateChange
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, self.monitorQueue) { [weak self] _, _ in
                self?.rescanNow()
            }
            if status != noErr {
                sinkLog.error("start: échec du listener de devices (\(status))")
            }
            self.rescanNow()
        }
    }

    func rescan() {
        monitorQueue.async { self.rescanNow() }
    }

    private func rescanNow() {
        guard let (device, sink) = Self.locateSink() else {
            removeWatchListener()
            lock.lock()
            let wasConnected = connected
            if wasConnected { CMIODeviceStopStream(deviceID, sinkStreamID) }
            connected = false
            queue = nil
            deviceID = 0
            lock.unlock()
            if wasConnected { sinkLog.notice("rescan: caméra virtuelle disparue") }
            onStateChange?(false, false)
            return
        }
        lock.lock()
        let needsConnect = !connected || device != deviceID
        lock.unlock()
        if needsConnect {
            connectSink(device: device, sink: sink)
        }
        installWatchListener(on: device)
        onStateChange?(isConnected, Self.readClientsWatching(device) ?? false)
    }

    private func installWatchListener(on device: CMIODeviceID) {
        guard watchedDevice != device else { return }
        removeWatchListener()
        var address = Self.clientsAddress()
        guard CMIOObjectHasProperty(device, &address) else { return }
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onStateChange?(self.isConnected, Self.readClientsWatching(device) ?? false)
        }
        if CMIOObjectAddPropertyListenerBlock(device, &address, monitorQueue, listener) == noErr {
            watchedDevice = device
            watchListener = listener
        } else {
            sinkLog.error("installWatchListener: échec sur le device \(device)")
        }
    }

    private func removeWatchListener() {
        guard let device = watchedDevice, let listener = watchListener else { return }
        var address = Self.clientsAddress()
        CMIOObjectRemovePropertyListenerBlock(device, &address, monitorQueue, listener)
        watchedDevice = nil
        watchListener = nil
    }

    private func connectSink(device: CMIODeviceID, sink: CMIOStreamID) {
        var queueOut: Unmanaged<CMSimpleQueue>?
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, refCon, &queueOut) == noErr,
              let newQueue = queueOut?.takeRetainedValue(),
              CMIODeviceStartStream(device, sink) == noErr else {
            sinkLog.error("connectSink: échec de connexion au device \(device)")
            return
        }
        lock.lock()
        if connected { CMIODeviceStopStream(deviceID, sinkStreamID) }
        deviceID = device
        sinkStreamID = sink
        queue = newQueue
        connected = true
        lock.unlock()
        sinkLog.notice("connectSink: connecté au device \(device)")
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let currentQueue = queue
        lock.unlock()
        guard let currentQueue else { return }
        guard CMSimpleQueueGetCount(currentQueue) < CMSimpleQueueGetCapacity(currentQueue) else { return }

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format = format else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }
        let retained = Unmanaged.passRetained(sampleBuffer)
        if CMSimpleQueueEnqueue(currentQueue, element: retained.toOpaque()) != noErr {
            retained.release()
        }
    }

    private static func clientsAddress() -> CMIOObjectPropertyAddress {
        return CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(0x6B616374),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func readClientsWatching(_ device: CMIODeviceID) -> Bool? {
        var address = clientsAddress()
        guard CMIOObjectHasProperty(device, &address) else { return nil }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else { return nil }
        var used: UInt32 = 0
        if dataSize == UInt32(MemoryLayout<UInt32>.size) {
            var value: UInt32 = 0
            guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &value) == noErr else { return nil }
            return value != 0
        }
        if dataSize == UInt32(MemoryLayout<UInt64>.size) {
            var value: UInt64 = 0
            guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &value) == noErr else { return nil }
            return value != 0
        }
        return nil
    }

    private static func locateSink() -> (CMIODeviceID, CMIOStreamID)? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        guard count > 0 else { return nil }
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &devices) == noErr else { return nil }

        for device in devices where name(of: device) == "Cameras" {
            if let sink = sinkStream(of: device) {
                return (device, sink)
            }
        }
        return nil
    }

    private static func name(of device: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func sinkStream(of device: CMIODeviceID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        guard count >= 2 else { return nil }
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &streams) == noErr else { return nil }
        return streams[1]
    }
}
