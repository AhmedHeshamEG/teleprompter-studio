import Foundation
import SwiftData

enum CinematicKind: String, Codable, Sendable {
    case none
    case real   // iOS 26+ hardware Cinematic capture
    case synthetic // segmentation + Core Image bokeh fallback
}

enum CameraFacing: String, Codable, Sendable {
    case front
    case back
}

@Model
final class Recording {
    var id: UUID = UUID()
    var script: Script?
    /// Relative path within the app's Documents/Recordings directory (not an absolute
    /// sandbox URL, which can change between launches/installs).
    var relativePath: String = ""
    var createdAt: Date = Date()
    var durationSec: Double = 0
    var isCinematic: Bool = false
    var cinematicKind: CinematicKind = CinematicKind.none
    var cameraFacingRaw: String = CameraFacing.back.rawValue
    var resolutionWidth: Int = 1920
    var resolutionHeight: Int = 1080
    var savedToPhotos: Bool = false

    var cameraFacing: CameraFacing {
        get { CameraFacing(rawValue: cameraFacingRaw) ?? .back }
        set { cameraFacingRaw = newValue.rawValue }
    }

    init(
        script: Script? = nil,
        relativePath: String,
        durationSec: Double = 0,
        isCinematic: Bool = false,
        cinematicKind: CinematicKind = .none,
        cameraFacing: CameraFacing = .back,
        resolutionWidth: Int = 1920,
        resolutionHeight: Int = 1080
    ) {
        self.id = UUID()
        self.script = script
        self.relativePath = relativePath
        self.createdAt = Date()
        self.durationSec = durationSec
        self.isCinematic = isCinematic
        self.cinematicKind = cinematicKind
        self.cameraFacingRaw = cameraFacing.rawValue
        self.resolutionWidth = resolutionWidth
        self.resolutionHeight = resolutionHeight
    }

    func fileURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(relativePath)
    }
}
