import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FilmklipparenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var editor = Editor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(editor)
                .environmentObject(editor.clock)
                .frame(minWidth: 1060, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}
