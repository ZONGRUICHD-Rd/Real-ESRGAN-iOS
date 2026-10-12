import SwiftUI

/// Before/after viewer: drag the divider to compare, pinch to zoom, double-tap to reset.
struct CompareView: View {
    let before: UIImage
    let after: UIImage?

    @State private var split: CGFloat = 0.5
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxZoom: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let fitted = fittedSize(for: before.size, in: container)
            let displayed = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
            let imageMinX = (container.width - displayed.width) / 2 + offset.width

            ZStack {
                images(size: fitted)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .position(x: container.width / 2, y: container.height / 2)

                if after != nil {
                    divider(x: imageMinX + displayed.width * split, height: container.height)
                    labels
                }
            }
            .contentShape(.rect)
            .gesture(panGesture(container: container, fitted: fitted, imageMinX: imageMinX, displayedWidth: displayed.width))
            .simultaneousGesture(magnifyGesture(container: container, fitted: fitted))
            .onTapGesture(count: 2) {
                withAnimation(.smooth) { resetZoom() }
            }
        }
        .clipped()
        .onChange(of: before) { _, _ in
            resetZoom()
            split = 0.5
        }
        .onChange(of: after == nil) { _, isNil in
            if !isNil { withAnimation(.smooth(duration: 0.6)) { split = 0.5 } }
        }
    }

    // MARK: Layers

    private func images(size: CGSize) -> some View {
        ZStack {
            Image(uiImage: before)
                .resizable()
                .frame(width: size.width, height: size.height)

            if let after {
                Image(uiImage: after)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: size.width * (1 - split))
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func divider(x: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.35), radius: 3)

            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassEffect(.clear.interactive(), in: .circle)
        }
        .position(x: x, y: height / 2)
        .accessibilityElement()
        .accessibilityLabel("对比分割线")
        .accessibilityValue("\(Int(split * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(1, split + 0.1)
            case .decrement: split = max(0, split - 0.1)
            @unknown default: break
            }
        }
    }

    private var labels: some View {
        VStack {
            HStack {
                tag("原图")
                Spacer()
                tag("Real-ESRGAN")
            }
            Spacer()
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.35), in: .capsule)
            .glassEffect(.clear, in: .capsule)
    }

    // MARK: Gestures

    /// At 1x a drag moves the divider; when zoomed it pans the image.
    private func panGesture(container: CGSize, fitted: CGSize, imageMinX: CGFloat, displayedWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if zoom > 1.01 || after == nil {
                    offset = clampedOffset(
                        CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height),
                        container: container, fitted: fitted)
                } else {
                    split = min(1, max(0, (value.location.x - imageMinX) / max(displayedWidth, 1)))
                }
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func magnifyGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(maxZoom, max(1, committedZoom * value.magnification))
                offset = clampedOffset(offset, container: container, fitted: fitted)
            }
            .onEnded { _ in
                committedZoom = zoom
                committedOffset = offset
            }
    }

    private func resetZoom() {
        zoom = 1
        committedZoom = 1
        offset = .zero
        committedOffset = .zero
    }

    // MARK: Geometry

    private func fittedSize(for image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func clampedOffset(_ proposed: CGSize, container: CGSize, fitted: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * zoom - container.width) / 2)
        let maxY = max(0, (fitted.height * zoom - container.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height)))
    }
}
