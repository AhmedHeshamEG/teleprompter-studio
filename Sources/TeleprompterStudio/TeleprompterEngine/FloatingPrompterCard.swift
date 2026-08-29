import SwiftUI

/// The scrolling script as a floating, hand-placeable card: drag the top handle to move it, the
/// bottom-right grip to resize it, and the script itself to nudge the reading position mid-take.
///
/// Lives in its own view for two reasons.
///
/// **It's shared.** Studio (Director) and the Companion screen show the same card over the same
/// full-bleed camera image, so the second device is a real mirror of the first rather than a
/// different-looking screen with a thumbnail in the corner.
///
/// **Dragging it used to rebuild the entire screen.** The position, size and drag state lived on
/// `StudioView`, so every frame of a drag re-evaluated the whole Studio body — camera preview
/// representable, cinematic overlay, grid, every piece of chrome — 60 times a second. That's the
/// stutter you feel when moving the card by its handle. Owning that state here confines each drag
/// frame to this subtree, and the live drag itself is a plain `.offset` that isn't committed to the
/// stored position (or clamped) until the finger lifts.
struct FloatingPrompterCard: View {
    var document: PrompterDocument
    var controller: PrompterController
    var opacity: Double
    /// Height as a fraction of the screen. A `Binding` because Studio's settings sheet drives the
    /// same value from a slider, and the two controls have to agree.
    @Binding var heightFraction: Double
    let screenSize: CGSize
    /// Screen space the surrounding chrome occupies, in points. The card is confined to what's
    /// left: it can be dragged and resized anywhere in that region and nowhere outside it.
    ///
    /// Without this the card was clamped to the *whole* screen while the top bar and the transport
    /// / capture controls were drawn on top of it — so in landscape, where the controls sit in a
    /// single wide row and the screen is only ~390pt tall to begin with, the bottom of the card
    /// (and often its resize grip, and in a tall card its drag handle) ended up underneath chrome
    /// that swallows the touch. The card was there; it just couldn't be grabbed.
    var chromeInsets: PrompterChromeInsets = .zero

    @State private var positionFraction = CGPoint(x: 0.5, y: 0.42)
    /// Card width as a fraction of screen width, adjusted by the corner grip.
    @State private var widthFraction: Double = 0.92
    /// Live drag translation, applied as an offset and committed on release.
    @State private var dragTranslation: CGSize = .zero
    @State private var resizeStart: CGSize?
    @State private var cardSize: CGSize = .zero
    @State private var didApplyInitialLayout = false

    /// Height of the drag-handle row above the script, which counts toward the card's footprint
    /// when working out how tall the body may be.
    private static let handleHeight: CGFloat = 5 + Theme.spacingS * 2

    /// The region of the screen the card is allowed to occupy.
    private var availableRect: CGRect {
        chromeInsets.availableRect(in: screenSize)
    }

    /// Largest body height (as a fraction of screen height) whose card still fits between the
    /// chrome, so the resize grip and the height slider can't push it under the controls.
    private var maxHeightFraction: Double {
        guard screenSize.height > 0 else { return 0.92 }
        let usable = max(120, availableRect.height - Self.handleHeight)
        return min(0.92, Double(usable / screenSize.height))
    }

    private var maxWidthFraction: Double {
        guard screenSize.width > 0 else { return 1.0 }
        return min(1.0, Double(availableRect.width / screenSize.width))
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            // Hit-testing is intentionally ON: the prompter is a real scroll view, so the reader can
            // nudge the script by hand mid-take. Tap-to-focus still works anywhere outside the card.
            NativePrompterView(document: document, controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .frame(height: screenSize.height * min(heightFraction, maxHeightFraction))
                .overlay(alignment: .bottomTrailing) { resizeGrip }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .stroke(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .frame(width: screenSize.width * min(widthFraction, maxWidthFraction))
        .opacity(opacity)
        .onGeometryChange(for: CGSize.self, of: \.size) { cardSize = $0 }
        .offset(dragTranslation)
        .position(
            x: positionFraction.x * screenSize.width,
            y: positionFraction.y * screenSize.height
        )
        .animation(Theme.smoothSpring, value: screenSize.width) // re-clamp smoothly on rotation
        .onAppear { applyInitialLayout() }
        .onChange(of: screenSize) { oldSize, newSize in
            reflow(from: oldSize, to: newSize)
        }
        // The chrome measures itself after first layout, and its height changes when the screen
        // rotates (one wide row in landscape, two stacked rows in portrait). Re-clamp whenever it
        // moves, or a card placed under the old chrome height stays unreachable.
        .onChange(of: chromeInsets) { _, _ in clampIntoAvailableArea() }
        .onChange(of: cardSize) { _, _ in clampIntoAvailableArea() }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Theme.textTertiary)
            .frame(width: 44, height: 5)
            .padding(.vertical, Theme.spacingS)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.001)) // keeps the whole handle row tappable, not just the capsule glyph
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { dragTranslation = $0.translation }
                    .onEnded { value in
                        dragTranslation = .zero
                        positionFraction = clamped(
                            CGPoint(
                                x: positionFraction.x + value.translation.width / max(screenSize.width, 1),
                                y: positionFraction.y + value.translation.height / max(screenSize.height, 1)
                            ),
                            in: screenSize
                        )
                    }
            )
    }

    /// Bottom-right corner grip: drag to resize the card's width and height live. Sizes are kept as
    /// screen fractions (same as the position) so a card sized in portrait stays sane in landscape.
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 34, height: 34)
            .background(Color.black.opacity(0.55), in: Circle())
            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            .padding(Theme.spacingXS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? CGSize(width: widthFraction, height: heightFraction)
                        if resizeStart == nil { resizeStart = start }
                        // Doubled because the card is center-anchored: dragging the corner by N
                        // points grows the card by N on that side and N on the opposite one.
                        let widthDelta = 2 * value.translation.width / max(screenSize.width, 1)
                        let heightDelta = 2 * value.translation.height / max(screenSize.height, 1)
                        widthFraction = min(max(start.width + widthDelta, 0.35), maxWidthFraction)
                        heightFraction = min(max(start.height + heightDelta, 0.15), maxHeightFraction)
                    }
                    .onEnded { _ in
                        resizeStart = nil
                        clampIntoAvailableArea()
                    }
            )
    }

    /// Rotation used to stretch the card: its width and height are stored as fractions of the
    /// screen, so a comfortable 92%-wide column in portrait became a 92%-wide, half-height *band*
    /// in landscape. This converts the card's actual point size through the rotation instead, so it
    /// stays the same physical size and is only clamped when the new screen genuinely can't fit it.
    private func reflow(from oldSize: CGSize, to newSize: CGSize) {
        guard oldSize.width > 0, oldSize.height > 0, newSize.width > 0, newSize.height > 0 else { return }
        let widthPoints = oldSize.width * widthFraction
        let heightPoints = oldSize.height * heightFraction
        widthFraction = min(max(widthPoints / newSize.width, 0.35), maxWidthFraction)
        heightFraction = min(max(heightPoints / newSize.height, 0.15), maxHeightFraction)
        positionFraction = clamped(positionFraction, in: newSize)
    }

    /// Landscape-first defaults for a screen opened while the phone is already sideways. A
    /// full-width card on a landscape screen is a 700pt-wide line of text, unreadable at prompter
    /// speed; a narrower column sitting higher up leaves the chrome its own space.
    private func applyInitialLayout() {
        guard !didApplyInitialLayout, screenSize.width > 0, screenSize.height > 0 else { return }
        didApplyInitialLayout = true
        guard screenSize.width > screenSize.height else { return }
        widthFraction = 0.6
        heightFraction = min(0.52, maxHeightFraction)
        // Centred in the space the chrome leaves rather than at a fixed 36% of the screen, which
        // in landscape put the card's lower half behind the control row.
        positionFraction = CGPoint(x: 0.5, y: availableRect.midY / screenSize.height)
    }

    /// Pulls the card back inside `availableRect` after anything that could have left it straddling
    /// the chrome: a resize, a rotation, or the chrome itself changing height.
    private func clampIntoAvailableArea() {
        guard screenSize.width > 0, screenSize.height > 0 else { return }
        heightFraction = min(heightFraction, maxHeightFraction)
        widthFraction = min(widthFraction, maxWidthFraction)
        positionFraction = clamped(positionFraction, in: screenSize)
    }

    /// Keeps the card's center far enough from every edge of the *available* region that its own
    /// bounds never end up outside it — off-screen, or underneath the chrome.
    private func clamped(_ point: CGPoint, in screenSize: CGSize) -> CGPoint {
        guard screenSize.width > 0, screenSize.height > 0 else { return point }
        let region = availableRect
        let halfWidth = cardSize.width / 2 + Theme.spacingS
        let halfHeight = cardSize.height / 2 + Theme.spacingS
        // A card taller/wider than the region (possible for a moment before a resize settles)
        // centres in it instead of producing an inverted range.
        let minX = min(region.minX + halfWidth, region.midX)
        let maxX = max(region.maxX - halfWidth, region.midX)
        let minY = min(region.minY + halfHeight, region.midY)
        let maxY = max(region.maxY - halfHeight, region.midY)
        return CGPoint(
            x: min(max(point.x * screenSize.width, minX), maxX) / screenSize.width,
            y: min(max(point.y * screenSize.height, minY), maxY) / screenSize.height
        )
    }
}

/// How much of the screen's top and bottom edges the surrounding chrome occupies. Measured by the
/// screen that owns the chrome (Studio, Companion) and handed to the card, so the card never has
/// to know what that chrome *is* — only how much room it leaves.
struct PrompterChromeInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = PrompterChromeInsets()

    func availableRect(in screenSize: CGSize) -> CGRect {
        let height = max(120, screenSize.height - top - bottom)
        return CGRect(x: 0, y: top, width: screenSize.width, height: height)
    }
}
