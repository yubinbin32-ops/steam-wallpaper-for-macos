import AppKit
import AVFoundation
import QuartzCore
import SpriteKit
import WebKit

final class AspectFillView: NSView {
    var image: NSImage? {
        didSet {
            if let image = image {
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    layer?.contents = cg
                } else {
                    layer?.contents = image
                }
            } else {
                layer?.contents = nil
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
    }
}

final class DesktopWallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class DesktopEngine: NSObject, ObservableObject {
    public static let shared = DesktopEngine()

    @Published public private(set) var currentWallpaper: WallpaperItem?
    @Published public private(set) var isPlaying: Bool = false
    @Published public var isMuted: Bool = true {
        didSet {
            player?.isMuted = isMuted
            audioPlayer?.isMuted = isMuted
            for webView in webViews {
                webView.evaluateJavaScript("""
                var audios = document.querySelectorAll('audio, video');
                audios.forEach(function(a) { a.muted = \(isMuted); });
                """, completionHandler: nil)
            }
        }
    }
    @Published public var volume: Float = 0.5 {
        didSet {
            player?.volume = volume
            audioPlayer?.volume = volume
            for webView in webViews {
                webView.evaluateJavaScript("""
                var audios = document.querySelectorAll('audio, video');
                audios.forEach(function(a) { a.volume = \(volume); });
                """, completionHandler: nil)
            }
        }
    }

    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayers: [AVPlayerLayer] = []
    private var audioPlayer: AVQueuePlayer?
    private var audioLooper: AVPlayerLooper?

    private var imageViews: [AspectFillView] = []
    private var skViews: [SKView] = []
    private var metalViews: [MetalSceneView] = []
    private var webViews: [WKWebView] = []
    private var mouseMonitor: Any?

    public override init() {
        super.init()
    }

    /// Sets up desktop windows across all attached displays
    public func setupWindows() {
        // Close existing windows
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        playerLayers.removeAll()
        imageViews.removeAll()
        for skView in skViews {
            skView.presentScene(nil)
        }
        skViews.removeAll()
        for mView in metalViews {
            mView.isPaused = true
            mView.removeFromSuperview()
        }
        metalViews.removeAll()
        for webView in webViews {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webViews.removeAll()

        for screen in NSScreen.screens {
            let window = createDesktopWindow(for: screen)
            windows.append(window)
        }
    }

    private func createDesktopWindow(for screen: NSScreen) -> NSWindow {
        let window = DesktopWallpaperWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // Set below desktop icons
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        window.level = NSWindow.Level(desktopLevel)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .black
        window.ignoresMouseEvents = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true

        // 1. Image layer for preview / static fallback with true Aspect Fill
        let imageView = AspectFillView(frame: contentView.bounds)
        contentView.addSubview(imageView)
        imageViews.append(imageView)

        // 2. SpriteKit SKView for real-time Scene fallback
        let skView = SKView(frame: contentView.bounds)
        skView.autoresizingMask = [.width, .height]
        skView.ignoresSiblingOrder = true
        skView.allowsTransparency = false
        skView.preferredFramesPerSecond = 60
        skView.isHidden = true
        contentView.addSubview(skView)
        skViews.append(skView)

        // 3. MetalSceneView for hardware-accelerated authentic Scene rendering (1:1 MSL Effects)
        let metalView = MetalSceneView(frame: contentView.bounds)
        metalView.autoresizingMask = [.width, .height]
        metalView.isHidden = true
        contentView.addSubview(metalView)
        metalViews.append(metalView)

        // 4. AVPlayerLayer for native 60fps hardware-accelerated video
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = contentView.bounds
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.isHidden = true
        contentView.layer?.addSublayer(playerLayer)
        playerLayers.append(playerLayer)

        window.contentView = contentView
        window.orderFront(nil)
        return window
    }

    /// Plays the given wallpaper item
    public func play(wallpaper: WallpaperItem) {
        self.currentWallpaper = wallpaper

        if windows.isEmpty {
            setupWindows()
        }

        // Stop current playback
        player?.pause()
        player = nil
        playerLooper = nil
        audioPlayer?.pause()
        audioPlayer = nil
        audioLooper = nil

        if wallpaper.type == .web, let htmlURL = wallpaper.htmlURL {
            // Interactive HTML5 / WebGL / Canvas Web Wallpaper (1:1 Wallpaper Engine Runtime)
            for layer in playerLayers {
                layer.player = nil
                layer.isHidden = true
            }
            for skView in skViews {
                skView.isPaused = true
                skView.isHidden = true
                skView.presentScene(nil)
            }
            for mView in metalViews {
                mView.isPaused = true
                mView.isHidden = true
            }
            for imgView in imageViews {
                imgView.isHidden = true
            }

            // Clean up old web views
            for webView in webViews {
                webView.stopLoading()
                webView.removeFromSuperview()
            }
            webViews.removeAll()

            // Initialize fresh WKWebViews configured with 1:1 Wallpaper Engine JavaScript Bridge
            let config = WebWallpaperBridge.shared.createConfiguration(for: wallpaper.localDirectoryURL)
            for window in windows {
                guard let contentView = window.contentView else { continue }
                let webView = WKWebView(frame: contentView.bounds, configuration: config)
                webView.navigationDelegate = WebWallpaperBridge.shared
                webView.autoresizingMask = [.width, .height]
                webView.setValue(false, forKey: "drawsBackground")
                contentView.addSubview(webView)
                webViews.append(webView)
                webView.loadFileURL(htmlURL, allowingReadAccessTo: wallpaper.localDirectoryURL)
            }

            // Setup global mouse cursor tracking for Web Wallpaper HUD parallax & 3D tilt
            if mouseMonitor == nil {
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.currentWallpaper?.type == .web else { return }
                        for (idx, wView) in self.webViews.enumerated() {
                            guard idx < self.windows.count else { continue }
                            let win = self.windows[idx]
                            let screenH = win.frame.height
                            let mouseLoc = event.locationInWindow
                            let x = Int(mouseLoc.x)
                            let y = Int(screenH - mouseLoc.y)
                            let js = """
                            window.dispatchEvent(new MouseEvent('mousemove', {
                                clientX: \(x),
                                clientY: \(y),
                                screenX: \(x),
                                screenY: \(y),
                                bubbles: true
                            }));
                            """
                            wView.evaluateJavaScript(js, completionHandler: nil)
                        }
                    }
                }
            }

            self.isPlaying = true

        } else {
            // Remove web mouse tracking when playing scene or video
            if let m = mouseMonitor {
                NSEvent.removeMonitor(m)
                mouseMonitor = nil
            }
            for webView in webViews {
                webView.stopLoading()
                webView.removeFromSuperview()
            }
            webViews.removeAll()
        }

        if wallpaper.type == .scene {
            // 1. Hardware-accelerated Metal Scene Rendering (1:1 MSL Effects Pipeline)
            for layer in playerLayers {
                layer.player = nil
                layer.isHidden = true
            }
            for imgView in imageViews {
                imgView.isHidden = true
            }

            let metalLoaded = MetalSceneEngine.shared.loadScene(from: wallpaper.localDirectoryURL)
            if metalLoaded {
                for skView in skViews {
                    skView.isPaused = true
                    skView.isHidden = true
                    skView.presentScene(nil)
                }
                for mView in metalViews {
                    mView.isPaused = false
                    mView.isHidden = false
                }
            } else {
                for mView in metalViews {
                    mView.isPaused = true
                    mView.isHidden = true
                }
                var sceneLoaded = false
                for skView in skViews {
                    if let scene = SceneRenderer.shared.buildScene(for: wallpaper.localDirectoryURL) {
                        skView.presentScene(scene)
                        skView.isPaused = false
                        skView.isHidden = false
                        sceneLoaded = true
                    }
                }

                if !sceneLoaded {
                    // Fallback to static image if scene parsing failed
                    if let previewURL = wallpaper.previewURL, let image = NSImage(contentsOf: previewURL) {
                        for imgView in imageViews {
                            imgView.image = image
                            imgView.isHidden = false
                        }
                    }
                }
            }

            // Play accompanying uncompressed BGM (e.g. FLAC / MP3)
            startAudioPlayback(for: wallpaper)
            self.isPlaying = true

        } else if let videoURL = wallpaper.videoURL {
            // Hardware-accelerated Video Wallpaper
            for skView in skViews {
                skView.isPaused = true
                skView.isHidden = true
                skView.presentScene(nil)
            }
            for mView in metalViews {
                mView.isPaused = true
                mView.isHidden = true
            }
            for imgView in imageViews {
                imgView.isHidden = true
            }

            let asset = AVURLAsset(url: videoURL)
            let item = AVPlayerItem(asset: asset)
            let queuePlayer = AVQueuePlayer(playerItem: item)
            queuePlayer.isMuted = isMuted
            queuePlayer.volume = volume

            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            self.player = queuePlayer
            self.playerLooper = looper

            for layer in playerLayers {
                layer.player = queuePlayer
                layer.isHidden = false
            }

            queuePlayer.play()
            self.isPlaying = true

            startAudioPlayback(for: wallpaper)
        } else {
            // Static image fallback
            for skView in skViews {
                skView.isPaused = true
                skView.isHidden = true
                skView.presentScene(nil)
            }
            for mView in metalViews {
                mView.isPaused = true
                mView.isHidden = true
            }
            for layer in playerLayers {
                layer.player = nil
                layer.isHidden = true
            }
            if let previewURL = wallpaper.previewURL, let image = NSImage(contentsOf: previewURL) {
                for imgView in imageViews {
                    imgView.image = image
                    imgView.isHidden = false
                }
            }

            startAudioPlayback(for: wallpaper)
            self.isPlaying = true
        }
    }

    private func startAudioPlayback(for wallpaper: WallpaperItem) {
        guard let audioURL = wallpaper.audioURL else { return }
        let audioAsset = AVURLAsset(url: audioURL)
        let audioItem = AVPlayerItem(asset: audioAsset)
        let aPlayer = AVQueuePlayer(playerItem: audioItem)
        aPlayer.isMuted = isMuted
        aPlayer.volume = volume
        let aLooper = AVPlayerLooper(player: aPlayer, templateItem: audioItem)
        self.audioPlayer = aPlayer
        self.audioLooper = aLooper
        aPlayer.play()
    }

    public func pause() {
        player?.pause()
        audioPlayer?.pause()
        for skView in skViews {
            skView.isPaused = true
        }
        for webView in webViews {
            webView.evaluateJavaScript("""
            if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.setPaused) {
                window.wallpaperPropertyListener.setPaused(true);
            }
            if (window.onPause) window.onPause();
            """, completionHandler: nil)
        }
        isPlaying = false
    }

    public func resume() {
        player?.play()
        audioPlayer?.play()
        for skView in skViews {
            skView.isPaused = false
        }
        for webView in webViews {
            webView.evaluateJavaScript("""
            if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.setPaused) {
                window.wallpaperPropertyListener.setPaused(false);
            }
            if (window.onResume) window.onResume();
            """, completionHandler: nil)
        }
        isPlaying = true
    }

    public func stop() {
        pause()
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
        for webView in webViews {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webViews.removeAll()
        currentWallpaper = nil
        audioLooper = nil
        audioPlayer = nil
        playerLooper = nil
        player = nil
        for skView in skViews {
            skView.isPaused = true
            skView.presentScene(nil)
            skView.isHidden = true
        }
        for layer in playerLayers {
            layer.player = nil
            layer.isHidden = true
        }
        for imgView in imageViews {
            imgView.image = nil
            imgView.isHidden = true
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        playerLayers.removeAll()
        imageViews.removeAll()
        skViews.removeAll()
    }
}
