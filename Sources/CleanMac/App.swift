import AppKit
import CoreServices
import SwiftUI

@main
struct CleanMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // The menu bar comes first so SwiftUI doesn't open the window by itself on launch.
        // AppDelegate decides, because a login launch must not show a window even briefly.
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Window("CleanMac", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 740)
    }
}

/// Exists from launch, unlike the menu's contents, so it can hand AppDelegate a way to open the window.
private struct MenuBarLabel: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "sparkles")
            .onAppear { appDelegate.windowOpenerIsReady { openWindow(id: "main") } }
    }
}

/// True when macOS launched the app as a login item rather than the user opening it.
func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
    guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
    return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
}

/// A login launch stays in the menu bar only, with no window or Dock icon, until the user opens the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openMainWindow: (() -> Void)?
    private var opensWindowOnLaunch: Bool?

    // The launch event is only available from here: AppKit handles it after willFinishLaunching.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let isLogin = isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        if isLogin { NSApp.setActivationPolicy(.accessory) }
        opensWindowOnLaunch = !isLogin
        finishLaunchIfReady()
    }

    func windowOpenerIsReady(_ open: @escaping () -> Void) {
        openMainWindow = open
        finishLaunchIfReady()
    }

    // Launching from Finder, the Dock or Spotlight while the app is hidden lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return false
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The label and didFinishLaunching can arrive in either order.
    private func finishLaunchIfReady() {
        guard openMainWindow != nil, let opensWindow = opensWindowOnLaunch else { return }
        opensWindowOnLaunch = nil
        if opensWindow { showMainWindow() }
    }
}
