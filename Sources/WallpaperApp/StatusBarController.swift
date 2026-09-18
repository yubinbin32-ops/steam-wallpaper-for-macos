import AppKit
import WallpaperCore

@MainActor
public final class StatusBarController: NSObject {
    public static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var onOpenGallery: (() -> Void)?

    public func setup(onOpenGallery: @escaping () -> Void) {
        self.onOpenGallery = onOpenGallery

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "Steam Wallpaper")
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()

        let currentTitleItem = NSMenuItem(title: "壁纸: 准备中", action: nil, keyEquivalent: "")
        currentTitleItem.tag = 100
        currentTitleItem.isEnabled = false
        menu.addItem(currentTitleItem)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "打开壁纸库相册...", action: #selector(openGalleryClicked), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let togglePlayItem = NSMenuItem(title: "暂停播放", action: #selector(togglePlayClicked), keyEquivalent: "p")
        togglePlayItem.target = self
        togglePlayItem.tag = 101
        menu.addItem(togglePlayItem)

        let toggleMuteItem = NSMenuItem(title: "取消静音", action: #selector(toggleMuteClicked), keyEquivalent: "m")
        toggleMuteItem.target = self
        toggleMuteItem.tag = 102
        menu.addItem(toggleMuteItem)

        let nextItem = NSMenuItem(title: "切换下一款壁纸", action: #selector(nextWallpaperClicked), keyEquivalent: "n")
        nextItem.target = self
        menu.addItem(nextItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Wallpaper", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    public func updateTitle(_ title: String) {
        guard let menu = statusItem?.menu, let item = menu.item(withTag: 100) else { return }
        item.title = "壁纸: \(title)"
    }

    @objc private func openGalleryClicked() {
        onOpenGallery?()
    }

    @objc private func togglePlayClicked() {
        if DesktopEngine.shared.isPlaying {
            DesktopEngine.shared.pause()
        } else {
            DesktopEngine.shared.resume()
        }
        if let item = statusItem?.menu?.item(withTag: 101) {
            item.title = DesktopEngine.shared.isPlaying ? "暂停播放" : "恢复播放"
        }
    }

    @objc private func toggleMuteClicked() {
        DesktopEngine.shared.isMuted.toggle()
        if let item = statusItem?.menu?.item(withTag: 102) {
            item.title = DesktopEngine.shared.isMuted ? "开启壁纸原声" : "静音"
        }
    }

    @objc private func nextWallpaperClicked() {
        let store = WallpaperStore.shared
        let wallpapers = store.wallpapers
        guard !wallpapers.isEmpty else { return }

        if let currentId = store.activeWallpaperId,
           let currentIndex = wallpapers.firstIndex(where: { $0.id == currentId }) {
            let nextIndex = (currentIndex + 1) % wallpapers.count
            store.selectWallpaper(wallpapers[nextIndex])
        } else if let first = wallpapers.first {
            store.selectWallpaper(first)
        }
    }

    @objc private func quitClicked() {
        DesktopEngine.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}
