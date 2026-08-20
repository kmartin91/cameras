import SwiftUI
import CoreVideo

struct PreviewPane: View {
    @ObservedObject var manager: CameraManager
    @State private var lastDrag: CGSize = .zero
    @State private var hovering = false
    @State private var showColor = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                PreviewView(manager: manager)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture(in: geo.size))
                    .onTapGesture(count: 2) { manager.resetFraming() }
                if hovering {
                    controls
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard manager.zoom > 1, size.width > 0, size.height > 0 else { return }
                let deltaX = value.translation.width - lastDrag.width
                let deltaY = value.translation.height - lastDrag.height
                lastDrag = value.translation
                let overflow = max(manager.zoom - 1, 0.05)
                let sign = manager.mirror ? 1.0 : -1.0
                manager.panX = clamp(manager.panX + sign * deltaX / (size.width * overflow) * 2)
                manager.panY = clamp(manager.panY + deltaY / (size.height * overflow) * 2)
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if showColor {
                colorPanel
            }
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $manager.zoom, in: 1...2)
                    .frame(width: 200)
                Image(systemName: "plus.magnifyingglass")
                Button("1×") { manager.resetFraming() }
                Button {
                    showColor.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.bottom, 12)
    }

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            colorRow("Luminosité", $manager.brightness, -0.5...0.5)
            colorRow("Contraste", $manager.contrast, 0.5...1.5)
            colorRow("Saturation", $manager.saturation, 0...2)
            colorRow("Température", $manager.warmth, -1...1)
            Button("Réinitialiser la couleur") { manager.resetColor() }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func colorRow(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: 170)
        }
    }
}

struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PreviewView: NSViewRepresentable {
    let manager: CameraManager

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resizeAspect
        let coordinator = context.coordinator
        manager.pipeline.addPreviewHandler(coordinator.id) { [weak view] buffer in
            coordinator.current = buffer
            view?.layer?.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.manager.pipeline.removePreviewHandler(coordinator.id)
        coordinator.current = nil
    }

    final class Coordinator {
        let manager: CameraManager
        let id = UUID()
        var current: CVPixelBuffer?
        init(manager: CameraManager) { self.manager = manager }
    }
}
