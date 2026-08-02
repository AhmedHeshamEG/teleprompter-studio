import Foundation
import SwiftData

enum DeviceRole: String, Codable, Sendable {
    case director
    case companion
    case unassigned
}

@Model
final class AppSettings {
    /// Singleton marker; the app always fetches/creates the single settings row via
    /// `AppSettings.current(in:)`.
    var singletonKey: String = "app-settings"

    var defaultSpeedPxPerSec: Double = 90
    var defaultFontSize: Double = 46

    var lanServerEnabled: Bool = false
    var lanPort: Int = 8080

    var lastRoleRaw: String = DeviceRole.unassigned.rawValue
    var lastRole: DeviceRole {
        get { DeviceRole(rawValue: lastRoleRaw) ?? .unassigned }
        set { lastRoleRaw = newValue.rawValue }
    }

    var mirrorFlipHorizontalDefault: Bool = false
    var mirrorFlipVerticalDefault: Bool = false

    init() {}

    @MainActor
    static func current(in context: ModelContext) -> AppSettings {
        let key = "app-settings"
        let descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate { $0.singletonKey == key }
        )
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = AppSettings()
        context.insert(created)
        try? context.save()
        return created
    }
}
