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

    @State private var positionFraction = CGPoint(x: 0.5, y: 0.42)
    /// Card width as a fraction of screen width, adjusted by the corner grip.
    @State private var widthFraction: Double = 0.92
    /// Live drag translation, applied as an offset and committed on release.
    @State private var dragTranslation: CGSize = .zero
    @State private var resizeStart: CGSize?
    @State private var cardSize: CGSize = .zero
    @State private var didApplyInitialLayout = false

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            // Hit-testing is intentionally ON: the prompter is a real scroll view, so the reader can
            // nudge the script by hand mid-take. Tap-to-focus still works anywhere outside the card.
            NativePrompterView(document: document, controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .frame(height: screenSize.height * heightFraction)
                .overlay(alignment: .bottomTrailing) { resizeGrip }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .stroke(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .frame(width: screenSize.width * widthFraction)
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
                        widthFraction = min(max(start.width + widthDelta, 0.35), 1.0)
                        heightFraction = min(max(start.height + heightDelta, 0.15), 0.92)
                    }
                    .onEnded { _ in resizeStart = nil }
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
        widthFraction = min(max(widthPoints / newSize.width, 0.35), 1.0)
        heightFraction = min(max(heightPoints / newSize.height, 0.15), 0.92)
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
        heightFraction = 0.52
        positionFraction = CGPoint(x: 0.5, y: 0.36)
    }

    /// Keeps the card's center far enough from every edge that its own bounds never leave the
    /// visible screen.
    private func clamped(_ point: CGPoint, in screenSize: CGSize) -> CGPoint {
        guard screenSize.width > 0, screenSize.height > 0 else { return point }
        let halfWidthFraction = (cardSize.width / 2 + Theme.spacingS) / screenSize.width
        let halfHeightFraction = (cardSize.height / 2 + Theme.spacingS) / screenSize.height
        return CGPoint(
            x: min(max(point.x, halfWidthFraction), 1 - halfWidthFraction),
            y: min(max(point.y, halfHeightFraction), 1 - halfHeightFraction)
        )
    }
}
