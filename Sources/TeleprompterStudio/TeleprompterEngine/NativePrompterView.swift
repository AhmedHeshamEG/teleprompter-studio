import Combine
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
    @State private var playAnchorDate: Date?
    @State private var playAnchorOffset: CGFloat = 0

    /// A shared, common-run-loop-mode 60Hz ticker rather than a `Task.sleep` polling loop —
    /// ties scroll advancement to the same clock SwiftUI/UIKit use for their own animations, so
    /// it keeps ticking smoothly while the user is dragging the floating card around (a plain
    /// `Task.sleep` loop on the main actor can visibly stall while a gesture is being tracked,
    /// which is what made the overlay feel laggy during playback).
    private static let scrollTicker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

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
        .onChange(of: controller.isPlaying) { _, playing in
            playAnchorDate = playing ? .now : nil
            playAnchorOffset = scrollOffset
        }
        .onReceive(Self.scrollTicker) { date in advanceScroll(to: date) }
        .onChange(of: document.markdown) { _, _ in resetScroll() }
        .onChange(of: controller.jumpToTopToken) { _, _ in reanchor(at: 0) }
        .onChange(of: controller.speedPxPerSec) { _, _ in reanchor(at: scrollOffset) }
        .onChange(of: controller.jumpToFractionRequest) { _, newValue in
            guard let newValue else { return }
            reanchor(at: CGFloat(newValue) * maxScroll)
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

    private func advanceScroll(to date: Date) {
        guard controller.isPlaying, !isInteractivePreview, let anchorDate = playAnchorDate else { return }

        let limit = maxScroll
        guard limit > 0 else { return }

        let elapsed = date.timeIntervalSince(anchorDate)
        scrollOffset = min(limit, playAnchorOffset + CGFloat(controller.speedPxPerSec) * CGFloat(max(0, elapsed)))
        controller.progress = Double(scrollOffset / limit)
        if scrollOffset >= limit {
            controller.markFinished()
        }
    }

    private func resetScroll() {
        reanchor(at: 0)
        controller.progress = 0
    }

    /// Re-anchors the play clock at `offset` — needed whenever `scrollOffset` is changed by
    /// anything other than `advanceScroll` itself (seek, restart, speed change), otherwise the
    /// next tick would compute from the stale anchor and the text would visibly jump.
    private func reanchor(at offset: CGFloat) {
        scrollOffset = offset
        playAnchorOffset = offset
        playAnchorDate = controller.isPlaying ? .now : nil
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
