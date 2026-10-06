import XCTest
import SpriteKit
import WebKit
@testable import WallpaperCore

final class WallpaperTests: XCTestCase {
    func testWorkshopIdExtraction() {
        let service = SteamWorkshopService()

        XCTAssertEqual(service.extractWorkshopId(from: "3659880761"), "3659880761")
        XCTAssertEqual(service.extractWorkshopId(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=3659880761"), "3659880761")
        XCTAssertEqual(service.extractWorkshopId(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=3802068825&searchtext="), "3802068825")
        XCTAssertEqual(service.extractWorkshopId(from: "steam://url/CommunityFilePage/3802068825"), "3802068825")
    }

    func testParseDownloadedVideoDirectory() throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3802068825"
        let url = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let parser = WallpaperParser()
        let item = try parser.parseDirectory(at: url)

        XCTAssertEqual(item.id, "3802068825")
        XCTAssertEqual(item.type, .video)
        XCTAssertNotNil(item.videoURL)
        XCTAssertEqual(item.title, "yuki恋冢爱")
    }

    func testParseDownloadedSceneDirectory() throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3659880761"
        let url = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let parser = WallpaperParser()
        let item = try parser.parseDirectory(at: url)

        XCTAssertEqual(item.id, "3659880761")
        XCTAssertEqual(item.type, .scene)
        XCTAssertNil(item.videoURL)
        XCTAssertEqual(item.title, "超时空辉夜姬 八千代")
        XCTAssertNotNil(item.audioURL)
        XCTAssertNotNil(item.previewURL)
    }

    func testParseWebWallpaperDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectJSON = """
        {
            "file": "index.html",
            "title": "Interactive Matrix Rain",
            "type": "web",
            "workshopid": "9999999999",
            "tags": ["Cyberpunk", "Abstract"]
        }
        """
        try projectJSON.write(to: tempDir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "<html><body>Hello</body></html>".write(to: tempDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let parser = WallpaperParser()
        let item = try parser.parseDirectory(at: tempDir)

        XCTAssertEqual(item.id, "9999999999")
        XCTAssertEqual(item.type, .web)
        XCTAssertEqual(item.title, "Interactive Matrix Rain")
        XCTAssertNotNil(item.htmlURL)
        XCTAssertEqual(item.htmlURL?.lastPathComponent, "index.html")
    }

    @MainActor
    func testSceneRendererBuildSceneYachiyo() throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3659880761"
        let url = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let skScene = SceneRenderer.shared.buildScene(for: url)
        XCTAssertNotNil(skScene, "SceneRenderer should build an SKScene for 八千代")

        guard let scene = skScene else { return }
        XCTAssertEqual(scene.size.width, 3840)
        XCTAssertEqual(scene.size.height, 2160)
        XCTAssertEqual(scene.scaleMode, .aspectFill)

        let sprites = allDescendants(of: scene).compactMap { $0 as? SKSpriteNode }
        let emitters = allDescendants(of: scene).compactMap { $0 as? SKEmitterNode }

        XCTAssertGreaterThanOrEqual(sprites.count, 1)
        XCTAssertGreaterThanOrEqual(emitters.count, 3)
        print("八千代 Scene verified: \(sprites.count) sprite(s), \(emitters.count) particle emitter(s)")
    }

    @MainActor
    func testSceneRendererBuildSceneTakatsukiSen() throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3351179520"
        let url = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let skScene = SceneRenderer.shared.buildScene(for: url)
        XCTAssertNotNil(skScene, "SceneRenderer should build an SKScene for 高槻泉")

        guard let scene = skScene else { return }
        XCTAssertEqual(scene.size.width, 5120)
        XCTAssertEqual(scene.size.height, 1440)
        XCTAssertEqual(scene.scaleMode, .aspectFill)

        let sprites = allDescendants(of: scene).compactMap { $0 as? SKSpriteNode }
        let emitters = allDescendants(of: scene).compactMap { $0 as? SKEmitterNode }

        XCTAssertGreaterThanOrEqual(sprites.count, 5, "Should have multi-layer sprites (background, body, hair, hand)")
        XCTAssertGreaterThanOrEqual(emitters.count, 5, "Should have multi-layer rain and smoke particle systems")
        print("高槻泉 Scene verified: \(sprites.count) sprite(s), \(emitters.count) particle emitter(s)")
    }

    func testMetalTexDecoderOnRealWorkshop() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3659880761"
        let pkgURL = URL(fileURLWithPath: workshopPath).appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: pkgURL.path),
              let parser = ScenePKGParser(url: pkgURL) else { return }

        // Test RG88 LZ4 Mask decoding
        for maskName in ["materials/masks/shake_mask_4c8aa070.tex", "materials/masks/shake_mask_5e2a2127.tex", "materials/masks/shake_mask_54525ae6.tex"] {
            if let maskData = parser.extractFile(named: maskName) {
                let tex = MetalTextureDecoder.shared.decode(data: maskData, device: device)
                XCTAssertNotNil(tex, "Should decode \(maskName)")
                
                // Read back bytes and find where non-neutral pixels are
                let w = tex!.width, h = tex!.height
                var raw = [UInt8](repeating: 0, count: w * h * 2)
                tex!.getBytes(&raw, bytesPerRow: w * 2, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                var count = 0
                var minX = w, maxX = 0, minY = h, maxY = 0
                var maxRDiff = 0, maxGDiff = 0
                for y in 0..<h {
                    for x in 0..<w {
                        let idx = (y * w + x) * 2
                        let r = Int(raw[idx]), g = Int(raw[idx+1])
                        let rDiff = abs(r - 127), gDiff = abs(g - 127)
                        maxRDiff = max(maxRDiff, rDiff)
                        maxGDiff = max(maxGDiff, gDiff)
                        if rDiff > 3 || gDiff > 3 {
                            count += 1
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
                print("Mask \(maskName): active=\(count), X=[\(minX)..\(maxX)], Y=[\(minY)..\(maxY)] maxRDiff=\(maxRDiff), maxGDiff=\(maxGDiff)")
            }
        }

        // Test Embedded PNG texture decoding
        if let rippleData = parser.extractFile(named: "materials/effects/waterripplenormal.tex") {
            let tex = MetalTextureDecoder.shared.decode(data: rippleData, device: device)
            XCTAssertNotNil(tex, "Should decode ripple normal tex")
            print("Successfully decoded ripple normal texture: \(tex!.width)x\(tex!.height)")
        }
    }

    @MainActor
    func testMetalSceneEngineLoadSceneYachiyo() throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3659880761"
        let url = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let success = MetalSceneEngine.shared.loadScene(from: url)
        XCTAssertTrue(success, "MetalSceneEngine should load scene successfully")
        XCTAssertEqual(MetalSceneEngine.shared.canvasSize.width, 3840)
        XCTAssertEqual(MetalSceneEngine.shared.canvasSize.height, 2160)
        XCTAssertGreaterThanOrEqual(MetalSceneEngine.shared.layers.count, 1)
        XCTAssertGreaterThanOrEqual(MetalSceneEngine.shared.particleSystems.count, 1, "Should load GPU instanced particle systems")

        let layer = MetalSceneEngine.shared.layers.first
        XCTAssertNotNil(layer)
        XCTAssertEqual(layer?.passes.count, 5, "Layer should have 5 effects passes (waterripple, shake, iris, shake, shake)")
        print("MetalSceneEngine loaded successfully: \(MetalSceneEngine.shared.layers.count) layer(s), \(MetalSceneEngine.shared.particleSystems.count) particle system(s), layer has \(layer?.passes.count ?? 0) effect pass(es)!")

        // Test rendering a frame with both effects and particles
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 1080, mipmapped: false)
        outDesc.usage = [.renderTarget, .shaderRead]
        guard let outTex = dev.makeTexture(descriptor: outDesc) else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = outTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rpd.colorAttachments[0].storeAction = .store

        MetalSceneEngine.shared.render(
            to: outTex,
            renderPassDescriptor: rpd,
            time: 1.5,
            viewportSize: CGSize(width: 1920, height: 1080)
        )
        print("Successfully rendered a complete Metal Scene frame with all 5 passes and GPU particles!")
    }

    @MainActor
    func testMetalSceneEngineLoadScene3786653815() throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3786653815"
        let url = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let success = MetalSceneEngine.shared.loadScene(from: url)
        XCTAssertTrue(success, "MetalSceneEngine should load scene 3786653815 successfully from scene.pkg")
        XCTAssertGreaterThanOrEqual(MetalSceneEngine.shared.layers.count, 1)

        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        outDesc.usage = [.renderTarget, .shaderRead]
        guard let outTex = dev.makeTexture(descriptor: outDesc) else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = outTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rpd.colorAttachments[0].storeAction = .store

        MetalSceneEngine.shared.render(
            to: outTex,
            renderPassDescriptor: rpd,
            time: 2.0,
            viewportSize: CGSize(width: 1920, height: 1080)
        )
        print("Successfully rendered scene 3786653815 in native BGRA format!")
    }

    @MainActor
    func testWebWallpaperRhineLab() async throws {
        let workshopPath = "/Users/a1-6/Library/Application Support/Steam/steamapps/workshop/content/431960/3799142774"
        let dirURL = URL(fileURLWithPath: workshopPath)
        guard FileManager.default.fileExists(atPath: dirURL.path) else { return }

        let parser = WallpaperParser()
        let item = try parser.parseDirectory(at: dirURL)
        XCTAssertEqual(item.type, .web)
        XCTAssertNotNil(item.htmlURL)
        guard let htmlURL = item.htmlURL else { return }

        let webConfig = WKWebViewConfiguration()
        webConfig.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webConfig.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: webConfig)
        webView.loadFileURL(htmlURL, allowingReadAccessTo: dirURL)

        // Wait a short bit for load
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Check if window.wallpaperPropertyListener exists
        let checkRes = try? await webView.evaluateJavaScript("typeof window.wallpaperPropertyListener")
        print("Initial wallpaperPropertyListener type: \(String(describing: checkRes))")

        // Parse project.json general.properties and inject
        let projectJsonURL = dirURL.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectJsonURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let general = obj["general"] as? [String: Any],
           let properties = general["properties"] as? [String: Any] {
            let jsonPropsData = try JSONSerialization.data(withJSONObject: properties)
            let jsonPropsStr = String(data: jsonPropsData, encoding: .utf8)!

            let applyScript = """
            if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyUserProperties) {
                window.wallpaperPropertyListener.applyUserProperties(\(jsonPropsStr));
                "applied";
            } else {
                "listener not ready";
            }
            """
            let applyRes = try? await webView.evaluateJavaScript(applyScript)
            print("applyUserProperties result: \(String(describing: applyRes))")
        }

        // Wait another 500ms and check host properties and canvas
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let hostRes = try? await webView.evaluateJavaScript("Object.keys(window.rhineWallpaperHost?.properties || {}).length")
        print("rhineWallpaperHost properties count: \(String(describing: hostRes))")

        let domRes = try? await webView.evaluateJavaScript("document.getElementById('stage')?.children.length || 0")
        print("Stage children count: \(String(describing: domRes))")

        let canvasRes = try? await webView.evaluateJavaScript("document.querySelector('canvas') !== null")
        print("Canvas element created: \(String(describing: canvasRes))")
    }

    @MainActor
    private func allDescendants(of node: SKNode) -> [SKNode] {
        var results = node.children
        for child in node.children {
            results.append(contentsOf: allDescendants(of: child))
        }
        return results
    }
}
