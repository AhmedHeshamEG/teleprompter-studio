import Foundation
import SwiftData

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = "New Folder"
    var order: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Script.folder)
    var scripts: [Script] = []

    init(name: String = "New Folder", order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.order = order
    }
}
