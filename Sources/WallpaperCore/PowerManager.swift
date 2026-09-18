import AppKit
import Foundation

@MainActor
public final class PowerManager: ObservableObject {
    public static let shared = PowerManager()

    @Published public var pauseOnFullScreen: Bool = true
    @Published public var pauseOnBattery: Bool = false
    @Published public private(set) var isSuspendedForPowerSaving: Bool = false

    private var timer: Timer?

    public init() {
        startMonitoring()
    }

    public func startMonitoring() {
        timer?.invalidate()
        // Check window state periodically (every 2.0s) to be completely non-intrusive and low CPU
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluatePlaybackState()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluatePlaybackState()
            }
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func evaluatePlaybackState() {
        guard DesktopEngine.shared.currentWallpaper != nil else { return }

        var shouldPause = false

        if pauseOnBattery && ProcessInfo.processInfo.isLowPowerModeEnabled {
            shouldPause = true
        }

        if pauseOnFullScreen && isAnyApplicationFullScreen() {
            shouldPause = true
        }

        if shouldPause {
            if !isSuspendedForPowerSaving {
                isSuspendedForPowerSaving = true
                DesktopEngine.shared.pause()
            }
        } else {
            if isSuspendedForPowerSaving {
                isSuspendedForPowerSaving = false
                DesktopEngine.shared.resume()
            }
        }
    }

    /// Checks if any on-screen window currently covers the entire primary screen
    private func isAnyApplicationFullScreen() -> Bool {
        guard let mainScreen = NSScreen.main else { return false }
        let screenBounds = mainScreen.frame

        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for info in windowInfoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let windowLayer = info[kCGWindowLayer as String] as? Int,
                  windowLayer == 0, // Normal window layer
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else {
                continue
            }

            // In CG coordinate system (top-left is 0,0)
            if width >= screenBounds.width && height >= screenBounds.height {
                // If it covers the whole screen and is not our app or finder desktop
                if let ownerName = info[kCGWindowOwnerName as String] as? String,
                   ownerName != "Finder", ownerName != "WallpaperApp" {
                    return true
                }
            }
        }

        return false
    }
}
