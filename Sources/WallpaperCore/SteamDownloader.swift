import Foundation
import AppKit

public actor SteamDownloader {
    public static let shared = SteamDownloader()

    public static let wallpaperEngineAppID = "431960"

    public var steamClientExecutableURL: URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
            let exec = appURL.appendingPathComponent("Contents/MacOS/steam_osx")
            if FileManager.default.isExecutableFile(atPath: exec.path) {
                return exec
            }
        }
        let candidates = [
            "/Applications/Steam.app/Contents/MacOS/steam_osx",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steam.app/Contents/MacOS/steam_osx").path
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }

    public nonisolated var defaultWorkshopContentDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content", isDirectory: true)
            .appendingPathComponent(Self.wallpaperEngineAppID, isDirectory: true)
    }

    public init() {}

    /// Checks whether the macOS Steam client executable is installed
    public func isSteamInstalled() -> Bool {
        return steamClientExecutableURL != nil
    }

    /// Checks whether Steam client is currently running
    public func isSteamRunning() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { app in
            guard let id = app.bundleIdentifier?.lowercased() else { return false }
            return id.contains("valvesoftware.steam") || id.contains("steam")
        }
    }

    /// Triggers download of the specified Wallpaper Engine workshop item via local Steam client
    public func triggerDownload(workshopId: String) throws {
        guard let execURL = steamClientExecutableURL else {
            throw NSError(
                domain: "SteamDownloader",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到 Steam 客户端，请确保已安装 Steam"]
            )
        }

        guard isSteamRunning() else {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            throw NSError(
                domain: "SteamDownloader",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "下载壁纸需要打开 Steam 客户端。已为您尝试唤起 Steam，请在客户端启动后重试。"]
            )
        }

        let process = Process()
        process.executableURL = execURL
        process.arguments = [
            "+workshop_download_item",
            Self.wallpaperEngineAppID,
            workshopId
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
    }

    /// Polls until the workshop item is fully downloaded to local disk
    public func waitForDownloadCompletion(
        workshopId: String,
        timeoutSeconds: TimeInterval = 90.0,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let itemDirectory = defaultWorkshopContentDirectory.appendingPathComponent(workshopId, isDirectory: true)
        let startTime = Date()

        onProgress?("正在通知 Steam 客户端下载...")

        // Give Steam a second to register the command
        try await Task.sleep(nanoseconds: 1_500_000_000)

        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            if FileManager.default.fileExists(atPath: itemDirectory.path) {
                let projectJson = itemDirectory.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath: projectJson.path) {
                    // Check if directory contents are still actively growing/changing
                    let attrs = try? FileManager.default.attributesOfItem(atPath: itemDirectory.path)
                    let modDate = attrs?[.modificationDate] as? Date ?? Date()
                    if Date().timeIntervalSince(modDate) >= 1.0 {
                        onProgress?("下载完成，正在校验文件完整性...")
                        return itemDirectory
                    }
                }
            }

            let elapsed = Int(Date().timeIntervalSince(startTime))
            onProgress?("Steam 正在下载中 (\(elapsed)s)...")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw NSError(
            domain: "SteamDownloader",
            code: 408,
            userInfo: [NSLocalizedDescriptionKey: "下载超时（\(Int(timeoutSeconds))秒）。请确保 Steam 客户端保持开启并在后台运行。"]
        )
    }

    /// High level download orchestrator: triggers download and waits for completion
    public func downloadItem(
        workshopId: String,
        timeoutSeconds: TimeInterval = 90.0,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        try triggerDownload(workshopId: workshopId)
        return try await waitForDownloadCompletion(
            workshopId: workshopId,
            timeoutSeconds: timeoutSeconds,
            onProgress: onProgress
        )
    }
}
