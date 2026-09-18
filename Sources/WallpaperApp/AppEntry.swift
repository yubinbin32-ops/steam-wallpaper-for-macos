import SwiftUI
import AppKit
import WallpaperCore

@main
struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Steam Wallpaper for Mac", id: "gallery") {
            GalleryView()
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Setup Desktop engine and Windows
        DesktopEngine.shared.setupWindows()

        // Start Power Manager
        PowerManager.shared.startMonitoring()

        // Setup Menu Bar Item
        StatusBarController.shared.setup { [weak self] in
            self?.openGalleryWindow()
        }

        // Auto play active wallpaper if saved
        let store = WallpaperStore.shared
        if let activeId = store.activeWallpaperId,
           let activeItem = store.wallpapers.first(where: { $0.id == activeId }) {
            DesktopEngine.shared.play(wallpaper: activeItem)
            StatusBarController.shared.updateTitle(activeItem.title)
        } else if let first = store.wallpapers.first {
            store.selectWallpaper(first)
            StatusBarController.shared.updateTitle(first.title)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openGalleryWindow()
        }
    }

    func openGalleryWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let desktopLevel = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        for window in NSApp.windows where window.level != desktopLevel {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in background / menu bar when main window is closed!
        return false
    }
}
