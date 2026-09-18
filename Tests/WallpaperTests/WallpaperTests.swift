import XCTest
import SpriteKit
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

    @MainActor
    private func allDescendants(of node: SKNode) -> [SKNode] {
        var results = node.children
        for child in node.children {
            results.append(contentsOf: allDescendants(of: child))
        }
        return results
    }
}
