import Foundation
import SwiftUI

@MainActor
public final class WallpaperStore: ObservableObject {
    public static let shared = WallpaperStore()

    @Published public var wallpapers: [WallpaperItem] = []
    @Published public var activeWallpaperId: String? {
        didSet {
            UserDefaults.standard.set(activeWallpaperId, forKey: "ActiveWallpaperID")
        }
    }
    @Published public var downloadState: DownloadState = .idle
    @Published public var searchText: String = ""

    private let defaultWorkshopDirectory: URL

    public init() {
        self.defaultWorkshopDirectory = SteamDownloader.shared.defaultWorkshopContentDirectory
        self.activeWallpaperId = UserDefaults.standard.string(forKey: "ActiveWallpaperID")
        refreshWallpapers()

        // Auto-play active wallpaper if present
        if let activeId = activeWallpaperId, let match = wallpapers.first(where: { $0.id == activeId }) {
            DesktopEngine.shared.play(wallpaper: match)
        }
    }

    /// Reloads all installed wallpapers from Steam workshop directory
    public func refreshWallpapers() {
        let items = WallpaperParser.shared.scanWorkshopDirectory(at: defaultWorkshopDirectory)
        self.wallpapers = items
    }

    /// Selects and plays a wallpaper
    public func selectWallpaper(_ item: WallpaperItem) {
        self.activeWallpaperId = item.id
        DesktopEngine.shared.play(wallpaper: item)
    }

    /// Full workflow: parse link -> download via Steam -> unpack -> add to library -> apply
    public func downloadAndApply(linkOrId: String) async {
        let trimmed = linkOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let workshopId = SteamWorkshopService.shared.extractWorkshopId(from: trimmed) else {
            self.downloadState = .failed(message: "无效的工坊链接或 ID")
            return
        }

        do {
            self.downloadState = .parsing(id: workshopId)
            let metadata = try await SteamWorkshopService.shared.fetchMetadata(for: workshopId)

            self.downloadState = .downloading(id: workshopId, message: "正在通过 Steam 客户端下载《\(metadata.title)》...")

            let downloadedDir = try await SteamDownloader.shared.downloadItem(
                workshopId: workshopId,
                timeoutSeconds: 120.0
            ) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.downloadState = .downloading(id: workshopId, message: status)
                }
            }

            self.downloadState = .unpacking(id: workshopId)
            let parsedItem = try WallpaperParser.shared.parseDirectory(at: downloadedDir)

            // Update in-memory list
            if let existingIndex = self.wallpapers.firstIndex(where: { $0.id == parsedItem.id }) {
                self.wallpapers[existingIndex] = parsedItem
            } else {
                self.wallpapers.insert(parsedItem, at: 0)
            }

            // Immediately apply to desktop
            self.selectWallpaper(parsedItem)
            self.downloadState = .completed(item: parsedItem)

            // Reset status after 4 seconds
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .completed = self.downloadState {
                self.downloadState = .idle
            }
        } catch {
            self.downloadState = .failed(message: error.localizedDescription)
        }
    }

    public var filteredWallpapers: [WallpaperItem] {
        if searchText.isEmpty {
            return wallpapers
        }
        return wallpapers.filter { item in
            item.title.localizedCaseInsensitiveContains(searchText) ||
            item.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }
}
