import SwiftUI

@main
struct CleanMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("CleanMac", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 740)

        MenuBarExtra("CleanMac", systemImage: "sparkles") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
