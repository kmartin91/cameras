import AVFoundation
import AppKit
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

enum SpinSpeed: String, CaseIterable {
    case slow
    case medium
    case fast

    var degreesPerSecond: Double {
        switch self {
        case .slow: return 30
        case .medium: return 90
        case .fast: return 270
        }
    }
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
    var onRageQuitEnded: (() -> Void)?

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
    private var spinRate = 0.0
    private var spinAngle = 0.0
    private var spinClock: CFTimeInterval?
    private var spinSettleFrom: Double?
    private var spinSettleStart: CFTimeInterval = 0
    private var rageStart: CFTimeInterval?
    private var rageTimer: DispatchSourceTimer?
    private var rageBase: CIImage?
    private var rageBanner: CIImage?
    private var blackout = false
    private let rageDuration = 2.7
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
            if !standby, self.blackout {
                self.blackout = false
                self.standbyBuffer = nil
            }
            self.updateHold()
        }
    }

    func setSpin(_ degreesPerSecond: Double) {
        queue.async {
            if degreesPerSecond != 0 {
                self.spinRate = degreesPerSecond
                self.spinSettleFrom = nil
            } else if self.spinRate != 0 {
                self.spinRate = 0
                self.spinSettleFrom = self.spinAngle
                self.spinSettleStart = CACurrentMediaTime()
            }
        }
    }

    func rageQuit(caption: String) {
        queue.async {
            guard self.rageStart == nil else { return }
            self.rageBase = self.displayedBuffer.map { CIImage(cvPixelBuffer: $0) }
            self.rageBanner = self.makeRageBanner(caption: caption)
            self.rageStart = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.renderRageFrame() }
            timer.resume()
            self.rageTimer = timer
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
            completion(self.displayedBuffer)
        }
    }

    private var displayedBuffer: CVPixelBuffer? {
        holdTimer != nil ? (heldBuffer ?? lastBuffer) : lastBuffer
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
            if transitionStart == nil { emit(composite(applySpin(image))) }
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
        emit(composite(applySpin(result)))
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
        guard rageStart == nil else { return }
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
        if let standbyImage, !blackout {
            image = fit(standbyImage, into: rect).composited(over: image)
        }
        guard let buffer = makePixelBuffer() else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }


    private func applySpin(_ image: CIImage) -> CIImage {
        let angle = advanceSpin()
        guard abs(angle) > 0.01 else { return image }
        let rect = CGRect(origin: .zero, size: outputSize)
        let turn = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: -angle * .pi / 180)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return image.transformed(by: turn)
            .composited(over: CIImage(color: .black).cropped(to: rect))
            .cropped(to: rect)
    }

    private func advanceSpin() -> Double {
        let now = CACurrentMediaTime()
        let elapsed = min(max(now - (spinClock ?? now), 0), 0.1)
        spinClock = now
        if spinRate != 0 {
            spinAngle = (spinAngle + spinRate * elapsed).truncatingRemainder(dividingBy: 360)
            return spinAngle
        }
        guard let from = spinSettleFrom else { return 0 }
        let progress = min((now - spinSettleStart) / 0.6, 1)
        guard progress < 1 else {
            spinSettleFrom = nil
            spinAngle = 0
            return 0
        }
        let start = from < 0 ? from + 360 : from
        let target = start > 180 ? 360.0 : 0
        spinAngle = start + (target - start) * smoothstep(progress)
        return spinAngle
    }


    private func renderRageFrame() {
        guard let start = rageStart else { return }
        let elapsed = CACurrentMediaTime() - start
        guard elapsed < rageDuration else {
            finishRageQuit()
            return
        }
        guard !previewHandlers.isEmpty || virtualSink != nil, let buffer = makePixelBuffer() else { return }
        ciContext.render(rageFrame(at: elapsed), to: buffer)
        deliver(buffer)
    }

    private func finishRageQuit() {
        rageTimer?.cancel()
        rageTimer = nil
        rageStart = nil
        rageBase = nil
        rageBanner = nil
        blackout = true
        standby = true
        standbyBuffer = nil
        updateHold()
        onRageQuitEnded?()
    }

    private func rageFrame(at t: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: outputSize)
        let black = CIImage(color: .black).cropped(to: rect)
        let shakeEnd = 1.5
        let collapseEnd = 2.1
        guard t < collapseEnd else { return black }
        let p = min(t / shakeEnd, 1)
        let shaking = t < shakeEnd
        let amplitude = shaking ? outputSize.height * (0.006 + 0.03 * p) : 0
        let tilt = shaking ? Double.random(in: -1...1) * (0.3 + 2.2 * p) * .pi / 180 : 0
        let scale = 1.04 + 0.12 * p
        let shake = CGAffineTransform(
            translationX: rect.midX + Double.random(in: -1...1) * amplitude,
            y: rect.midY + Double.random(in: -1...1) * amplitude)
            .rotated(by: tilt)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        var frame = rageTint(rageBase ?? black, strength: min(t / 0.4, 1)).transformed(by: shake)
        let impact = max(0, 1 - abs(t - 0.37) / 0.08)
        if impact > 0 {
            frame = adjusted(frame, brightness: 0.4 * impact, saturation: 1)
        }
        if let rageBanner, t > 0.15 {
            frame = slam(rageBanner, elapsed: t - 0.15, in: rect).composited(over: frame)
        }
        frame = frame.composited(over: black).cropped(to: rect)
        guard !shaking else { return frame }
        return crtOff(frame, progress: (t - shakeEnd) / (collapseEnd - shakeEnd), in: rect)
            .composited(over: black)
            .cropped(to: rect)
    }

    private func rageTint(_ image: CIImage, strength: Double) -> CIImage {
        let filter = CIFilter.colorMonochrome()
        filter.inputImage = image
        filter.color = CIColor(red: 1, green: 0.1, blue: 0.06)
        filter.intensity = Float(0.55 * strength)
        return filter.outputImage ?? image
    }

    private func adjusted(_ image: CIImage, brightness: Double, saturation: Double) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = Float(brightness)
        filter.saturation = Float(saturation)
        return filter.outputImage ?? image
    }

    private func slam(_ banner: CIImage, elapsed: Double, in rect: CGRect) -> CIImage {
        let progress = min(elapsed / 0.22, 1)
        let scale = 1 + 2.5 * pow(1 - progress, 3)
        let placed = banner.transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: scale, y: scale))
        guard progress < 1 else { return placed }
        let fade = CIFilter.colorMatrix()
        fade.inputImage = placed
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: progress)
        return fade.outputImage ?? placed
    }

    private func crtOff(_ image: CIImage, progress: Double, in rect: CGRect) -> CIImage {
        let squash = min(progress / 0.6, 1)
        let height = max(1 - squash * squash, 0.006)
        let width = progress < 0.6 ? 1 : max(1 - (progress - 0.6) / 0.4, 0.004)
        let squeeze = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: width, y: height)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return adjusted(image, brightness: 0.1 + 0.6 * squash, saturation: 1 - squash)
            .cropped(to: rect)
            .transformed(by: squeeze)
    }

    private func makeRageBanner(caption: String) -> CIImage? {
        let height = outputSize.height
        guard let title = textImage("RAGE QUIT", size: height * 0.2, weight: .black),
              let subtitle = textImage(caption, size: height * 0.07, weight: .heavy) else { return nil }
        let width = outputSize.width * 1.6
        let titleHeight = title.extent.height * 1.1
        let captionHeight = subtitle.extent.height * 1.6
        let total = titleHeight + captionHeight
        let titleBand = CGRect(x: -width / 2, y: total / 2 - titleHeight, width: width, height: titleHeight)
        let captionBand = CGRect(x: -width / 2, y: -total / 2, width: width, height: captionHeight)
        let red = CIImage(color: CIColor(red: 0.86, green: 0.06, blue: 0.1)).cropped(to: titleBand)
        let dark = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06)).cropped(to: captionBand)
        let stamp = centered(title, in: titleBand.offsetBy(dx: 0, dy: -height * 0.012))
            .composited(over: red)
            .composited(over: centered(subtitle, in: captionBand).composited(over: dark))
        return stamp.transformed(by: CGAffineTransform(rotationAngle: 0.1))
    }

    private func textImage(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CIImage? {
        let filter = CIFilter.attributedTextImageGenerator()
        filter.text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white,
        ])
        filter.scaleFactor = 1
        return filter.outputImage
    }

    private func centered(_ image: CIImage, in rect: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: rect.midX - image.extent.midX, y: rect.midY - image.extent.midY))
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
        if rageStart != nil {
            rageBase = image
            return
        }
        guard !previewHandlers.isEmpty || virtualSink != nil else { return }
        guard let outputBuffer = makePixelBuffer() else { return }
        ciContext.render(image, to: outputBuffer)
        lastBuffer = outputBuffer
        if !frozen, !standby, holdTimer != nil {
            holdTimer?.cancel()
            holdTimer = nil
            heldBuffer = nil
        }
        deliver(outputBuffer)
    }

    private func deliver(_ buffer: CVPixelBuffer) {
        if !previewHandlers.isEmpty {
            let handlers = Array(previewHandlers.values)
            DispatchQueue.main.async { for handler in handlers { handler(buffer) } }
        }
        virtualSink?(buffer)
    }
}
