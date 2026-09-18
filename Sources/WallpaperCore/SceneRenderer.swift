import AppKit
import SpriteKit
import Foundation
import Metal
import CoreImage

// MARK: - PKG Archive Parser

final class ScenePKGParser: @unchecked Sendable {
    struct Entry {
        let path: String
        let offset: UInt32
        let length: UInt32
    }

    private let data: Data
    private let entries: [Entry]
    private let dataBaseOffset: Int

    init?(url: URL) {
        guard let fileData = try? Data(contentsOf: url) else { return nil }
        self.data = fileData

        let bytes = [UInt8](fileData)
        var cursor = 0

        func readU32() -> UInt32? {
            guard cursor + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[cursor])
                | (UInt32(bytes[cursor + 1]) << 8)
                | (UInt32(bytes[cursor + 2]) << 16)
                | (UInt32(bytes[cursor + 3]) << 24)
            cursor += 4
            return v
        }

        func readString(len: Int) -> String? {
            guard len >= 0, cursor + len <= bytes.count else { return nil }
            let slice = bytes[cursor..<cursor + len]
            cursor += len
            return String(bytes: slice, encoding: .utf8) ?? String(bytes: slice, encoding: .isoLatin1)
        }

        guard let headerLen = readU32(), headerLen < 100,
              let header = readString(len: Int(headerLen)),
              header.hasPrefix("PKGV") else { return nil }

        guard let entryCount = readU32(), entryCount < 100_000 else { return nil }

        var parsed: [Entry] = []
        parsed.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            guard let pathLen = readU32(), pathLen < 10_000,
                  let path = readString(len: Int(pathLen)),
                  let offset = readU32(),
                  let length = readU32() else { return nil }
            parsed.append(Entry(path: path, offset: offset, length: length))
        }

        self.entries = parsed
        self.dataBaseOffset = cursor
    }

    func extractFile(named name: String) -> Data? {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard let entry = entries.first(where: {
            $0.path == name || $0.path == normalized || $0.path.lowercased() == normalized.lowercased()
        }) else {
            return nil
        }
        let start = dataBaseOffset + Int(entry.offset)
        let end = start + Int(entry.length)
        guard end <= data.count else { return nil }
        return Data(data[start..<end])
    }
}

// MARK: - Dynamic & Resilient Codable Types

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

public struct FlexibleDouble: Codable, Sendable {
    public var value: Double = 0
    public init(value: Double = 0) { self.value = value }

    public init(from decoder: Decoder) throws {
        if let n = try? decoder.singleValueContainer().decode(Double.self) {
            self.value = n
            return
        }
        if let s = try? decoder.singleValueContainer().decode(String.self), let n = Double(s) {
            self.value = n
            return
        }
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            if let k = DynamicCodingKey(stringValue: "value") {
                if let n = try? container.decode(Double.self, forKey: k) {
                    self.value = n
                    return
                } else if let s = try? container.decode(String.self, forKey: k), let n = Double(s) {
                    self.value = n
                    return
                }
            }
        }
        self.value = 1.0
    }
}

public struct FlexibleBool: Codable, Sendable {
    public var value: Bool = true
    public init(value: Bool = true) { self.value = value }

    public init(from decoder: Decoder) throws {
        if let b = try? decoder.singleValueContainer().decode(Bool.self) {
            self.value = b
            return
        }
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.value = (s.lowercased() == "true" || s == "1")
            return
        }
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            if let k = DynamicCodingKey(stringValue: "value") {
                if let b = try? container.decode(Bool.self, forKey: k) {
                    self.value = b
                    return
                } else if let s = try? container.decode(String.self, forKey: k) {
                    self.value = (s.lowercased() == "true" || s == "1")
                    return
                }
            }
        }
        self.value = true
    }
}

public struct FlexibleVec3: Codable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var z: Double = 0

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x; self.y = y; self.z = z
    }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            let parts = s.split(separator: " ").compactMap { Double($0) }
            self.x = parts.count > 0 ? parts[0] : 0
            self.y = parts.count > 1 ? parts[1] : 0
            self.z = parts.count > 2 ? parts[2] : 0
            return
        }
        if let arr = try? decoder.singleValueContainer().decode([Double].self) {
            self.x = arr.count > 0 ? arr[0] : 0
            self.y = arr.count > 1 ? arr[1] : 0
            self.z = arr.count > 2 ? arr[2] : 0
            return
        }
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            if let k = DynamicCodingKey(stringValue: "value") {
                if let s = try? container.decode(String.self, forKey: k) {
                    let parts = s.split(separator: " ").compactMap { Double($0) }
                    self.x = parts.count > 0 ? parts[0] : 0
                    self.y = parts.count > 1 ? parts[1] : 0
                    self.z = parts.count > 2 ? parts[2] : 0
                    return
                } else if let arr = try? container.decode([Double].self, forKey: k) {
                    self.x = arr.count > 0 ? arr[0] : 0
                    self.y = arr.count > 1 ? arr[1] : 0
                    self.z = arr.count > 2 ? arr[2] : 0
                    return
                } else if let n = try? container.decode(Double.self, forKey: k) {
                    self.x = n; self.y = n; self.z = n
                    return
                }
            }
        }
        self.x = 0; self.y = 0; self.z = 0
    }
}

public struct FlexibleVec2: Codable, Sendable {
    public var x: Double = 0
    public var y: Double = 0

    public init(x: Double = 0, y: Double = 0) {
        self.x = x; self.y = y
    }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            let parts = s.split(separator: " ").compactMap { Double($0) }
            self.x = parts.count > 0 ? parts[0] : 0
            self.y = parts.count > 1 ? parts[1] : 0
            return
        }
        if let arr = try? decoder.singleValueContainer().decode([Double].self) {
            self.x = arr.count > 0 ? arr[0] : 0
            self.y = arr.count > 1 ? arr[1] : 0
            return
        }
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            if let k = DynamicCodingKey(stringValue: "value") {
                if let s = try? container.decode(String.self, forKey: k) {
                    let parts = s.split(separator: " ").compactMap { Double($0) }
                    self.x = parts.count > 0 ? parts[0] : 0
                    self.y = parts.count > 1 ? parts[1] : 0
                    return
                } else if let arr = try? container.decode([Double].self, forKey: k) {
                    self.x = arr.count > 0 ? arr[0] : 0
                    self.y = arr.count > 1 ? arr[1] : 0
                    return
                }
            }
        }
        self.x = 0; self.y = 0
    }
}

// MARK: - Scene Data Models

private struct SceneFileModel: Decodable {
    struct General: Decodable {
        struct Ortho: Decodable {
            let width: Int?
            let height: Int?
        }
        let orthogonalprojection: Ortho?
        let clearcolor: String?
    }

    struct ObjectModel: Decodable {
        let id: Int?
        let parent: Int?
        let name: String?
        let origin: FlexibleVec3?
        let scale: FlexibleVec3?
        let angles: FlexibleVec3?
        let visible: FlexibleBool?
        let image: String?
        let size: FlexibleVec2?
        let alpha: FlexibleDouble?
        let particle: String?
        struct InstanceOverride: Decodable {
            let rate: FlexibleDouble?
            let size: FlexibleDouble?
            let speed: FlexibleDouble?
            let lifetime: FlexibleDouble?
            let count: FlexibleDouble?
            let alpha: FlexibleDouble?
        }
        let instanceoverride: InstanceOverride?
    }

    let general: General?
    let objects: [ObjectModel]?

    enum CodingKeys: String, CodingKey {
        case general, objects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.general = try? c.decodeIfPresent(General.self, forKey: .general)

        var objs: [ObjectModel] = []
        if var arrContainer = try? c.nestedUnkeyedContainer(forKey: .objects) {
            while !arrContainer.isAtEnd {
                if let obj = try? arrContainer.decode(ObjectModel.self) {
                    objs.append(obj)
                } else {
                    struct Dummy: Decodable {}
                    _ = try? arrContainer.decode(Dummy.self)
                }
            }
        }
        self.objects = objs
    }
}

private struct WEModelFile: Decodable {
    let material: String?
    let puppet: String?
    let width: Int?
    let height: Int?
}

private struct WEMaterialFile: Decodable {
    struct Pass: Decodable {
        let blending: String?
        let textures: [String]?
    }
    let passes: [Pass]?
}

// MARK: - Metal Puppet Mesh Assembler (MDLV0021 / MDLV0023)

final class PuppetMeshAssembler: @unchecked Sendable {
    static let shared = PuppetMeshAssembler()

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let ciContext: CIContext?

    struct MetalVertex {
        var position: SIMD4<Float>
        var texCoord: SIMD2<Float>
    }

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            self.device = nil; self.queue = nil; self.pipeline = nil; self.ciContext = nil
            return
        }
        self.device = dev
        self.queue = q
        self.ciContext = CIContext(mtlDevice: dev)

        let metalSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float4 position;
            float2 texCoord;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut puppet_vert(const device VertexIn* verts [[buffer(0)]], uint vid [[vertex_id]]) {
            VertexOut out;
            out.position = verts[vid].position;
            out.texCoord = verts[vid].texCoord;
            return out;
        }

        fragment float4 puppet_frag(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return tex.sample(s, in.texCoord);
        }
        """
        if let lib = try? dev.makeLibrary(source: metalSrc, options: nil) {
            let pipeDesc = MTLRenderPipelineDescriptor()
            pipeDesc.vertexFunction = lib.makeFunction(name: "puppet_vert")
            pipeDesc.fragmentFunction = lib.makeFunction(name: "puppet_frag")
            pipeDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
            pipeDesc.colorAttachments[0].isBlendingEnabled = true
            pipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try? dev.makeRenderPipelineState(descriptor: pipeDesc)
        } else {
            self.pipeline = nil
        }
    }

    func assemble(mdlData: Data, sourceImage: NSImage, targetSize: CGSize) -> (SKTexture, CGSize)? {
        guard let device = self.device, let queue = self.queue, let pipeline = self.pipeline, let ciContext = self.ciContext else {
            return nil
        }

        guard let (verts, indices, actualSize) = parseMDLV(mdlData: mdlData, targetSize: targetSize) else {
            return nil
        }

        guard let cgImg = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let tw = cgImg.width, th = cgImg.height
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tw, height: th, mipmapped: false)
        guard let srcTex = device.makeTexture(descriptor: srcDesc) else { return nil }

        var rawBytes = [UInt8](repeating: 0, count: tw * th * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &rawBytes, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        ctx?.draw(cgImg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        srcTex.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: rawBytes, bytesPerRow: tw * 4)

        let rw = max(Int(actualSize.width), 1)
        let rh = max(Int(actualSize.height), 1)
        let tgtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: rw, height: rh, mipmapped: false)
        tgtDesc.usage = [.renderTarget, .shaderRead]
        guard let tgtTex = device.makeTexture(descriptor: tgtDesc) else { return nil }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = tgtTex
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(srcTex, index: 0)

        var drawnVerts: [MetalVertex] = []
        drawnVerts.reserveCapacity(indices.count)
        for idx in indices {
            guard Int(idx) < verts.count else { continue }
            drawnVerts.append(verts[Int(idx)])
        }

        let vBuf = device.makeBuffer(bytes: drawnVerts, length: drawnVerts.count * MemoryLayout<MetalVertex>.stride, options: [])
        encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawnVerts.count)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        guard let ci = CIImage(mtlTexture: tgtTex, options: nil),
              let outCG = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return (SKTexture(cgImage: outCG), actualSize)
    }

    private func parseMDLV(mdlData: Data, targetSize: CGSize) -> ([MetalVertex], [UInt16], CGSize)? {
        let bytes = [UInt8](mdlData)
        let markerSize = 9
        guard bytes.count > markerSize else { return nil }

        var mdlsOffset = bytes.count
        let mdlsMagic = Array("MDLS".utf8)
        for i in markerSize..<(bytes.count - 4) {
            if bytes[i] == mdlsMagic[0] && bytes[i+1] == mdlsMagic[1] && bytes[i+2] == mdlsMagic[2] && bytes[i+3] == mdlsMagic[3] {
                mdlsOffset = i
                break
            }
        }

        let vertexStride = 80
        var foundOffset: Int?
        var vBytes: Int = 0
        var iBytes: Int = 0

        for offset in markerSize..<(mdlsOffset - 8) {
            let candVBytes = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
            let vOffset = offset + 8
            let idxLenOffset = vOffset + Int(candVBytes)
            if candVBytes == 0 || candVBytes % UInt32(vertexStride) != 0 || idxLenOffset + 4 > mdlsOffset { continue }

            let candIBytes = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: idxLenOffset, as: UInt32.self) }
            let indicesOffset = idxLenOffset + 4
            if candIBytes == 0 || candIBytes % 6 != 0 || indicesOffset + Int(candIBytes) > mdlsOffset { continue }

            foundOffset = offset
            vBytes = Int(candVBytes)
            iBytes = Int(candIBytes)
            break
        }

        guard let offset = foundOffset else { return nil }
        let vertexCount = vBytes / vertexStride
        let vOffset = offset + 8
        let idxOffset = vOffset + vBytes + 4
        let indexCount = iBytes / 2

        var minX: Float = 0, maxX: Float = 0
        var minY: Float = 0, maxY: Float = 0

        struct RawV { var x: Float; var y: Float; var z: Float; var u: Float; var v: Float }
        var rawVerts: [RawV] = []
        rawVerts.reserveCapacity(vertexCount)

        for i in 0..<vertexCount {
            let vo = vOffset + i * vertexStride
            let x = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo, as: Float.self) }
            let y = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 4, as: Float.self) }
            let z = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 8, as: Float.self) }
            let u = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 72, as: Float.self) }
            let v = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 76, as: Float.self) }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            rawVerts.append(RawV(x: x, y: y, z: z, u: u, v: v))
        }

        let spanX = max(abs(minX), abs(maxX)) * 2.0
        let spanY = max(abs(minY), abs(maxY)) * 2.0
        let renderW = max(Float(targetSize.width), spanX)
        let renderH = max(Float(targetSize.height), spanY)

        var vertices: [MetalVertex] = []
        vertices.reserveCapacity(vertexCount)
        for rv in rawVerts {
            let ndcX = (2.0 * rv.x) / renderW
            let ndcY = (-2.0 * rv.y) / renderH
            vertices.append(MetalVertex(position: SIMD4<Float>(ndcX, ndcY, rv.z, 1.0), texCoord: SIMD2<Float>(rv.u, rv.v)))
        }

        var indices: [UInt16] = []
        indices.reserveCapacity(indexCount)
        for i in 0..<indexCount {
            let idx = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: idxOffset + i * 2, as: UInt16.self) }
            indices.append(idx)
        }

        return (vertices, indices, CGSize(width: CGFloat(renderW), height: CGFloat(renderH)))
    }
}


private struct ParticleDef: Decodable {
    struct Emitter: Decodable {
        let name: String?
        let rate: FlexibleDouble?
        let distancemax: FlexibleVec3?
        let origin: FlexibleVec3?
    }
    struct Initializer: Decodable {
        let name: String?
        let min: FlexibleVec3?
        let max: FlexibleVec3?
    }
    struct Operator: Decodable {
        let name: String?
        let gravity: FlexibleVec3?
        let drag: FlexibleDouble?
        let fadeintime: FlexibleDouble?
        let fadeouttime: FlexibleDouble?
    }
    struct Renderer: Decodable {
        let name: String?
        let length: FlexibleDouble?
    }

    let emitter: [Emitter]?
    let initializer: [Initializer]?
    let `operator`: [Operator]?
    let renderer: [Renderer]?
    let material: String?
    let maxcount: Int?
}

// MARK: - SceneRenderer Engine

@MainActor
public final class SceneRenderer {
    public static let shared = SceneRenderer()

    private var textureCache: [String: SKTexture] = [:]

    private init() {}

    /// Builds a universal, authentic real-time SpriteKit SKScene for any Wallpaper Engine directory.
    public func buildScene(for directoryURL: URL) -> SKScene? {
        let pkgURL = directoryURL.appendingPathComponent("scene.pkg")
        let pkgParser = ScenePKGParser(url: pkgURL)

        func readData(path: String) -> Data? {
            let direct = directoryURL.appendingPathComponent(path)
            if let d = try? Data(contentsOf: direct) { return d }
            let unpacked = directoryURL.appendingPathComponent("unpacked").appendingPathComponent(path)
            if let d = try? Data(contentsOf: unpacked) { return d }
            return pkgParser?.extractFile(named: path)
        }

        // 1. Load scene.json
        guard let sceneData = readData(path: "scene.json"),
              let sceneModel = try? JSONDecoder().decode(SceneFileModel.self, from: sceneData) else {
            return fallbackScene(directoryURL: directoryURL)
        }

        // 2. Setup Scene Canvas with Aspect Fill
        let projWidth = CGFloat(sceneModel.general?.orthogonalprojection?.width ?? 1920)
        let projHeight = CGFloat(sceneModel.general?.orthogonalprojection?.height ?? 1080)
        let sceneSize = CGSize(width: projWidth, height: projHeight)

        let skScene = SKScene(size: sceneSize)
        skScene.scaleMode = .aspectFill
        skScene.anchorPoint = CGPoint(x: 0.5, y: 0.5) // Center is (0, 0)

        if let clearStr = sceneModel.general?.clearcolor {
            let parts = clearStr.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 3 {
                skScene.backgroundColor = NSColor(red: parts[0], green: parts[1], blue: parts[2], alpha: 1.0)
            } else {
                skScene.backgroundColor = .black
            }
        } else {
            skScene.backgroundColor = .black
        }

        let objects = sceneModel.objects ?? []
        var nodesById: [Int: SKNode] = [:]
        var objectNodePairs: [(SceneFileModel.ObjectModel, SKNode)] = []
        var imageCount = 0

        // 3. First pass: Create nodes for all visible objects
        for (idx, obj) in objects.enumerated() {
            guard obj.visible?.value ?? true else { continue }

            let node: SKNode
            if let imageModelPath = obj.image,
               !imageModelPath.contains("composelayer") && !imageModelPath.contains("projectlayer") {
                if let sprite = createImageNode(obj: obj, imageModelPath: imageModelPath, readData: readData) {
                    node = sprite
                    imageCount += 1
                } else {
                    node = SKNode()
                }
            } else if let particlePath = obj.particle {
                if let emitter = createParticleNode(obj: obj, particlePath: particlePath, readData: readData, canvasSize: sceneSize) {
                    node = emitter
                } else {
                    node = SKNode()
                }
            } else {
                node = SKNode()
            }

            node.name = obj.name
            node.zPosition = CGFloat(idx)

            // Local transforms
            if let sc = obj.scale {
                let sx = sc.x != 0 ? sc.x : 1.0
                let sy = sc.y != 0 ? sc.y : 1.0
                node.xScale = CGFloat(sx)
                node.yScale = CGFloat(sy)
            }
            if let ang = obj.angles {
                node.zRotation = CGFloat(ang.z)
            }
            if let al = obj.alpha?.value {
                node.alpha = CGFloat(al)
            }

            if let oid = obj.id {
                nodesById[oid] = node
            }
            objectNodePairs.append((obj, node))
        }

        // 4. Second pass: Construct the Scene Graph Hierarchy (Parent-Child)
        for (obj, node) in objectNodePairs {
            if let pid = obj.parent, let parentNode = nodesById[pid] {
                // Local coordinate relative to parent
                let lx = obj.origin?.x ?? 0
                let ly = obj.origin?.y ?? 0
                node.position = CGPoint(x: lx, y: ly)
                parentNode.addChild(node)
            } else {
                // Root node: relative to scene center (0, 0)
                var posX: CGFloat = 0
                var posY: CGFloat = 0
                if let orig = obj.origin {
                    if abs(orig.x) > Double(sceneSize.width) * 0.25 || abs(orig.y) > Double(sceneSize.height) * 0.25 {
                        posX = CGFloat(orig.x) - sceneSize.width / 2
                        posY = CGFloat(orig.y) - sceneSize.height / 2
                    } else {
                        posX = CGFloat(orig.x)
                        posY = CGFloat(orig.y)
                    }
                }
                node.position = CGPoint(x: posX, y: posY)
                skScene.addChild(node)
            }
        }

        // 5. Fallback if no images could be resolved
        if imageCount == 0 {
            if let fallbackNode = createFallbackBackgroundNode(directoryURL: directoryURL, canvasSize: sceneSize) {
                skScene.addChild(fallbackNode)
            }
        }

        return skScene
    }

    // MARK: - Layer Node Creation

    private func createImageNode(obj: SceneFileModel.ObjectModel, imageModelPath: String, readData: (String) -> Data?) -> SKSpriteNode? {
        guard let modelData = readData(imageModelPath),
              let model = try? JSONDecoder().decode(WEModelFile.self, from: modelData),
              let materialPath = model.material,
              let matData = readData(materialPath),
              let material = try? JSONDecoder().decode(WEMaterialFile.self, from: matData) else {
            return nil
        }

        let blending = material.passes?.first?.blending ?? "translucent"
        guard let textureName = material.passes?.first?.textures?.first else { return nil }

        // Find texture file
        let matDir = (materialPath as NSString).deletingLastPathComponent
        var texData: Data?
        let candidates = [
            "\(matDir)/\(textureName).tex",
            "materials/\(textureName).tex",
            "\(textureName).tex",
            "\(matDir)/\(textureName).png",
            "materials/\(textureName).png",
            "\(textureName).png",
            "\(matDir)/\(textureName).jpg",
            "materials/\(textureName).jpg"
        ]

        for candidate in candidates {
            if let d = readData(candidate) {
                texData = d
                break
            }
        }

        guard let rawData = texData, let image = extractImage(from: rawData) else {
            return nil
        }

        let baseSize: CGSize
        if let sz = obj.size, sz.x > 0, sz.y > 0 {
            baseSize = CGSize(width: CGFloat(sz.x), height: CGFloat(sz.y))
        } else if let mw = model.width, let mh = model.height, mw > 0, mh > 0 {
            baseSize = CGSize(width: CGFloat(mw), height: CGFloat(mh))
        } else {
            baseSize = CGSize(width: image.size.width, height: image.size.height)
        }

        let sprite: SKSpriteNode
        if let puppetPath = model.puppet,
           let mdlData = readData(puppetPath),
           let (assembledTex, actualSize) = PuppetMeshAssembler.shared.assemble(mdlData: mdlData, sourceImage: image, targetSize: baseSize) {
            sprite = SKSpriteNode(texture: assembledTex)
            sprite.size = actualSize
        } else {
            let texture = SKTexture(image: image)
            sprite = SKSpriteNode(texture: texture)
            sprite.size = baseSize
        }

        sprite.blendMode = (blending == "additive") ? .add : .alpha
        return sprite
    }


    private func createFallbackBackgroundNode(directoryURL: URL, canvasSize: CGSize) -> SKSpriteNode? {
        var img: NSImage?
        for name in ["artwork.png", "preview.jpg", "preview.png", "preview.gif"] {
            let u = directoryURL.appendingPathComponent(name)
            if let image = NSImage(contentsOf: u) {
                img = image
                break
            }
        }
        guard let image = img else { return nil }

        let texture = SKTexture(image: image)
        let sprite = SKSpriteNode(texture: texture)

        // Compute aspect fill size so it NEVER stretches or distorts
        let imgW = image.size.width
        let imgH = image.size.height
        let scale = max(canvasSize.width / max(imgW, 1), canvasSize.height / max(imgH, 1))
        sprite.size = CGSize(width: imgW * scale, height: imgH * scale)
        sprite.position = CGPoint(x: 0, y: 0)
        sprite.zPosition = 0
        return sprite
    }

    // MARK: - Particle System Node Creation

    private func createParticleNode(obj: SceneFileModel.ObjectModel, particlePath: String, readData: (String) -> Data?, canvasSize: CGSize) -> SKEmitterNode? {
        guard let pData = readData(particlePath),
              let pDef = try? JSONDecoder().decode(ParticleDef.self, from: pData) else {
            return nil
        }

        let emitter = SKEmitterNode()
        let pathLower = particlePath.lowercased()
        let isRain = pathLower.contains("rain") || pathLower.contains("snow") || pathLower.contains("water")
        let isSmoke = pathLower.contains("smoke") || pathLower.contains("fog") || pathLower.contains("cloud")
        let isShootingStar = pathLower.contains("shootingstar")

        // 1. Lifetime
        var minLifetime: Double = 3.0
        var maxLifetime: Double = 6.0
        var minSize: Double = 10.0
        var maxSize: Double = 20.0
        var hasVelocity = false
        var avgVx: Double = 0.0
        var avgVy: Double = 0.0
        var baseAlpha: Double = isSmoke ? 0.05 : (isRain ? 0.35 : 0.7)

        for ini in pDef.initializer ?? [] {
            let name = ini.name?.lowercased() ?? ""
            if name.contains("lifetime") {
                minLifetime = ini.min?.x ?? 2.0
                maxLifetime = ini.max?.x ?? 5.0
            } else if name.contains("size") {
                minSize = ini.min?.x ?? 8.0
                maxSize = ini.max?.x ?? 20.0
            } else if name.contains("velocity") && !name.contains("angular") {
                if let maxV = ini.max, let minV = ini.min {
                    avgVx = (minV.x + maxV.x) / 2.0
                    avgVy = (minV.y + maxV.y) / 2.0
                    hasVelocity = true
                }
            } else if name.contains("alpha") {
                baseAlpha = ini.max?.x ?? (ini.min?.x ?? baseAlpha)
            }
        }

        if let overrideLifetime = obj.instanceoverride?.lifetime?.value, overrideLifetime > 0 {
            minLifetime *= overrideLifetime
            maxLifetime *= overrideLifetime
        }
        if let overrideSize = obj.instanceoverride?.size?.value, overrideSize > 0 {
            minSize *= overrideSize
            maxSize *= overrideSize
        }
        if let overrideAlpha = obj.instanceoverride?.alpha?.value {
            baseAlpha = overrideAlpha
        }

        let avgLifetime = max((minLifetime + maxLifetime) / 2.0, 0.2)
        emitter.particleLifetime = CGFloat(avgLifetime)
        emitter.particleLifetimeRange = CGFloat(max(maxLifetime - minLifetime, 0.0))

        // 2. Rate & Max Count capping (PREVENTS STROBE FLICKER & PARTICLE EXPLOSION)
        let maxCount = Double(pDef.maxcount ?? 100)
        let countFactor = obj.instanceoverride?.count?.value ?? 1.0
        let effectiveMaxCount = max(maxCount * countFactor, 1.0)

        let emConfig = pDef.emitter?.first
        var rawRate = emConfig?.rate?.value ?? 20.0
        if let overrideRate = obj.instanceoverride?.rate?.value, overrideRate > 0 {
            rawRate = min(rawRate * overrideRate, rawRate * 2.0)
        }
        // Cap rate so total alive particles never exceed effectiveMaxCount!
        let maxAllowedRate = effectiveMaxCount / avgLifetime
        let finalRate = min(rawRate, maxAllowedRate)
        emitter.particleBirthRate = CGFloat(finalRate)

        // 3. Emission range
        if let dist = emConfig?.distancemax {
            emitter.particlePositionRange = CGVector(dx: CGFloat(dist.x * 2), dy: CGFloat(dist.y * 2))
        } else {
            emitter.particlePositionRange = CGVector(dx: canvasSize.width, dy: canvasSize.height)
        }

        // 4. Particle Size
        let avgSize = max((minSize + maxSize) / 2.0, 2.0)
        if isRain && avgVy < -300 {
            emitter.particleSize = CGSize(width: max(avgSize * 0.35, 2.0), height: max(avgSize * 3.0, 6.0))
        } else {
            emitter.particleSize = CGSize(width: avgSize, height: avgSize)
        }
        emitter.particleScaleRange = CGFloat(max((maxSize - minSize) / max(avgSize, 1.0), 0.0))

        // 5. Velocity & Motion
        if hasVelocity {
            var speed = hypot(avgVx, avgVy)
            if let overrideSpeed = obj.instanceoverride?.speed?.value, overrideSpeed > 0 {
                speed *= overrideSpeed
            }
            emitter.particleSpeed = CGFloat(speed)
            emitter.emissionAngle = CGFloat(atan2(avgVy, avgVx))
            emitter.particleSpeedRange = CGFloat(speed * 0.2)
        } else if isRain {
            emitter.particleSpeed = 500
            emitter.emissionAngle = -CGFloat.pi / 2
        } else {
            // Calm floating stars / ambient dust - gentle drift, no strobe
            emitter.particleSpeed = 2.0
            emitter.particleSpeedRange = 4.0
            emitter.emissionAngle = 0
        }

        // 6. Operators: gravity & alpha
        for op in pDef.operator ?? [] {
            let opName = op.name?.lowercased() ?? ""
            if opName.contains("movement"), let g = op.gravity {
                emitter.xAcceleration = CGFloat(g.x)
                emitter.yAcceleration = CGFloat(g.y)
            }
        }

        // 7. Alpha & Texture selection (smooth, no instant pop-in/pop-out)
        emitter.particleAlpha = CGFloat(baseAlpha)
        emitter.particleAlphaRange = CGFloat(baseAlpha * 0.25)
        emitter.particleAlphaSpeed = 0.0 // Keep steady throughout lifetime

        if isRain {
            emitter.particleTexture = getRainTexture()
            emitter.particleBlendMode = .alpha
            emitter.particleColor = NSColor(calibratedWhite: 0.9, alpha: CGFloat(baseAlpha))
        } else if isSmoke {
            emitter.particleTexture = getSmokeTexture()
            emitter.particleBlendMode = .alpha
            emitter.particleColor = NSColor(calibratedWhite: 0.7, alpha: CGFloat(baseAlpha))
        } else if isShootingStar {
            emitter.particleTexture = getShootingStarTexture()
            emitter.particleBlendMode = .add
            emitter.particleColor = NSColor(calibratedRed: 0.9, green: 0.95, blue: 1.0, alpha: CGFloat(baseAlpha))
        } else {
            emitter.particleTexture = getGlowTexture()
            emitter.particleBlendMode = .add
            emitter.particleColor = NSColor(calibratedRed: 0.85, green: 0.92, blue: 1.0, alpha: CGFloat(baseAlpha))
        }

        emitter.advanceSimulationTime(min(avgLifetime, 3.0))
        return emitter
    }


    // MARK: - Image & Texture Extraction

    private func extractImage(from data: Data) -> NSImage? {
        if let img = NSImage(data: data) { return img }

        let bytes = [UInt8](data)
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

        if let pngIdx = bytes.indices.first(where: { i in
            i + 3 < bytes.count && bytes[i] == pngMagic[0] && bytes[i+1] == pngMagic[1] && bytes[i+2] == pngMagic[2] && bytes[i+3] == pngMagic[3]
        }) {
            let slice = Data(bytes[pngIdx...])
            if let img = NSImage(data: slice) { return img }
        }

        if let jpegIdx = bytes.indices.first(where: { i in
            i + 1 < bytes.count && bytes[i] == 0xFF && bytes[i+1] == 0xD8
        }) {
            let slice = Data(bytes[jpegIdx...])
            if let img = NSImage(data: slice) { return img }
        }

        return nil
    }

    // MARK: - Procedural Particle Textures

    private func getRainTexture() -> SKTexture {
        if let cached = textureCache["rain"] { return cached }
        let w: CGFloat = 8
        let h: CGFloat = 32
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor.clear.cgColor,
                NSColor(calibratedWhite: 1.0, alpha: 0.8).cgColor,
                NSColor.clear.cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.5, 1.0]
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: w / 2, y: h), end: CGPoint(x: w / 2, y: 0), options: [])
            }
        }
        img.unlockFocus()
        let tex = SKTexture(image: img)
        textureCache["rain"] = tex
        return tex
    }

    private func getSmokeTexture() -> SKTexture {
        if let cached = textureCache["smoke"] { return cached }
        let size: CGFloat = 64
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor(calibratedWhite: 1.0, alpha: 0.35).cgColor,
                NSColor(calibratedWhite: 1.0, alpha: 0.15).cgColor,
                NSColor.clear.cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.5, 1.0]
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                ctx.drawRadialGradient(grad, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                                       endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size / 2, options: [])
            }
        }
        img.unlockFocus()
        let tex = SKTexture(image: img)
        textureCache["smoke"] = tex
        return tex
    }

    private func getGlowTexture() -> SKTexture {
        if let cached = textureCache["glow"] { return cached }
        let size: CGFloat = 64
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor.white.cgColor,
                NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 0.6).cgColor,
                NSColor.clear.cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.3, 1.0]
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                ctx.drawRadialGradient(grad, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                                       endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size / 2, options: [])
            }
        }
        img.unlockFocus()
        let tex = SKTexture(image: img)
        textureCache["glow"] = tex
        return tex
    }

    private func getShootingStarTexture() -> SKTexture {
        if let cached = textureCache["shootingstar"] { return cached }
        let w: CGFloat = 128
        let h: CGFloat = 32
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor.clear.cgColor,
                NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: 0.3).cgColor,
                NSColor.white.cgColor,
                NSColor.clear.cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.4, 0.85, 1.0]
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h / 2), end: CGPoint(x: w / 2, y: h / 2), options: [])
            }
        }
        img.unlockFocus()
        let tex = SKTexture(image: img)
        textureCache["shootingstar"] = tex
        return tex
    }

    private func fallbackScene(directoryURL: URL) -> SKScene? {
        var img: NSImage?
        for name in ["artwork.png", "preview.jpg", "preview.png", "preview.gif"] {
            let u = directoryURL.appendingPathComponent(name)
            if let image = NSImage(contentsOf: u) {
                img = image
                break
            }
        }
        guard let image = img else { return nil }

        let skScene = SKScene(size: image.size)
        skScene.scaleMode = .aspectFill
        skScene.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let sprite = SKSpriteNode(texture: SKTexture(image: image))
        sprite.size = image.size
        sprite.position = CGPoint(x: 0, y: 0)
        skScene.addChild(sprite)
        return skScene
    }
}
