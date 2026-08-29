import SwiftUI
import UIKit

/// UIKit-backed prompter surface: a `UITextView` scrolled by a `CADisplayLink`.
///
/// Why not plain SwiftUI: the original renderer advanced a `@State` scroll offset from a 60 Hz
/// `Timer` publisher, so every single frame re-evaluated the SwiftUI view body, re-laid-out the
/// entire script `Text`, and re-composited it over the live camera preview. That is what made the
/// overlay feel laggy, and it also made "play" fragile — the scroll only advanced if that
/// particular publisher tick reached that particular view instance. Here the scroll is just
/// `contentOffset` moved on the display link: no SwiftUI invalidation per frame, layout is done
/// once per text/size change, and playback is a property on a UIKit object rather than an emergent
/// property of the view tree.
///
/// **Why a `UITextView` and not a `UILabel` in a `UIScrollView`** (which is what this was): a
/// `UILabel` draws its entire text into *one* backing layer. Core Animation silently refuses to
/// render a layer taller than the GPU's maximum texture size (8192 or 16384 points depending on
/// the device), so past a certain content height the label drew *nothing at all* — leaving the
/// card's translucent black background with no text on it. Content height is
/// `lines × fontSize × lineHeight`, so the failure appears as a **font-size threshold**: a script
/// that renders fine at 40pt goes completely black at 46pt. `UITextView` is TextKit-backed and
/// tiles its rendering to the visible viewport, so it has no such ceiling — the script draws
/// correctly at any size in the 18–120pt range, at any length.
struct PrompterTextView: UIViewRepresentable {
    var text: String
    var fontSize: Double
    var lineHeight: Double
    var textColor: UIColor
    var marginHorizontalPercent: Double
    var isPlaying: Bool
    var speedPxPerSec: Double
    var mirrorHorizontal: Bool
    var mirrorVertical: Bool
    /// Editor preview: user can scroll by hand, autoplay never runs.
    var isInteractive: Bool
    var jumpToTopToken: Int
    var jumpToFractionRequest: Double?

    var onProgress: (Double) -> Void
    var onFinished: () -> Void
    var onJumpConsumed: () -> Void

    func makeUIView(context: Context) -> PrompterScrollView {
        let view = PrompterScrollView(frame: .zero, textContainer: nil)
        view.onProgress = onProgress
        view.onFinished = onFinished
        context.coordinator.lastJumpToTopToken = jumpToTopToken
        apply(to: view, coordinator: context.coordinator, isFirstApply: true)
        return view
    }

    func updateUIView(_ view: PrompterScrollView, context: Context) {
        view.onProgress = onProgress
        view.onFinished = onFinished
        apply(to: view, coordinator: context.coordinator, isFirstApply: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to view: PrompterScrollView, coordinator: Coordinator, isFirstApply: Bool) {
        view.configureText(
            text,
            fontSize: CGFloat(fontSize),
            lineHeight: CGFloat(lineHeight),
            color: textColor,
            horizontalInsetPercent: CGFloat(marginHorizontalPercent)
        )
        view.setMirror(horizontal: mirrorHorizontal, vertical: mirrorVertical)
        view.speedPxPerSec = speedPxPerSec
        view.isUserScrollEnabled = true
        view.setPlaying(isPlaying && !isInteractive)

        if !isFirstApply, coordinator.lastJumpToTopToken != jumpToTopToken {
            coordinator.lastJumpToTopToken = jumpToTopToken
            view.jumpToTop()
        }
        if let fraction = jumpToFractionRequest {
            view.seek(toFraction: fraction)
            // Deferred: clearing the controller's request synchronously here would mutate
            // observed state in the middle of SwiftUI's own update pass.
            DispatchQueue.main.async { onJumpConsumed() }
        }
    }

    final class Coordinator {
        var lastJumpToTopToken = 0
    }
}

/// The actual scrolling surface. Owns its own display link so playback keeps advancing at a
/// steady rate regardless of what SwiftUI is doing above it (including while the user drags the
/// floating card around, which used to visibly stall the old timer-driven scroll).
///
/// A `UITextView` *is* a `UIScrollView`, so everything the previous implementation did with
/// `contentOffset` still applies verbatim — it just gained TextKit's viewport-tiled rendering,
/// which is what makes large font sizes work (see `PrompterTextView`).
final class PrompterScrollView: UITextView, UITextViewDelegate {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastReportedProgress: Double = -1
    private var lastReportTime: CFTimeInterval = 0
    private var isApplyingProgrammaticOffset = false

    /// Cached inputs so `configureText` can no-op when nothing actually changed — `updateUIView`
    /// runs on every SwiftUI update, and re-typesetting a full script is not free.
    private var cachedText: String?
    private var cachedFontSize: CGFloat = 0
    private var cachedLineHeight: CGFloat = 0
    private var cachedColor: UIColor = .white
    private var cachedInsetPercent: CGFloat = 0
    private var lastInsetWidth: CGFloat = 0
    private var lastInsetHeight: CGFloat = 0

    var speedPxPerSec: Double = PrompterPreferences.defaultSpeed
    var isUserScrollEnabled = true {
        didSet { isScrollEnabled = isUserScrollEnabled }
    }
    var onProgress: ((Double) -> Void)?
    var onFinished: (() -> Void)?

    private(set) var isPlaying = false

    /// `init(frame:textContainer:)` is `UITextView`'s *designated* initializer — `init(frame:)`
    /// is not, and can't be overridden. Callers pass a `nil` container, which is what asks for the
    /// default TextKit 2 stack (the one that lays out and renders only the visible viewport, which
    /// is precisely the property this view needs) rather than a hand-built TextKit 1 one.
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        bounces = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .normal
        isEditable = false
        isSelectable = false            // a prompter is read, not selected; also kills the magnifier
        // `self.` because the initializer's own `textContainer` parameter shadows the property,
        // and it's the view's resolved (non-optional) container that needs configuring.
        self.textContainer.lineFragmentPadding = 0
        self.textContainer.lineBreakMode = .byWordWrapping
        // The prompter never scrolls sideways: without this a long unbroken word (a URL, say)
        // would widen the content instead of wrapping.
        self.textContainer.widthTracksTextView = true
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        displayLink?.invalidate()
    }

    /// `CADisplayLink` retains its target, so a view torn down mid-playback would otherwise keep
    /// itself (and a 60 Hz callback) alive forever.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPlaying(false) }
    }

    // MARK: Content

    func configureText(
        _ text: String,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        color: UIColor,
        horizontalInsetPercent: CGFloat
    ) {
        let insetsChanged = cachedInsetPercent != horizontalInsetPercent
        let unchanged = cachedText == text
            && cachedFontSize == fontSize
            && cachedLineHeight == lineHeight
            && cachedColor == color
            && !insetsChanged
        guard !unchanged else { return }

        let textChanged = cachedText != nil && cachedText != text
        cachedText = text
        cachedFontSize = fontSize
        cachedLineHeight = lineHeight
        cachedColor = color
        cachedInsetPercent = horizontalInsetPercent

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, (lineHeight - 1) * fontSize)
        paragraph.alignment = .left
        attributedText = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        lastInsetWidth = 0 // force the insets to be recomputed on the next layout pass
        setNeedsLayout()
        if textChanged { jumpToTop() }
    }

    func setMirror(horizontal: Bool, vertical: Bool) {
        // Applied to the whole view rather than to a content subview: a `UITextView` renders its
        // own text, so there is no inner view left to flip on its own.
        let wanted = CGAffineTransform(scaleX: horizontal ? -1 : 1, y: vertical ? -1 : 1)
        if transform != wanted {
            transform = wanted
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        guard bounds.width != lastInsetWidth || bounds.height != lastInsetHeight else { return }
        lastInsetWidth = bounds.width
        lastInsetHeight = bounds.height

        let horizontalInset = bounds.width * cachedInsetPercent / 100
        textContainerInset = UIEdgeInsets(
            top: 12,
            left: horizontalInset,
            // A viewport's worth of trailing space so the final line can scroll up to the reading
            // guide instead of stopping dead at the bottom edge.
            bottom: bounds.height * 0.85,
            right: horizontalInset
        )
    }

    private var maxOffset: CGFloat {
        max(0, contentSize.height - bounds.height)
    }

    // MARK: Transport

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            lastTimestamp = 0
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func jumpToTop() {
        lastTimestamp = 0
        setOffset(0)
        reportProgress(force: true)
    }

    func seek(toFraction fraction: Double) {
        lastTimestamp = 0
        setOffset(CGFloat(max(0, min(1, fraction))) * maxOffset)
        reportProgress(force: true)
    }

    private func setOffset(_ y: CGFloat) {
        isApplyingProgrammaticOffset = true
        setContentOffset(CGPoint(x: 0, y: y), animated: false)
        isApplyingProgrammaticOffset = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else { return }
        let delta = now - lastTimestamp
        // Ignore absurd deltas (app was backgrounded, a long main-thread stall, etc.) rather than
        // teleporting the script forward by however long the gap was.
        guard delta > 0, delta < 0.5 else { return }
        let limit = maxOffset
        guard limit > 0 else { return }

        let next = contentOffset.y + CGFloat(speedPxPerSec * delta)
        if next >= limit {
            setOffset(limit)
            reportProgress(force: true)
            setPlaying(false)
            onFinished?()
            return
        }
        setOffset(next)
        reportProgress(force: false)
    }

    /// Publishing progress back into `@Observable` state invalidates every SwiftUI view reading
    /// it, so it's throttled to ~10 Hz — plenty for the progress bar and the companion-device
    /// sync, and it keeps the per-frame scroll free of SwiftUI work.
    private func reportProgress(force: Bool) {
        let limit = maxOffset
        let fraction = limit > 0 ? Double(contentOffset.y / limit) : 0
        let now = CACurrentMediaTime()
        guard force || (now - lastReportTime > 0.1 && abs(fraction - lastReportedProgress) > 0.0005) else { return }
        lastReportTime = now
        lastReportedProgress = fraction
        onProgress?(fraction)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingProgrammaticOffset else { return }
        // Hand-scrolling re-anchors playback wherever the user let go: `step` always advances
        // from the current `contentOffset`, so no extra bookkeeping is needed.
        lastTimestamp = 0
        reportProgress(force: true)
    }
}
