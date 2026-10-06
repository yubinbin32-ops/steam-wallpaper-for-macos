import Foundation
import WebKit
import AppKit

// MARK: - Official 1:1 Wallpaper Engine Web Wallpaper Bridge

@MainActor
public final class WebWallpaperBridge: NSObject, WKNavigationDelegate, @unchecked Sendable {
    public static let shared = WebWallpaperBridge()

    private var propertiesCache: [String: String] = [:]
    
    private override init() {
        super.init()
    }
    
    /// Parses properties from project.json general.properties
    public func loadProperties(from directoryURL: URL) -> String {
        let key = directoryURL.path
        if let cached = propertiesCache[key] { return cached }
        
        let projectJsonURL = directoryURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectJsonURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = obj["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: properties),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            propertiesCache[key] = "{}"
            return "{}"
        }
        
        propertiesCache[key] = jsonStr
        return jsonStr
    }
    
    /// Creates a WKWebViewConfiguration with official sandbox permissions and user script bridge
    public func createConfiguration(for directoryURL: URL) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        
        // Essential WebKit preferences for local file execution and WebGL
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let propsJSON = loadProperties(from: directoryURL)
        let bridgeScript = createBridgeUserScript(propertiesJSON: propsJSON)
        config.userContentController.addUserScript(bridgeScript)
        
        return config
    }
    
    /// Official Wallpaper Engine CEF/JavaScript Bridge
    public func createBridgeUserScript(propertiesJSON: String) -> WKUserScript {
        let source = """
        (function() {
            // 1. Official Wallpaper Engine Media Integration Constants
            window.wallpaperMediaIntegration = {
                PLAYBACK_STOPPED: 0,
                PLAYBACK_PLAYING: 1,
                PLAYBACK_PAUSED: 2,
                playback: {
                    STOPPED: 0,
                    PLAYING: 1,
                    PAUSED: 2
                }
            };

            // 2. Official Listeners Registry
            window.__wallpaperAudioListeners = [];
            window.wallpaperRegisterAudioListener = function(callback) {
                if (typeof callback === 'function') {
                    window.__wallpaperAudioListeners.push(callback);
                }
            };

            for (const kind of ["Status", "Properties", "Thumbnail", "Playback", "Timeline"]) {
                window["__wallpaperMedia" + kind + "Listeners"] = [];
                window["wallpaperRegisterMedia" + kind + "Listener"] = function(callback) {
                    if (typeof callback === 'function') {
                        window["__wallpaperMedia" + kind + "Listeners"].push(callback);
                    }
                };
            }

            window.wallpaperRequestRandomFileForProperty = function(property, callback) {
                if (typeof callback === 'function') callback("");
            };

            // 3. Staged Initial Properties
            window.__initialUserProperties = \(propertiesJSON);

            // 4. Reactive Property Listener Setter Hook (Guarantees zero race condition)
            let _listener = undefined;
            Object.defineProperty(window, 'wallpaperPropertyListener', {
                configurable: true,
                enumerable: true,
                get: function() { return _listener; },
                set: function(val) {
                    _listener = val;
                    if (val) {
                        setTimeout(function() {
                            if (typeof val.applyUserProperties === 'function' && window.__initialUserProperties) {
                                try { val.applyUserProperties(window.__initialUserProperties); } catch(e) { console.error(e); }
                            }
                            if (typeof val.applyGeneralProperties === 'function') {
                                try { val.applyGeneralProperties({ fps: 60 }); } catch(e) { console.error(e); }
                            }
                        }, 0);
                    }
                }
            });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - WKNavigationDelegate Safety Net
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let dispatchScript = """
        if (window.wallpaperPropertyListener) {
            if (typeof window.wallpaperPropertyListener.applyUserProperties === 'function' && window.__initialUserProperties) {
                try { window.wallpaperPropertyListener.applyUserProperties(window.__initialUserProperties); } catch(e) {}
            }
            if (typeof window.wallpaperPropertyListener.applyGeneralProperties === 'function') {
                try { window.wallpaperPropertyListener.applyGeneralProperties({ fps: 60 }); } catch(e) {}
            }
        }
        """
        webView.evaluateJavaScript(dispatchScript, completionHandler: nil)
    }
}
