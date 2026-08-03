import SwiftUI
import UIKit

/// Thin SwiftUI shell around `PrompterTextView` (UIKit) plus the reading guide and countdown.
///
/// Every `PrompterController` property the renderer needs is read **here, in `body`** and passed
/// down as a plain value. That is deliberate: the Observation framework only tracks property reads
/// that happen inside a SwiftUI `View.body`, so reading them inside `updateUIView` instead would
/// leave the renderer stale — the same class of bug that used to freeze the camera preview's
/// rotation (see `AVCameraSession.previewLayer`). Reading them here guarantees pressing play,
/// dragging the speed slider, or seeking always reaches the UIKit view.
struct NativePrompterView: View {
    var document: PrompterDocument
    @Bindable var controller: PrompterController
    /// Editor preview: manual touch-scroll, no autoplay, no countdown overlay.
    var isInteractivePreview: Bool = false

    private var plainText: String {
        PlainTextRenderer.plainText(from: document.markdown)
    }

    var body: some View {
        ZStack(alignment: .top) {
            PrompterTextView(
                text: plainText,
                fontSize: controller.fontSize,
                lineHeight: document.lineHeight,
                textColor: UIColor(HexColor.color(document.textColorHex)),
                marginHorizontalPercent: document.marginHorizontalPercent,
                isPlaying: controller.isPlaying,
                speedPxPerSec: controller.speedPxPerSec,
                mirrorHorizontal: controller.mirrorHorizontal,
                mirrorVertical: controller.mirrorVertical,
                isInteractive: isInteractivePreview,
                jumpToTopToken: controller.jumpToTopToken,
                jumpToFractionRequest: controller.jumpToFractionRequest,
                onProgress: { controller.progress = $0 },
                onFinished: { controller.markFinished() },
                onJumpConsumed: { controller.clearJumpToFractionRequest() }
            )

            if !isInteractivePreview {
                GeometryReader { geo in
                    guideOverlay(in: geo.size)
                }
                .allowsHitTesting(false)
            }

            if let seconds = controller.countdownSecondsRemaining, !isInteractivePreview {
                Text("\(seconds)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.45))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(HexColor.color(document.bgColorHex).opacity(isInteractivePreview ? 1 : 0.55))
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
