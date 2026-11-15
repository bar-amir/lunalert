import SwiftUI

@main
struct LunalertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar item and the Settings window are AppKit-managed (StatusItemController,
        // SettingsWindowController); SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}
