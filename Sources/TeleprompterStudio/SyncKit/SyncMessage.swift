import Foundation

enum SyncRole: String, Codable, Sendable {
    case director
    case companion
}

/// Wire format for everything sent over the `MCSession`. Kept as a single flat enum (rather
/// than separate reliable/unreliable channels) so both sides share one decode path; the sender
/// picks `MCSessionSendDataMode` per case in `SyncCoordinator`.
enum SyncMessage: Codable, Sendable {
    case roleAnnounce(SyncRole)

    case scriptSync(title: String, markdown: String, style: SyncStyleSnapshot)

    case playbackState(fraction: Double, isPlaying: Bool, speedPxPerSec: Double, fontSize: Double)

    case remoteCommand(RemoteCommand)

    /// Downscaled, JPEG-compressed live preview frame. `sequence` lets the receiver drop
    /// stale/out-of-order frames instead of queuing them.
    case previewFrame(jpeg: Data, sequence: UInt32)

    case recordingStateChanged(isRecording: Bool, elapsed: Double)

    /// Sent by Director when preview streaming degrades or recovers, so Companion can show
    /// "prompter-mirror only" instead of a frozen/broken video view.
    case previewStreamAvailability(available: Bool)

    enum RemoteCommand: Codable, Sendable {
        case togglePlayback
        case jumpToTop
        case jumpToFraction(Double)
        case setSpeed(Double)
        case setFontSize(Double)
        case startRecording
        case stopRecording
        case startCountdown(seconds: Int)
    }
}

struct SyncStyleSnapshot: Codable, Sendable, Equatable {
    var fontName: String
    var baseSize: Double
    var lineHeight: Double
    var textColorHex: String
    var bgColorHex: String
    var accentColorHex: String
    var marginHorizontalPercent: Double
    var mirrorHorizontal: Bool
    var mirrorVertical: Bool

    init(document: PrompterDocument) {
        fontName = document.fontName
        baseSize = document.baseSize
        lineHeight = document.lineHeight
        textColorHex = document.textColorHex
        bgColorHex = document.bgColorHex
        accentColorHex = document.accentColorHex
        marginHorizontalPercent = document.marginHorizontalPercent
        mirrorHorizontal = document.mirrorHorizontal
        mirrorVertical = document.mirrorVertical
    }

    var asDocument: (String) -> PrompterDocument {
        { markdown in
            PrompterDocument(
                markdown: markdown,
                fontName: fontName,
                baseSize: baseSize,
                lineHeight: lineHeight,
                textColorHex: textColorHex,
                bgColorHex: bgColorHex,
                accentColorHex: accentColorHex,
                marginHorizontalPercent: marginHorizontalPercent,
                mirrorHorizontal: mirrorHorizontal,
                mirrorVertical: mirrorVertical
            )
        }
    }
}
