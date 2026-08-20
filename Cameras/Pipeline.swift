import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

enum TransitionStyle: String, CaseIterable {
    case dissolve
    case cut
    case slide
    case wipe
    case punch
    case blur
}

enum PiPCorner: String, CaseIterable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
}

struct SourceTransform {
    var mirror = false
    var zoom = 1.0
    var panX = 0.0
    var panY = 0.0
    var rotation = 0
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0
}

final class Pipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "studio.kma.cameras.pipeline")

    var onTransitionEnded: (() -> Void)?

    private var outputSize = CGSize(width: 1280, height: 720)
    private var previewHandlers: [UUID: (CVPixelBuffer) -> Void] = [:]
    private var virtualSink: ((CVPixelBuffer) -> Void)?
    private var watermarkSource: CIImage?
    private var watermarkCorner = PiPCorner.bottomRight
    private var watermarkScale = 0.15
    private var watermarkPlaced: CIImage?
    private var activeOutput: AVCaptureVideoDataOutput?
    private var fadingOutput: AVCaptureVideoDataOutput?
    private var pipOutput: AVCaptureVideoDataOutput?
    private var activeTransform = SourceTransform()
    private var fadingTransform = SourceTransform()
    private var pipTransform = SourceTransform()
    private var fadingImage: CIImage?
    private var pipImage: CIImage?
    private var pipCorner = PiPCorner.bottomRight
    private var pipScale = 0.28
    private var transitionStart: CFTimeInterval?
    private var transitionDuration = 0.45
    private var transitionStyle = TransitionStyle.dissolve
    private var frozen = false
    private var standby = false
    private var standbyImage: CIImage?
    private var standbyBuffer: CVPixelBuffer?
    private var lastBuffer: CVPixelBuffer?
    private var heldBuffer: CVPixelBuffer?
    private var holdTimer: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private var pool: CVPixelBufferPool?
    private let poolAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary

    func activate(_ output: AVCaptureVideoDataOutput, transform: SourceTransform = SourceTransform()) {
        queue.async {
            if self.activeOutput != nil {
                self.fadingOutput = self.activeOutput
                self.fadingTransform = self.activeTransform
                self.fadingImage = nil
                self.transitionStart = nil
            }
            self.activeOutput = output
            self.activeTransform = transform
        }
    }

    func updateActiveTransform(_ transform: SourceTransform) {
        queue.async { self.activeTransform = transform }
    }

    func setPiPOutput(_ output: AVCaptureVideoDataOutput?, transform: SourceTransform = SourceTransform()) {
        queue.async {
            self.pipOutput = output
            self.pipTransform = transform
            if output == nil { self.pipImage = nil }
        }
    }

    func setPiPLayout(corner: PiPCorner, scale: Double) {
        queue.async {
            self.pipCorner = corner
            self.pipScale = scale
            self.pipImage = nil
        }
    }

    func reset() {
        queue.async {
            self.activeOutput = nil
            self.fadingOutput = nil
            self.fadingImage = nil
            self.transitionStart = nil
        }
    }

    func setOutputSize(_ size: CGSize) {
        queue.async {
            guard size != self.outputSize else { return }
            self.outputSize = size
            self.pool = nil
            self.pipImage = nil
            self.standbyBuffer = nil
            self.watermarkPlaced = nil
        }
    }

    func setTransitionDuration(_ duration: Double) {
        queue.async { self.transitionDuration = duration }
    }

    func setTransitionStyle(_ style: TransitionStyle) {
        queue.async { self.transitionStyle = style }
    }

    func setFrozen(_ frozen: Bool) {
        queue.async {
            self.frozen = frozen
            self.updateHold()
        }
    }

    func setStandby(_ standby: Bool) {
        queue.async {
            self.standby = standby
            self.updateHold()
        }
    }

    func setStandbyImage(_ image: CIImage?) {
        queue.async {
            self.standbyImage = image
            self.standbyBuffer = nil
        }
    }

    func addPreviewHandler(_ id: UUID, _ handler: @escaping (CVPixelBuffer) -> Void) {
        queue.async { self.previewHandlers[id] = handler }
    }

    func removePreviewHandler(_ id: UUID) {
        queue.async { self.previewHandlers.removeValue(forKey: id) }
    }

    func setVirtualSink(_ sink: ((CVPixelBuffer) -> Void)?) {
        queue.async { self.virtualSink = sink }
    }

    func setWatermark(_ image: CIImage?, corner: PiPCorner, scale: Double) {
        queue.async {
            self.watermarkSource = image
            self.watermarkCorner = corner
            self.watermarkScale = scale
            self.watermarkPlaced = nil
        }
    }

    func snapshotBuffer(_ completion: @escaping (CVPixelBuffer?) -> Void) {
        queue.async {
            completion(self.holdTimer != nil ? (self.heldBuffer ?? self.lastBuffer) : self.lastBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !frozen, !standby, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if output === pipOutput {
            pipImage = fill(CIImage(cvPixelBuffer: buffer), into: pipRect(), transform: pipTransform)
            return
        }
        let fullRect = CGRect(origin: .zero, size: outputSize)
        if output === fadingOutput {
            let image = fill(CIImage(cvPixelBuffer: buffer), into: fullRect, transform: fadingTransform)
            fadingImage = image
            if transitionStart == nil { emit(composite(image)) }
            return
        }
        guard output === activeOutput else { return }
        let image = fill(CIImage(cvPixelBuffer: buffer), into: fullRect, transform: activeTransform)
        var result = image
        if let fading = fadingImage, transitionStyle != .cut {
            let start = transitionStart ?? CACurrentMediaTime()
            transitionStart = start
            let progress = (CACurrentMediaTime() - start) / transitionDuration
            if progress < 1 {
                result = blend(from: fading, to: image, progress: smoothstep(progress))
            } else {
                endTransition()
            }
        } else if fadingOutput != nil {
            endTransition()
        }
        emit(composite(result))
    }


    private func updateHold() {
        if standby {
            if standbyBuffer == nil { standbyBuffer = renderStandby() }
            heldBuffer = standbyBuffer
            startHoldTimer()
        } else if frozen {
            heldBuffer = lastBuffer
            startHoldTimer()
        }
    }

    private func startHoldTimer() {
        guard holdTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 15.0, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.serveHeldFrame() }
        timer.resume()
        holdTimer = timer
    }

    private func serveHeldFrame() {
        if standby, standbyBuffer == nil {
            standbyBuffer = renderStandby()
            heldBuffer = standbyBuffer
        }
        guard let buffer = heldBuffer else { return }
        virtualSink?(buffer)
        if standby, !previewHandlers.isEmpty {
            let handlers = Array(previewHandlers.values)
            DispatchQueue.main.async { for handler in handlers { handler(buffer) } }
        }
    }

    private func renderStandby() -> CVPixelBuffer? {
        let rect = CGRect(origin: .zero, size: outputSize)
        var image = CIImage(color: .black).cropped(to: rect)
        if let standbyImage {
            image = fit(standbyImage, into: rect).composited(over: image)
        }
        guard let buffer = makePixelBuffer() else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }


    private func composite(_ image: CIImage) -> CIImage {
        var result = image
        if let pip = pipImage {
            result = pip.composited(over: result)
        }
        if let watermark = watermarkImage() {
            result = watermark.composited(over: result)
        }
        return result
    }

    private func watermarkImage() -> CIImage? {
        if let watermarkPlaced { return watermarkPlaced }
        guard let source = watermarkSource, source.extent.width > 0 else { return nil }
        let targetWidth = outputSize.width * watermarkScale
        let scale = targetWidth / source.extent.width
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let margin = (outputSize.width * 0.02).rounded()
        let x: CGFloat
        let y: CGFloat
        switch watermarkCorner {
        case .bottomRight:
            x = outputSize.width - scaled.extent.width - margin
            y = margin
        case .bottomLeft:
            x = margin
            y = margin
        case .topRight:
            x = outputSize.width - scaled.extent.width - margin
            y = outputSize.height - scaled.extent.height - margin
        case .topLeft:
            x = margin
            y = outputSize.height - scaled.extent.height - margin
        }
        let placed = scaled.transformed(by: CGAffineTransform(translationX: x - scaled.extent.minX, y: y - scaled.extent.minY))
        watermarkPlaced = placed
        return placed
    }

    private func pipRect() -> CGRect {
        let width = (outputSize.width * pipScale).rounded()
        let height = (width * 9 / 16).rounded()
        let margin = (outputSize.width * 0.02).rounded()
        let x: CGFloat
        let y: CGFloat
        switch pipCorner {
        case .bottomRight:
            x = outputSize.width - width - margin
            y = margin
        case .bottomLeft:
            x = margin
            y = margin
        case .topRight:
            x = outputSize.width - width - margin
            y = outputSize.height - height - margin
        case .topLeft:
            x = margin
            y = outputSize.height - height - margin
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func smoothstep(_ t: Double) -> Double {
        return t * t * (3 - 2 * t)
    }

    private func blend(from: CIImage, to: CIImage, progress: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: outputSize)
        switch transitionStyle {
        case .slide:
            let dx = outputSize.width * (1 - progress)
            return to.transformed(by: CGAffineTransform(translationX: dx, y: 0))
                .composited(over: from)
                .cropped(to: rect)
        case .wipe:
            let revealed = rect.height * progress
            return to.cropped(to: CGRect(x: 0, y: rect.height - revealed, width: rect.width, height: revealed))
                .composited(over: from)
                .cropped(to: rect)
        case .punch:
            let s = 1 + 0.12 * (1 - progress)
            let cx = rect.midX
            let cy = rect.midY
            let zoomed = to.transformed(by: CGAffineTransform(translationX: cx, y: cy).scaledBy(x: s, y: s).translatedBy(x: -cx, y: -cy))
                .cropped(to: rect)
            return dissolve(from: from, to: zoomed, progress: progress)
        case .blur:
            let mixed = dissolve(from: from, to: to, progress: progress)
            let radius = sin(progress * .pi) * 18
            guard radius > 0.5 else { return mixed }
            return mixed.clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: rect)
        default:
            return dissolve(from: from, to: to, progress: progress)
        }
    }

    private func dissolve(from: CIImage, to: CIImage, progress: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = from
        filter.targetImage = to
        filter.time = Float(progress)
        return filter.outputImage ?? to
    }

    private func endTransition() {
        fadingOutput = nil
        fadingImage = nil
        transitionStart = nil
        onTransitionEnded?()
    }

    private func fill(_ image: CIImage, into rect: CGRect, transform t: SourceTransform) -> CIImage {
        var source = image
        switch t.rotation {
        case 90: source = source.oriented(.right)
        case 180: source = source.oriented(.down)
        case 270: source = source.oriented(.left)
        default: break
        }
        let extent = source.extent
        let scale = max(rect.width / extent.width, rect.height / extent.height) * max(t.zoom, 1)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let overflowX = max((scaled.extent.width - rect.width) / 2, 0)
        let overflowY = max((scaled.extent.height - rect.height) / 2, 0)
        let dx = rect.midX - scaled.extent.midX - min(max(t.panX, -1), 1) * overflowX
        let dy = rect.midY - scaled.extent.midY - min(max(t.panY, -1), 1) * overflowY
        var result = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        if t.mirror {
            result = result.transformed(by: CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
        }
        return adjustColor(result.cropped(to: rect), t)
    }

    private func adjustColor(_ image: CIImage, _ t: SourceTransform) -> CIImage {
        var result = image
        if t.brightness != 0 || t.contrast != 1 || t.saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = result
            filter.brightness = Float(t.brightness)
            filter.contrast = Float(t.contrast)
            filter.saturation = Float(t.saturation)
            result = filter.outputImage ?? result
        }
        if t.warmth != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 + t.warmth * 1500, y: 0)
            result = filter.outputImage ?? result
        }
        return result.cropped(to: image.extent)
    }

    private func fit(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = rect.midX - scaled.extent.midX
        let dy = rect.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(outputSize.width),
                kCVPixelBufferHeightKey: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, poolAuxAttributes, &buffer)
        return buffer
    }

    private func emit(_ image: CIImage) {
        guard !previewHandlers.isEmpty || virtualSink != nil else { return }
        guard let outputBuffer = makePixelBuffer() else { return }
        ciContext.render(image, to: outputBuffer)
        lastBuffer = outputBuffer
        if !frozen, !standby, holdTimer != nil {
            holdTimer?.cancel()
            holdTimer = nil
            heldBuffer = nil
        }
        if !previewHandlers.isEmpty {
            let handlers = Array(previewHandlers.values)
            DispatchQueue.main.async { for handler in handlers { handler(outputBuffer) } }
        }
        virtualSink?(outputBuffer)
    }
}
