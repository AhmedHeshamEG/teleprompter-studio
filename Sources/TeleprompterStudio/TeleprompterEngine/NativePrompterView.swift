import SwiftUI

/// Plain native SwiftUI teleprompter: no WebKit, no HTML/Markdown rendering, no JS bridge — just
/// `Text` moved by a continuously-updating offset while `controller.isPlaying`. Replaces the old
/// WKWebView + `marked.js` pipeline, which could silently fail to finish loading (leaving raw
/// `<span>`/`**`/`#` markup on screen) and had no reliable connection between the play button and
/// actual scrolling.
struct NativePrompterView: View {
    var document: PrompterDocument
    @Bindable var controller: PrompterController
    /// Editor preview: manual touch-scroll, no autoplay, no countdown overlay.
    var isInteractivePreview: Bool = false

    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var lastTick: Date?

    private var plainText: String {
        let text = PlainTextRenderer.plainText(from: document.markdown)
        return text.isEmpty ? " " : text
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                textContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, geo.size.width * document.marginHorizontalPercent / 100)
                    .padding(.top, isInteractivePreview ? Theme.spacingM : geo.size.height)
                    .padding(.bottom, geo.size.height)
                    .background(heightReader)
                    .offset(y: isInteractivePreview ? 0 : -scrollOffset)
                    .scaleEffect(x: controller.mirrorHorizontal ? -1 : 1, y: controller.mirrorVertical ? -1 : 1)

                if !isInteractivePreview {
                    guideOverlay(in: geo.size)
                }

                if let seconds = controller.countdownSecondsRemaining, !isInteractivePreview {
                    Text("\(seconds)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.45))
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
            .onAppear { viewportHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, newValue in viewportHeight = newValue }
        }
        .background(HexColor.color(document.bgColorHex).opacity(isInteractivePreview ? 1 : 0.55))
        .task(id: controller.isPlaying) { await runAutoscroll() }
        .onChange(of: document.markdown) { _, _ in resetScroll() }
        .onChange(of: controller.jumpToTopToken) { _, _ in scrollOffset = 0 }
        .onChange(of: controller.jumpToFractionRequest) { _, newValue in
            guard let newValue else { return }
            scrollOffset = CGFloat(newValue) * maxScroll
            controller.progress = newValue
            controller.clearJumpToFractionRequest()
        }
    }

    private var textContent: some View {
        Text(plainText)
            .font(.system(size: CGFloat(controller.fontSize), weight: .semibold))
            .foregroundStyle(HexColor.color(document.textColorHex))
            .lineSpacing((document.lineHeight - 1) * CGFloat(controller.fontSize))
            .multilineTextAlignment(.leading)
    }

    private var heightReader: some View {
        GeometryReader { textGeo in
            Color.clear
                .onAppear { contentHeight = textGeo.size.height }
                .onChange(of: textGeo.size.height) { _, newValue in contentHeight = newValue }
        }
    }

    private var maxScroll: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    @MainActor
    private func runAutoscroll() async {
        guard controller.isPlaying, !isInteractivePreview else { return }
        lastTick = .now
        while controller.isPlaying, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard controller.isPlaying, !Task.isCancelled else { break }
            let now = Date.now
            let dt = now.timeIntervalSince(lastTick ?? now)
            lastTick = now

            let limit = maxScroll
            guard limit > 0 else { continue }

            scrollOffset += CGFloat(controller.speedPxPerSec) * CGFloat(dt)
            if scrollOffset >= limit {
                scrollOffset = limit
                controller.markFinished()
                break
            }
            controller.progress = Double(scrollOffset / limit)
        }
    }

    private func resetScroll() {
        scrollOffset = 0
        controller.progress = 0
    }

    @ViewBuilder
    private func guideOverlay(in size: CGSize) -> some View {
        switch controller.guideMode {
        case .line:
            Rectangle()
                .fill(Theme.accent.opacity(0.6))
                .frame(height: 2)
                .position(x: size.width / 2, y: size.height * 0.42)
        case .band:
            Rectangle()
                .fill(Theme.accent.opacity(0.12))
                .frame(height: size.height * 0.16)
                .position(x: size.width / 2, y: size.height * 0.42)
        case .none:
            EmptyView()
        }
    }
}
