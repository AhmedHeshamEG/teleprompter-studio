import SwiftUI
import UIKit

/// UIKit-backed prompter surface: a `UIScrollView` holding one `UILabel`, scrolled by a
/// `CADisplayLink`.
///
/// Why not plain SwiftUI: the previous renderer advanced a `@State` scroll offset from a 60 Hz
/// `Timer` publisher, so every single frame re-evaluated the SwiftUI view body, re-laid-out the
/// entire script `Text`, and re-composited it over the live camera preview. That is what made the
/// overlay feel laggy, and it also made "play" fragile — the scroll only advanced if that
/// particular publisher tick reached that particular view instance. Here the scroll is just
/// `contentOffset` moved on the display link: no SwiftUI invalidation per frame, layout is done
/// once per text/size change, and playback is a property on a UIKit object rather than an emergent
/// property of the view tree.
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
        let view = PrompterScrollView()
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
final class PrompterScrollView: UIScrollView, UIScrollViewDelegate {
    private let label = UILabel()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastReportedProgress: Double = -1
    private var lastReportTime: CFTimeInterval = 0
    private var isApplyingProgrammaticOffset = false

    /// Cached inputs so `configureText` can no-op when nothing actually changed — `updateUIView`
    /// runs on every SwiftUI update, and re-measuring a full script is not free.
    private var cachedText: String?
    private var cachedFontSize: CGFloat = 0
    private var cachedLineHeight: CGFloat = 0
    private var cachedColor: UIColor = .white
    private var cachedInsetPercent: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutHeight: CGFloat = 0

    var speedPxPerSec: Double = 90
    var isUserScrollEnabled = true {
        didSet { isScrollEnabled = isUserScrollEnabled }
    }
    var onProgress: ((Double) -> Void)?
    var onFinished: (() -> Void)?

    private(set) var isPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        bounces = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .normal
        delegate = self

        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        addSubview(label)
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
        let unchanged = cachedText == text
            && cachedFontSize == fontSize
            && cachedLineHeight == lineHeight
            && cachedColor == color
            && cachedInsetPercent == horizontalInsetPercent
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
        label.attributedText = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        lastLayoutWidth = 0 // force a re-measure on the next layout pass
        setNeedsLayout()
        if textChanged { jumpToTop() }
    }

    func setMirror(horizontal: Bool, vertical: Bool) {
        let transform = CGAffineTransform(scaleX: horizontal ? -1 : 1, y: vertical ? -1 : 1)
        if label.transform != transform {
            label.transform = transform
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        guard bounds.width != lastLayoutWidth || bounds.height != lastLayoutHeight || label.bounds.width == 0 else { return }
        lastLayoutWidth = bounds.width
        lastLayoutHeight = bounds.height

        let horizontalInset = bounds.width * cachedInsetPercent / 100
        let topInset: CGFloat = 12
        let available = max(1, bounds.width - horizontalInset * 2)
        let height = label.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
        // `bounds` + `center` rather than `frame`: the label carries a mirroring transform for
        // beam-splitter rigs, and `frame` is undefined for a transformed view.
        label.bounds = CGRect(x: 0, y: 0, width: available, height: height)
        label.center = CGPoint(x: horizontalInset + available / 2, y: topInset + height / 2)
        // A viewport's worth of trailing space so the final line can scroll up to the reading
        // guide instead of stopping dead at the bottom edge.
        contentSize = CGSize(width: bounds.width, height: topInset + height + bounds.height * 0.85)
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
