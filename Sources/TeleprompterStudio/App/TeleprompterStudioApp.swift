import SwiftUI
import SwiftData

@main
struct TeleprompterStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let modelContainer: ModelContainer

    init() {
        // OpenDyslexic ships inside the SwiftPM resource bundle, which `UIAppFonts` can't see —
        // it has to be handed to Core Text ourselves, before anything renders a script.
        PrompterFonts.registerBundledFonts()

        let schema = Schema([
            Script.self,
            ScriptStyle.self,
            Folder.self,
            Recording.self,
            AppSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
