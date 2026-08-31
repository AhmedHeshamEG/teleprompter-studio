import SwiftUI
import UIKit

/// The scrolling script as a floating, hand-placeable card: drag the top handle to move it, the
/// bottom-right grip (or a two-finger pinch) to resize it, and the script itself to nudge the
/// reading position mid-take.
///
/// **Moving it is UIKit, not SwiftUI.** The position and size used to live in `@State` and be
/// applied with `.offset`/`.position`, so every frame of a drag re-evaluated this view — which
/// re-runs `NativePrompterView`, which re-runs the prompter `UIViewRepresentable`'s update pass,
/// which re-reads the whole document — sixty times a second. That is the drag lag: the card is
/// chasing a view tree that is being rebuilt underneath it. Now a `PrompterCardCanvas` owns the
/// gestures and moves a plain `UIView`'s frame directly on the render server, and SwiftUI hears
/// about the result exactly once, when the finger lifts.
///
/// **The card is confined to the screen, not to the chrome.** Clamping it into the gap the
/// controls left is what squeezed it to a two-word slot in landscape, where the old top/bottom
/// bars ate ~270 of ~390 points. The chrome insets now only decide where the card *starts*; after
/// that it goes wherever it's put, and the chrome itself gets out of the way (side rails in
/// landscape, and the hide button in `StudioView` clears it entirely).
struct FloatingPrompterCard: View {
    var document: PrompterDocument
    var controller: PrompterController
    var opacity: Double
    /// Height as a fraction of the screen. A `Binding` because Studio's settings sheet drives the
    /// same value from a slider, and the two controls have to agree.
    @Binding var heightFraction: Double
    let screenSize: CGSize
    /// Screen space the surrounding chrome occupies, in points — used to place the card sensibly
    /// on first appearance and on rotation, never to restrict where it may be dragged.
    var chromeInsets: PrompterChromeInsets = .zero
    /// While chrome is hidden the handle and grip go with it: the card is where you put it, and a
    /// stray thumb on the way to the record button can't nudge the script out of frame mid-take.
    var showsHandles: Bool = true
    /// Bumped by "Reset Card" in Studio Settings — the one way back from a card dragged somewhere
    /// unhelpful.
    var resetToken: Int = 0

    /// The card's frame in points, in screen coordinates. Points rather than fractions because
    /// that is what the user actually placed; rotation converts it deliberately (see `reflow`)
    /// instead of stretching it into a different shape every time the screen turns.
    @State private var cardFrame: CGRect = .zero
    @State private var lastResetToken = 0

    private var availableRect: CGRect { chromeInsets.availableRect(in: screenSize) }

    /// Small enough to be worth having, large enough to still read as a prompter.
    private static let minimumSize = CGSize(width: 200, height: 120)

    var body: some View {
        PrompterCardCanvas(
            cardFrame: $cardFrame,
            canvasSize: screenSize,
            showsHandles: showsHandles,
            opacity: opacity,
            minimumSize: Self.minimumSize
        ) {
            // Hit-testing is intentionally ON: the prompter is a real scroll view, so the reader
            // can nudge the script by hand mid-take. Tap-to-focus still works anywhere outside the
            // card — the canvas passes those touches straight through.
            NativePrompterView(document: document, controller: controller)
        }
        .onAppear { if cardFrame.isEmpty { cardFrame = defaultFrame() } }
        .onChange(of: screenSize) { oldSize, newSize in reflow(from: oldSize, to: newSize) }
        // The settings sheet's Height slider and the corner grip drive the same value from two
        // directions; the tolerance keeps them from writing to each other forever.
        .onChange(of: heightFraction) { _, newValue in
            let wanted = newValue * screenSize.height
            guard abs(wanted - cardFrame.height) > 1 else { return }
            cardFrame = fitted(CGRect(
                x: cardFrame.minX,
                y: cardFrame.midY - wanted / 2,
                width: cardFrame.width,
                height: wanted
            ))
        }
        .onChange(of: cardFrame) { _, newValue in
            guard screenSize.height > 0 else { return }
            let fraction = Double(newValue.height / screenSize.height)
            if abs(fraction - heightFraction) > 0.002 { heightFraction = fraction }
        }
        .onChange(of: resetToken) { _, newValue in
            guard newValue != lastResetToken else { return }
            lastResetToken = newValue
            withAnimation(Theme.smoothSpring) { cardFrame = defaultFrame() }
        }
    }

    /// Where a card lands when it has never been placed, or has been reset: centred in whatever
    /// the chrome leaves, as wide as reading comfort allows.
    ///
    /// Landscape gets a *narrower* card on purpose — a full-width card on a landscape screen is a
    /// 700pt line of text, which is unreadable at prompter speed — but it now gets nearly the
    /// screen's full height, because the landscape chrome sits in side rails rather than in bands
    /// across the top and bottom.
    private func defaultFrame() -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .zero }
        let region = availableRect
        let isLandscape = screenSize.width > screenSize.height
        let width = isLandscape
            ? min(region.width, max(360, screenSize.width * 0.62))
            : min(region.width, screenSize.width * 0.92)
        let height = isLandscape
            ? region.height
            : min(region.height, screenSize.height * max(0.25, min(heightFraction, 0.9)))
        return fitted(CGRect(
            x: region.midX - width / 2,
            y: region.midY - height / 2,
            width: width,
            height: height
        ))
    }

    /// Rotation keeps the card the same *physical* size where it can, rather than reinterpreting
    /// its fractions against a screen with the dimensions swapped — which turned a comfortable
    /// portrait column into a landscape band. If the new screen genuinely can't hold it, it's
    /// scaled down to fit and re-centred on the region the chrome leaves.
    private func reflow(from oldSize: CGSize, to newSize: CGSize) {
        guard oldSize.width > 0, oldSize.height > 0, newSize.width > 0, newSize.height > 0 else { return }
        guard !cardFrame.isEmpty else { cardFrame = defaultFrame(); return }

        let region = availableRect
        var size = cardFrame.size
        // A card sized for the long edge doesn't fit on the short one; shrink proportionally
        // instead of clipping one dimension and leaving the other stretched.
        let scale = min(1, min(region.width / size.width, region.height / size.height))
        size = CGSize(width: size.width * scale, height: size.height * scale)
        // Keep it roughly where it was, proportionally, then pull it inside the screen.
        let centerFractionX = cardFrame.midX / oldSize.width
        let centerFractionY = cardFrame.midY / oldSize.height
        cardFrame = fitted(CGRect(
            x: centerFractionX * newSize.width - size.width / 2,
            y: centerFractionY * newSize.height - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    /// Clamps a frame to the *screen*, with a small margin, so the card can never be lost off an
    /// edge — and never so small that it stops being readable.
    private func fitted(_ rect: CGRect) -> CGRect {
        PrompterCardGeometry.fit(rect, in: screenSize, minimumSize: Self.minimumSize)
    }
}

/// Shared clamping, so the SwiftUI side and the UIKit gesture handlers agree on what "on screen"
/// means down to the point.
enum PrompterCardGeometry {
    static let margin: CGFloat = 6

    static func fit(_ rect: CGRect, in canvas: CGSize, minimumSize: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return rect }
        let maxWidth = max(minimumSize.width, canvas.width - margin * 2)
        let maxHeight = max(minimumSize.height, canvas.height - margin * 2)
        let width = min(max(rect.width, minimumSize.width), maxWidth)
        let height = min(max(rect.height, minimumSize.height), maxHeight)
        let x = min(max(rect.minX, margin), max(margin, canvas.width - margin - width))
        let y = min(max(rect.minY, margin), max(margin, canvas.height - margin - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - UIKit canvas

/// A full-screen, touch-transparent canvas that holds one movable card.
///
/// It is full-screen so that dragging never changes *this* view's frame (and so never disturbs
/// SwiftUI's layout); only the card inside it moves. Touches outside the card fall through to the
/// camera preview underneath, so tap-to-focus and pinch-to-zoom keep working.
private struct PrompterCardCanvas<Content: View>: UIViewRepresentable {
    @Binding var cardFrame: CGRect
    var canvasSize: CGSize
    var showsHandles: Bool
    var opacity: Double
    var minimumSize: CGSize
    @ViewBuilder var content: Content

    func makeUIView(context: Context) -> PrompterCardCanvasView {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        // The card is a floating panel, not a screen: without this it inherits the window's safe
        // area and inset its own text away from a notch that isn't next to it.
        host.safeAreaRegions = []
        context.coordinator.host = host

        let view = PrompterCardCanvasView()
        view.minimumSize = minimumSize
        view.setContentView(host.view)
        view.onCommit = { frame in
            // The one SwiftUI update a whole drag produces.
            context.coordinator.lastAppliedFrame = frame
            cardFrame = frame
        }
        return view
    }

    func updateUIView(_ view: PrompterCardCanvasView, context: Context) {
        context.coordinator.host?.rootView = content
        view.minimumSize = minimumSize
        view.setHandlesVisible(showsHandles)
        view.card.alpha = opacity
        // Only write the frame when SwiftUI is the one that changed it — echoing back the frame a
        // gesture just committed would fight the finger that's still on the glass.
        if !view.isGestureActive, context.coordinator.lastAppliedFrame != cardFrame, !cardFrame.isEmpty {
            context.coordinator.lastAppliedFrame = cardFrame
            view.card.frame = cardFrame
        }
    }

    static func dismantleUIView(_ view: PrompterCardCanvasView, coordinator: Coordinator) {
        coordinator.host = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
        var lastAppliedFrame: CGRect = .null
    }
}

/// The card itself: the script, a drag handle above it, and a resize grip in its corner. Lays out
/// its own subviews, so moving or resizing it costs one `layoutSubviews` on one view - no SwiftUI
/// pass, no Auto Layout solve.
final class PrompterCardView: UIView {
    let handleRow = UIView()
    let grip = UIView()

    private let handleBar = UIView()
    private let gripIcon = UIImageView()
    private var contentView: UIView?

    static let handleHeight: CGFloat = 22
    private static let gripSize: CGFloat = 34

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        clipsToBounds = true

        // The whole row is the drag target, not just the capsule glyph drawn in it.
        handleRow.backgroundColor = .clear
        handleBar.backgroundColor = UIColor.white.withAlphaComponent(0.38)
        handleBar.layer.cornerRadius = 2.5
        handleRow.addSubview(handleBar)
        addSubview(handleRow)

        grip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        grip.layer.cornerRadius = Self.gripSize / 2
        grip.layer.borderWidth = 1
        grip.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        gripIcon.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        gripIcon.tintColor = UIColor.white.withAlphaComponent(0.62)
        gripIcon.contentMode = .center
        grip.addSubview(gripIcon)
        addSubview(grip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setContentView(_ view: UIView) {
        contentView?.removeFromSuperview()
        contentView = view
        view.backgroundColor = .clear
        insertSubview(view, at: 0)
        setNeedsLayout()
    }

    func setHandlesVisible(_ visible: Bool) {
        guard handleRow.isHidden == visible else { return }
        handleRow.isHidden = !visible
        grip.isHidden = !visible
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let handleHeight = handleRow.isHidden ? 0 : Self.handleHeight
        handleRow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.handleHeight)
        handleBar.frame = CGRect(x: (bounds.width - 44) / 2, y: 8, width: 44, height: 5)
        contentView?.frame = CGRect(
            x: 0,
            y: handleHeight,
            width: bounds.width,
            height: max(0, bounds.height - handleHeight)
        )
        grip.frame = CGRect(
            x: bounds.width - Self.gripSize - 6,
            y: bounds.height - Self.gripSize - 6,
            width: Self.gripSize,
            height: Self.gripSize
        )
        gripIcon.frame = grip.bounds
    }
}

/// The canvas view: one card subview, two pans and a pinch, and no SwiftUI involvement until a
/// gesture ends.
final class PrompterCardCanvasView: UIView {
    let card = PrompterCardView()

    /// Frame at the moment the current gesture began, so every update is computed from a fixed
    /// origin rather than accumulating rounding error.
    private var gestureStartFrame: CGRect = .zero

    var minimumSize = CGSize(width: 200, height: 120)
    var onCommit: ((CGRect) -> Void)?
    private(set) var isGestureActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(card)

        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        card.handleRow.addGestureRecognizer(move)

        let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        card.grip.addGestureRecognizer(resize)

        // Pinch anywhere on the card resizes it. The prompter's own scroll view only cares about
        // single-finger drags, so the two never contend for the same touch.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        card.addGestureRecognizer(pinch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setContentView(_ view: UIView) {
        card.setContentView(view)
    }

    func setHandlesVisible(_ visible: Bool) {
        card.setHandlesVisible(visible)
    }

    /// Touches that miss the card belong to whatever is underneath it — the camera preview's
    /// tap-to-focus and pinch-to-zoom. Without this the canvas would swallow the entire screen.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: Gestures

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginGesture()
        case .changed:
            let translation = gesture.translation(in: self)
            apply(gestureStartFrame.offsetBy(dx: translation.x, dy: translation.y))
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginGesture()
        case .changed:
            let translation = gesture.translation(in: self)
            // The grip is the bottom-right corner, so the top-left stays put and the card grows
            // by exactly as much as the finger moved — no doubling, no drift.
            apply(CGRect(
                x: gestureStartFrame.minX,
                y: gestureStartFrame.minY,
                width: gestureStartFrame.width + translation.x,
                height: gestureStartFrame.height + translation.y
            ))
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginGesture()
        case .changed:
            let scale = gesture.scale
            let size = CGSize(
                width: gestureStartFrame.width * scale,
                height: gestureStartFrame.height * scale
            )
            apply(CGRect(
                x: gestureStartFrame.midX - size.width / 2,
                y: gestureStartFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    private func beginGesture() {
        isGestureActive = true
        gestureStartFrame = card.frame
    }

    private func apply(_ frame: CGRect) {
        // No implicit CALayer animation: an animated frame change lags the finger by the length of
        // the animation, which is exactly the "it doesn't stick to my thumb" feeling.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = PrompterCardGeometry.fit(frame, in: bounds.size, minimumSize: minimumSize)
        card.layoutIfNeeded()
        CATransaction.commit()
    }

    private func endGesture() {
        isGestureActive = false
        onCommit?(card.frame)
    }
}

extension PrompterCardCanvasView: UIGestureRecognizerDelegate {
    /// The pinch shares its touches with the prompter's own scroll view rather than cancelling it,
    /// so a two-finger resize doesn't leave the script mid-drag.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer
    }
}

/// How much of each screen edge the surrounding chrome occupies. Measured by the screen that owns
/// the chrome (Studio, Companion) and handed to the card, so the card never has to know what that
/// chrome *is* — only where it leaves room.
///
/// Landscape puts the controls in side rails, which is why this has horizontal edges at all: in
/// landscape an iPhone has ~390 points of height and none of it can be spared for a control bar.
struct PrompterChromeInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    static let zero = PrompterChromeInsets()

    func availableRect(in screenSize: CGSize) -> CGRect {
        let width = max(200, screenSize.width - leading - trailing)
        let height = max(120, screenSize.height - top - bottom)
        return CGRect(x: leading, y: top, width: width, height: height)
    }
}
