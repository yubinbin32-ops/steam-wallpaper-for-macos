import Foundation
import Metal
import MetalKit
import CoreGraphics
import AppKit
import simd

// MARK: - Pure Swift LZ4 Block Decompressor

public enum LZ4BlockDecompressor {
    public static func decompress(compressed: Data, decompressedSize: Int) -> Data? {
        let bytes = [UInt8](compressed)
        var dst = [UInt8]()
        dst.reserveCapacity(decompressedSize)
        
        var srcPos = 0
        let srcLen = bytes.count
        
        while srcPos < srcLen {
            let token = bytes[srcPos]
            srcPos += 1
            
            var litLen = Int(token >> 4)
            if litLen == 15 {
                while srcPos < srcLen {
                    let s = Int(bytes[srcPos])
                    srcPos += 1
                    litLen += s
                    if s != 255 { break }
                }
            }
            
            // Copy literals
            if srcPos + litLen > srcLen { break }
            dst.append(contentsOf: bytes[srcPos..<(srcPos + litLen)])
            srcPos += litLen
            if srcPos >= srcLen { break }
            
            // Read 16-bit offset
            guard srcPos + 2 <= srcLen else { break }
            let offset = Int(bytes[srcPos]) | (Int(bytes[srcPos + 1]) << 8)
            srcPos += 2
            guard offset > 0, offset <= dst.count else { break }
            
            var matchLen = Int(token & 0x0F) + 4
            if (token & 0x0F) == 15 {
                while srcPos < srcLen {
                    let s = Int(bytes[srcPos])
                    srcPos += 1
                    matchLen += s
                    if s != 255 { break }
                }
            }
            
            // Copy match
            let start = dst.count - offset
            for i in 0..<matchLen {
                dst.append(dst[start + i])
            }
        }
        
        return Data(dst)
    }
}

// MARK: - Metal Texture Decoder (TEXV0005 / TEXI0001 / TEXB0004)

public final class MetalTextureDecoder: @unchecked Sendable {
    public static let shared = MetalTextureDecoder()
    
    private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    private let jpgMagic: [UInt8] = [0xFF, 0xD8, 0xFF]
    private var defaultParticleTexture: MTLTexture?
    
    private init() {}
    
    public func getDefaultParticleTexture(device: MTLDevice) -> MTLTexture {
        if let tex = defaultParticleTexture { return tex }
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - 31.5) / 31.5
                let dy = (Double(y) - 31.5) / 31.5
                let r = sqrt(dx * dx + dy * dy)
                let a = max(0.0, 1.0 - r) * exp(-2.0 * r * r)
                let alpha = UInt8(min(max(a * 255.0, 0.0), 255.0))
                let idx = (y * size + x) * 4
                bytes[idx] = 255
                bytes[idx + 1] = 255
                bytes[idx + 2] = 255
                bytes[idx + 3] = alpha
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size * 4)
        self.defaultParticleTexture = tex
        return tex
    }
    
    public func decode(data: Data, device: MTLDevice) -> MTLTexture? {
        let bytes = [UInt8](data)
        
        // 1. Direct Embedded PNG/JPEG detection
        if let pngIdx = findMagic(bytes: bytes, magic: pngMagic) {
            let slice = Data(bytes[pngIdx...])
            if let tex = createTextureFromImageData(slice, device: device) {
                return tex
            }
        }
        if let jpgIdx = findMagic(bytes: bytes, magic: jpgMagic) {
            let slice = Data(bytes[jpgIdx...])
            if let tex = createTextureFromImageData(slice, device: device) {
                return tex
            }
        }
        
        // 2. Binary TEXV / TEXI / TEXB parsing
        guard let texiIdx = data.range(of: "TEXI0001\0".data(using: .utf8)!)?.lowerBound,
              let texbIdx = data.range(of: "TEXB0004\0".data(using: .utf8)!)?.lowerBound else {
            return nil
        }
        
        let texiStart = texiIdx + 9
        guard texiStart + 24 <= data.count else { return nil }
        
        let format = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: texiStart, as: UInt32.self) }
        let width = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: texiStart + 8, as: UInt32.self) })
        let height = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: texiStart + 12, as: UInt32.self) })
        
        // Read TEXB header
        let texbStart = texbIdx + 9
        guard texbStart + 16 <= data.count else { return nil }
        
        let freeImageFmt = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: texbStart + 4, as: Int32.self) }
        let isVideoMp4 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: texbStart + 8, as: Int32.self) }
        guard isVideoMp4 == 0 else { return nil }
        
        if freeImageFmt != -1 && freeImageFmt != 0 {
            let searchSlice = Data(bytes[(texbStart + 16)...])
            if let img = createTextureFromImageData(searchSlice, device: device) {
                return img
            }
        }
        
        // Read mipmap data
        let mipStart = texbStart + 16
        guard mipStart + 20 <= data.count else { return nil }
        let mipW = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: mipStart, as: UInt32.self) })
        let mipH = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: mipStart + 4, as: UInt32.self) })
        let isLZ4 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: mipStart + 8, as: UInt32.self) }
        let decompSize = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: mipStart + 12, as: UInt32.self) })
        let byteCount = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: mipStart + 16, as: UInt32.self) })
        
        let rawPayloadStart = mipStart + 20
        guard rawPayloadStart + byteCount <= data.count else { return nil }
        let compressedPayload = data.subdata(in: rawPayloadStart..<(rawPayloadStart + byteCount))
        
        let pixelData: Data
        if isLZ4 == 1 {
            guard let decomp = LZ4BlockDecompressor.decompress(compressed: compressedPayload, decompressedSize: decompSize) else {
                return nil
            }
            pixelData = decomp
        } else {
            pixelData = compressedPayload
        }
        
        let finalW = mipW > 0 ? mipW : width
        let finalH = mipH > 0 ? mipH : height
        guard finalW > 0, finalH > 0 else { return nil }
        
        // Map Wallpaper Engine TexFormat to Metal MTLPixelFormat
        let mtlFormat: MTLPixelFormat
        let bytesPerRow: Int
        
        switch format {
        case 0: // RGBA8888
            mtlFormat = .rgba8Unorm
            bytesPerRow = finalW * 4
        case 4: // DXT5 / BC3
            mtlFormat = .bc3_rgba
            bytesPerRow = ((finalW + 3) / 4) * 16
        case 7: // DXT1 / BC1
            mtlFormat = .bc1_rgba
            bytesPerRow = ((finalW + 3) / 4) * 8
        case 8: // RG88
            mtlFormat = .rg8Unorm
            bytesPerRow = finalW * 2
        case 9: // R8
            mtlFormat = .r8Unorm
            bytesPerRow = finalW
        default:
            mtlFormat = .rgba8Unorm
            bytesPerRow = finalW * 4
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: mtlFormat, width: finalW, height: finalH, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        
        pixelData.withUnsafeBytes { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, finalW, finalH),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        
        return tex
    }
    
    public func createTextureFromImageData(_ data: Data, device: MTLDevice) -> MTLTexture? {
        guard let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = cgImage.width
        let h = cgImage.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        
        var rawBytes = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &rawBytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rawBytes, bytesPerRow: w * 4)
        return tex
    }
    
    private func findMagic(bytes: [UInt8], magic: [UInt8]) -> Int? {
        guard bytes.count >= magic.count else { return nil }
        for i in 0..<(bytes.count - magic.count) {
            var match = true
            for j in 0..<magic.count {
                if bytes[i + j] != magic[j] {
                    match = false
                    break
                }
            }
            if match { return i }
        }
        return nil
    }
}

// MARK: - Metal Shader Manager (1:1 MSL Transpiled Library)

public final class MetalShaderManager: @unchecked Sendable {
    public static let shared = MetalShaderManager()
    
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let linearSampler: MTLSamplerState
    public let repeatSampler: MTLSamplerState
    
    public let fullscreenVertFunc: MTLFunction
    public let layerVertFunc: MTLFunction
    public let layerFragFunc: MTLFunction
    
    // Offscreen Effect Pipelines (Render target: .rgba8Unorm)
    public let waterRipplePipeline: MTLRenderPipelineState
    public let shakePipeline: MTLRenderPipelineState
    public let irisPipeline: MTLRenderPipelineState
    public let flowPipeline: MTLRenderPipelineState
    public let spinPipeline: MTLRenderPipelineState
    public let blurPipeline: MTLRenderPipelineState
    public let colorGradingPipeline: MTLRenderPipelineState
    
    // Compositing & Particle Pipelines (Render target: .bgra8Unorm & .rgba8Unorm)
    public let layerTranslucentPipelineBGRA: MTLRenderPipelineState
    public let layerAdditivePipelineBGRA: MTLRenderPipelineState
    public let layerMultiplyPipelineBGRA: MTLRenderPipelineState
    
    public let layerTranslucentPipelineRGBA: MTLRenderPipelineState
    public let layerAdditivePipelineRGBA: MTLRenderPipelineState
    
    public let particleTranslucentPipelineBGRA: MTLRenderPipelineState
    public let particleAdditivePipelineBGRA: MTLRenderPipelineState
    public let particleTranslucentPipelineRGBA: MTLRenderPipelineState
    public let particleAdditivePipelineRGBA: MTLRenderPipelineState
    
    public let skinnedPuppetPipelineBGRA: MTLRenderPipelineState
    public let skinnedPuppetPipelineRGBA: MTLRenderPipelineState
    
    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal is not supported on this Mac")
        }
        self.device = dev
        self.commandQueue = q
        
        // Samplers
        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear
        sDesc.magFilter = .linear
        sDesc.sAddressMode = .clampToEdge
        sDesc.tAddressMode = .clampToEdge
        self.linearSampler = dev.makeSamplerState(descriptor: sDesc)!
        
        let rDesc = MTLSamplerDescriptor()
        rDesc.minFilter = .linear
        rDesc.magFilter = .linear
        rDesc.sAddressMode = .repeat
        rDesc.tAddressMode = .repeat
        self.repeatSampler = dev.makeSamplerState(descriptor: rDesc)!
        
        let mslSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        // 1. Fullscreen Quad for Offscreen Post-Processing Passes
        vertex VertexOut fullscreen_vert(uint vid [[vertex_id]]) {
            VertexOut out;
            float2 uv = float2((vid << 1) & 2, vid & 2);
            out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
            out.texCoord = float2(uv.x, 1.0 - uv.y);
            return out;
        }

        // 2. 2D Layer Compositing Vertex & Fragment
        struct LayerQuadVertex {
            float2 position;
            float2 texCoord;
        };

        struct LayerUniforms {
            float4x4 mvp;
            float4 color;
        };

        vertex VertexOut layer_vert(const device LayerQuadVertex* verts [[buffer(0)]],
                                   constant LayerUniforms &u [[buffer(1)]],
                                   uint vid [[vertex_id]]) {
            VertexOut out;
            out.position = u.mvp * float4(verts[vid].position, 0.0, 1.0);
            out.texCoord = verts[vid].texCoord;
            return out;
        }

        fragment float4 layer_frag(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler s [[sampler(0)]],
                                  constant LayerUniforms &u [[buffer(1)]]) {
            float4 col = tex.sample(s, in.texCoord);
            return col * u.color;
        }

        // 3. Official 1:1 Water Ripple Effect
        struct WaterRippleUniforms {
            float time;
            float strength;
            float animationSpeed;
            float scale;
            float scrollSpeed;
            float scrollDirection;
            float ratio;
            float texAdjustment;
        };

        fragment float4 waterripple_frag(VertexOut in [[stage_in]],
                                         texture2d<float> tex0 [[texture(0)]],
                                         texture2d<float> maskTex [[texture(1)]],
                                         texture2d<float> normalTex [[texture(2)]],
                                         sampler sClamp [[sampler(0)]],
                                         sampler sRepeat [[sampler(1)]],
                                         constant WaterRippleUniforms &u [[buffer(0)]]) {
            float2 uv = in.texCoord;
            float mask = maskTex.sample(sClamp, uv).r;

            float sD = u.scrollDirection;
            float2 dir = float2(sin(sD), cos(sD));
            float2 scroll = dir * (u.scrollSpeed * u.scrollSpeed * u.time);
            float anim = u.time * (u.animationSpeed * u.animationSpeed);

            float2 rCoord1 = (uv + anim + scroll) * u.scale;
            float2 rCoord2 = (uv * 1.333 - anim + scroll) * u.scale;

            rCoord1.x *= u.texAdjustment;
            rCoord1.y *= u.ratio;
            rCoord2.x *= u.texAdjustment;
            rCoord2.y *= u.ratio;

            float3 n1 = normalTex.sample(sRepeat, rCoord1).xyz * 2.0 - 1.0;
            float3 n2 = normalTex.sample(sRepeat, rCoord2).xyz * 2.0 - 1.0;
            float3 normal = normalize(float3(n1.xy + n2.xy, n1.z));

            float2 distortedUV = uv + normal.xy * (u.strength * u.strength) * mask;
            return tex0.sample(sClamp, distortedUV);
        }

        // 4. Official 1:1 Shake Effect
        struct ShakeUniforms {
            float time;
            float speed;
            float amp;
            float2 friction;
            float2 bounds;
            float phase;
        };

        fragment float4 shake_frag(VertexOut in [[stage_in]],
                                   texture2d<float> tex0 [[texture(0)]],
                                   texture2d<float> maskTex [[texture(1)]],
                                   sampler s [[sampler(0)]],
                                   constant ShakeUniforms &u [[buffer(0)]]) {
            float2 uv = in.texCoord;
            float4 maskSample = maskTex.sample(s, uv);
            float2 flowMask = (maskSample.rg - float2(0.498039, 0.498039)) * 2.0;

            float t = u.speed * u.time + u.phase;
            float sVal = sin(t) * 0.498 + 0.5;
            float baseVal = step(0.0, cos(t));
            float offset = mix(1.0 - pow(1.0 - sVal, u.friction.x), pow(sVal, u.friction.y), baseVal);
            offset = clamp((offset - u.bounds.x) * u.bounds.y, 0.0, 1.0);
            offset = offset * 2.0 - 1.0;

            float2 uvOffset = offset * (u.amp * u.amp) * flowMask;
            return tex0.sample(s, uv + uvOffset);
        }

        // 5. Official 1:1 Iris Saccade Effect
        struct IrisUniforms {
            float time;
            float speed;
            float noiseAmount;
            float phase;
            float rough;
            float2 scale;
        };

        fragment float4 iris_frag(VertexOut in [[stage_in]],
                                  texture2d<float> tex0 [[texture(0)]],
                                  texture2d<float> maskTex [[texture(1)]],
                                  sampler s [[sampler(0)]],
                                  constant IrisUniforms &u [[buffer(0)]]) {
            float2 uv = in.texCoord;
            float mask = maskTex.sample(s, uv).r;

            float t = (u.time * u.speed) + u.phase;
            float lowDt = floor(t);
            float2 motion2 = sin(1.9 * (lowDt + float2(0.0, 1.0)));
            float4 motion4 = sin(2.5 * (lowDt + float4(0.0, 0.0, 1.0, 1.0)) + float4(1.0, 2.0, 1.0, 2.0));
            float2 moveStart = motion2.xx + motion4.xy;
            float2 moveEnd = motion2.yy + motion4.zw;
            float ease = smoothstep(1.0 - u.rough, 1.0, cos(fract(t) * 3.14159265) * -0.5 + 0.5);
            float2 da = mix(moveStart, moveEnd, ease);

            da.x += sin(t) * u.noiseAmount;
            da.y += cos(t) * u.noiseAmount;
            da *= u.scale * 0.001;

            float2 irisOffset = da * mask;
            return tex0.sample(s, uv + irisOffset);
        }

        // 6. Official 1:1 Flow Effect
        struct FlowUniforms {
            float time;
            float speed;
            float strength;
        };

        fragment float4 flow_frag(VertexOut in [[stage_in]],
                                  texture2d<float> tex0 [[texture(0)]],
                                  texture2d<float> flowTex [[texture(1)]],
                                  sampler s [[sampler(0)]],
                                  constant FlowUniforms &u [[buffer(0)]]) {
            float2 uv = in.texCoord;
            float4 flowSample = flowTex.sample(s, uv);
            float2 flowVec = (flowSample.rg - float2(0.5, 0.5)) * 2.0;

            float progress = fract(u.time * u.speed);
            float progress2 = fract(u.time * u.speed + 0.5);
            float w = abs(progress * 2.0 - 1.0);

            float2 uv1 = uv + flowVec * (progress - 0.5) * u.strength;
            float2 uv2 = uv + flowVec * (progress2 - 0.5) * u.strength;

            float4 col1 = tex0.sample(s, uv1);
            float4 col2 = tex0.sample(s, uv2);
            return mix(col1, col2, w);
        }

        // 7. Official 1:1 Spin Effect
        struct SpinUniforms {
            float time;
            float speed;
            float strength;
            float2 center;
        };

        fragment float4 spin_frag(VertexOut in [[stage_in]],
                                  texture2d<float> tex0 [[texture(0)]],
                                  sampler s [[sampler(0)]],
                                  constant SpinUniforms &u [[buffer(0)]]) {
            float2 uv = in.texCoord;
            float2 delta = uv - u.center;
            float r = length(delta);
            float angle = atan2(delta.y, delta.x);
            float angleNew = angle + u.speed * u.time * u.strength * (1.0 - smoothstep(0.0, 0.5, r));
            float2 rotatedUV = u.center + r * float2(cos(angleNew), sin(angleNew));
            return tex0.sample(s, rotatedUV);
        }

        // 8. Separable Gaussian Blur
        struct BlurUniforms {
            float2 direction;
            float strength;
        };

        fragment float4 blur_frag(VertexOut in [[stage_in]],
                                  texture2d<float> tex0 [[texture(0)]],
                                  sampler s [[sampler(0)]],
                                  constant BlurUniforms &u [[buffer(0)]]) {
            float2 uv = in.texCoord;
            float4 sum = tex0.sample(s, uv) * 0.227027;
            float2 offset1 = u.direction * (1.38461538 * u.strength);
            float2 offset2 = u.direction * (3.23076923 * u.strength);
            sum += tex0.sample(s, uv + offset1) * 0.31621621;
            sum += tex0.sample(s, uv - offset1) * 0.31621621;
            sum += tex0.sample(s, uv + offset2) * 0.07027027;
            sum += tex0.sample(s, uv - offset2) * 0.07027027;
            return sum;
        }

        // 9. Color Grading
        struct ColorGradingUniforms {
            float brightness;
            float contrast;
            float saturation;
            float4 tint;
        };

        fragment float4 colorgrading_frag(VertexOut in [[stage_in]],
                                          texture2d<float> tex0 [[texture(0)]],
                                          sampler s [[sampler(0)]],
                                          constant ColorGradingUniforms &u [[buffer(0)]]) {
            float4 col = tex0.sample(s, in.texCoord);
            col.rgb = (col.rgb - 0.5) * u.contrast + 0.5 + u.brightness;
            float luma = dot(col.rgb, float3(0.299, 0.587, 0.114));
            col.rgb = mix(float3(luma), col.rgb, u.saturation) * u.tint.rgb;
            col.a *= u.tint.a;
            return col;
        }

        // 10. GPU Instanced Particle Billboard
        struct ParticleQuadVertex {
            float2 position;
            float2 texCoord;
        };

        struct ParticleInstanceData {
            float2 position;
            float2 size;
            float4 color;
            float rotation;
        };

        struct ParticleUniforms {
            float4x4 mvp;
        };

        struct ParticleVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
        };

        vertex ParticleVertexOut particle_vert(const device ParticleQuadVertex* quadVerts [[buffer(0)]],
                                              const device ParticleInstanceData* instances [[buffer(1)]],
                                              constant ParticleUniforms &u [[buffer(2)]],
                                              uint vid [[vertex_id]],
                                              uint iid [[instance_id]]) {
            ParticleQuadVertex qv = quadVerts[vid];
            ParticleInstanceData inst = instances[iid];

            float cosR = cos(inst.rotation);
            float sinR = sin(inst.rotation);
            float2 localPos = float2(
                qv.position.x * inst.size.x * cosR - qv.position.y * inst.size.y * sinR,
                qv.position.x * inst.size.x * sinR + qv.position.y * inst.size.y * cosR
            );

            float4 worldPos = float4(inst.position + localPos, 0.0, 1.0);
            ParticleVertexOut out;
            out.position = u.mvp * worldPos;
            out.texCoord = qv.texCoord;
            out.color = inst.color;
            return out;
        }

        fragment float4 particle_frag(ParticleVertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler s [[sampler(0)]]) {
            float4 c = tex.sample(s, in.texCoord);
            return c * in.color;
        }

        // 11. Skinned Mesh 2D Puppet Warp
        struct SkinnedVertexIn {
            float3 position;
            float2 texCoord;
            float4 boneWeights;
            uint4 boneIndices;
        };

        struct SkinnedUniforms {
            float4x4 mvp;
            float4x4 boneMatrices[64];
            float4 color;
        };

        vertex VertexOut skinned_puppet_vert(const device SkinnedVertexIn* inVerts [[buffer(0)]],
                                            constant SkinnedUniforms &u [[buffer(1)]],
                                            uint vid [[vertex_id]]) {
            SkinnedVertexIn in = inVerts[vid];
            float4 pos = float4(in.position, 1.0);
            
            uint b0 = clamp(in.boneIndices.x, 0u, 63u);
            uint b1 = clamp(in.boneIndices.y, 0u, 63u);
            uint b2 = clamp(in.boneIndices.z, 0u, 63u);
            uint b3 = clamp(in.boneIndices.w, 0u, 63u);
            
            float4 skinnedPos = (u.boneMatrices[b0] * pos) * in.boneWeights.x
                              + (u.boneMatrices[b1] * pos) * in.boneWeights.y
                              + (u.boneMatrices[b2] * pos) * in.boneWeights.z
                              + (u.boneMatrices[b3] * pos) * in.boneWeights.w;
                              
            VertexOut out;
            out.position = u.mvp * skinnedPos;
            out.texCoord = in.texCoord;
            return out;
        }

        fragment float4 skinned_puppet_frag(VertexOut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]],
                                           sampler s [[sampler(0)]],
                                           constant SkinnedUniforms &u [[buffer(1)]]) {
            float4 col = tex.sample(s, in.texCoord);
            return col * u.color;
        }
        """
        
        let lib = try! dev.makeLibrary(source: mslSource, options: nil)
        self.fullscreenVertFunc = lib.makeFunction(name: "fullscreen_vert")!
        self.layerVertFunc = lib.makeFunction(name: "layer_vert")!
        self.layerFragFunc = lib.makeFunction(name: "layer_frag")!
        
        let waterRippleFrag = lib.makeFunction(name: "waterripple_frag")!
        let shakeFrag = lib.makeFunction(name: "shake_frag")!
        let irisFrag = lib.makeFunction(name: "iris_frag")!
        let flowFrag = lib.makeFunction(name: "flow_frag")!
        let spinFrag = lib.makeFunction(name: "spin_frag")!
        let blurFrag = lib.makeFunction(name: "blur_frag")!
        let colorGradingFrag = lib.makeFunction(name: "colorgrading_frag")!
        
        let particleVert = lib.makeFunction(name: "particle_vert")!
        let particleFrag = lib.makeFunction(name: "particle_frag")!
        
        let skinnedVert = lib.makeFunction(name: "skinned_puppet_vert")!
        let skinnedFrag = lib.makeFunction(name: "skinned_puppet_frag")!
        
        enum BlendMode { case none, translucent, additive, multiply }
        
        func makePipe(v: MTLFunction, f: MTLFunction, pixelFormat: MTLPixelFormat, blend: BlendMode) -> MTLRenderPipelineState {
            let pDesc = MTLRenderPipelineDescriptor()
            pDesc.vertexFunction = v
            pDesc.fragmentFunction = f
            pDesc.colorAttachments[0].pixelFormat = pixelFormat
            switch blend {
            case .none:
                pDesc.colorAttachments[0].isBlendingEnabled = false
            case .translucent:
                pDesc.colorAttachments[0].isBlendingEnabled = true
                pDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                pDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                pDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
                pDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                pDesc.colorAttachments[0].isBlendingEnabled = true
                pDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                pDesc.colorAttachments[0].destinationRGBBlendFactor = .one
                pDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
                pDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            case .multiply:
                pDesc.colorAttachments[0].isBlendingEnabled = true
                pDesc.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
                pDesc.colorAttachments[0].destinationRGBBlendFactor = .zero
                pDesc.colorAttachments[0].sourceAlphaBlendFactor = .destinationAlpha
                pDesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
            }
            return try! dev.makeRenderPipelineState(descriptor: pDesc)
        }
        
        // Offscreen passes
        self.waterRipplePipeline = makePipe(v: fullscreenVertFunc, f: waterRippleFrag, pixelFormat: .rgba8Unorm, blend: .none)
        self.shakePipeline = makePipe(v: fullscreenVertFunc, f: shakeFrag, pixelFormat: .rgba8Unorm, blend: .none)
        self.irisPipeline = makePipe(v: fullscreenVertFunc, f: irisFrag, pixelFormat: .rgba8Unorm, blend: .none)
        self.flowPipeline = makePipe(v: fullscreenVertFunc, f: flowFrag, pixelFormat: .rgba8Unorm, blend: .none)
        self.spinPipeline = makePipe(v: fullscreenVertFunc, f: spinFrag, pixelFormat: .rgba8Unorm, blend: .none)
        self.blurPipeline = makePipe(v: fullscreenVertFunc, f: blurFrag, pixelFormat: .rgba8Unorm, blend: .none)
        self.colorGradingPipeline = makePipe(v: fullscreenVertFunc, f: colorGradingFrag, pixelFormat: .rgba8Unorm, blend: .none)
        
        // Compositing pipelines (BGRA)
        self.layerTranslucentPipelineBGRA = makePipe(v: layerVertFunc, f: layerFragFunc, pixelFormat: .bgra8Unorm, blend: .translucent)
        self.layerAdditivePipelineBGRA = makePipe(v: layerVertFunc, f: layerFragFunc, pixelFormat: .bgra8Unorm, blend: .additive)
        self.layerMultiplyPipelineBGRA = makePipe(v: layerVertFunc, f: layerFragFunc, pixelFormat: .bgra8Unorm, blend: .multiply)
        
        // Compositing pipelines (RGBA)
        self.layerTranslucentPipelineRGBA = makePipe(v: layerVertFunc, f: layerFragFunc, pixelFormat: .rgba8Unorm, blend: .translucent)
        self.layerAdditivePipelineRGBA = makePipe(v: layerVertFunc, f: layerFragFunc, pixelFormat: .rgba8Unorm, blend: .additive)
        
        // Particle pipelines
        self.particleTranslucentPipelineBGRA = makePipe(v: particleVert, f: particleFrag, pixelFormat: .bgra8Unorm, blend: .translucent)
        self.particleAdditivePipelineBGRA = makePipe(v: particleVert, f: particleFrag, pixelFormat: .bgra8Unorm, blend: .additive)
        self.particleTranslucentPipelineRGBA = makePipe(v: particleVert, f: particleFrag, pixelFormat: .rgba8Unorm, blend: .translucent)
        self.particleAdditivePipelineRGBA = makePipe(v: particleVert, f: particleFrag, pixelFormat: .rgba8Unorm, blend: .additive)
        
        // Skinned puppet pipelines
        self.skinnedPuppetPipelineBGRA = makePipe(v: skinnedVert, f: skinnedFrag, pixelFormat: .bgra8Unorm, blend: .translucent)
        self.skinnedPuppetPipelineRGBA = makePipe(v: skinnedVert, f: skinnedFrag, pixelFormat: .rgba8Unorm, blend: .translucent)
    }
}

// MARK: - Pass & Uniform Models

public struct MetalLayerQuadVertex {
    public var position: SIMD2<Float>
    public var texCoord: SIMD2<Float>
}

public struct LayerUniforms {
    public var mvp: simd_float4x4
    public var color: SIMD4<Float>
}

public struct WaterRippleUniforms {
    public var time: Float
    public var strength: Float
    public var animationSpeed: Float
    public var scale: Float
    public var scrollSpeed: Float
    public var scrollDirection: Float
    public var ratio: Float
    public var texAdjustment: Float
}

public struct ShakeUniforms {
    public var time: Float
    public var speed: Float
    public var amp: Float
    public var friction: SIMD2<Float>
    public var bounds: SIMD2<Float>
    public var phase: Float
}

public struct IrisUniforms {
    public var time: Float
    public var speed: Float
    public var noiseAmount: Float
    public var phase: Float
    public var rough: Float
    public var scale: SIMD2<Float>
}

public struct FlowUniforms {
    public var time: Float
    public var speed: Float
    public var strength: Float
}

public struct SpinUniforms {
    public var time: Float
    public var speed: Float
    public var strength: Float
    public var center: SIMD2<Float>
}

public struct BlurUniforms {
    public var direction: SIMD2<Float>
    public var strength: Float
}

public struct ColorGradingUniforms {
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float
    public var tint: SIMD4<Float>
}

public struct ParticleQuadVertex {
    public var position: SIMD2<Float>
    public var texCoord: SIMD2<Float>
}

public struct ParticleInstanceData {
    public var position: SIMD2<Float>
    public var size: SIMD2<Float>
    public var color: SIMD4<Float>
    public var rotation: Float
}

public struct ParticleUniforms {
    public var mvp: simd_float4x4
}

public struct SkinnedVertexIn {
    public var position: SIMD3<Float>
    public var texCoord: SIMD2<Float>
    public var boneWeights: SIMD4<Float>
    public var boneIndices: SIMD4<UInt32>
}

public struct SkinnedUniforms {
    public var mvp: simd_float4x4
    public var boneMatrices: (
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
        simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4
    )
    public var color: SIMD4<Float>
}

public enum EffectPassType {
    case waterripple
    case shake
    case iris
    case flow
    case spin
    case blur
    case colorgrading
    case unknown(String)
}

public enum LayerBlendMode {
    case translucent
    case additive
    case multiply
}

public final class SceneEffectPass: @unchecked Sendable {
    public let type: EffectPassType
    public var maskTexture: MTLTexture?
    public var normalTexture: MTLTexture?
    public var constants: [String: Any]
    
    public init(type: EffectPassType, maskTexture: MTLTexture? = nil, normalTexture: MTLTexture? = nil, constants: [String: Any] = [:]) {
        self.type = type
        self.maskTexture = maskTexture
        self.normalTexture = normalTexture
        self.constants = constants
    }
}

// MARK: - 2D Puppet Warp Skinned Mesh Model (MDLV0021 / MDLV0023)

public final class MDLVMesh: @unchecked Sendable {
    public let vertexBuffer: MTLBuffer
    public let indexBuffer: MTLBuffer
    public let indexCount: Int
    public let naturalSize: CGSize
    public var boneTransforms: [simd_float4x4] = Array(repeating: matrix_identity_float4x4, count: 64)
    
    public init?(mdlData: Data, device: MTLDevice, targetSize: CGSize) {
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
        
        var parsedVertices: [SkinnedVertexIn] = []
        parsedVertices.reserveCapacity(vertexCount)
        
        for i in 0..<vertexCount {
            let vo = vOffset + i * vertexStride
            let x = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo, as: Float.self) }
            let y = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 4, as: Float.self) }
            let z = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 8, as: Float.self) }
            
            let w0 = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 40, as: Float.self) }
            let w1 = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 44, as: Float.self) }
            let w2 = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 48, as: Float.self) }
            let w3 = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 52, as: Float.self) }
            
            let b0 = UInt32(bytes[vo + 56])
            let b1 = UInt32(bytes[vo + 57])
            let b2 = UInt32(bytes[vo + 58])
            let b3 = UInt32(bytes[vo + 59])
            
            let u = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 72, as: Float.self) }
            let v = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: vo + 76, as: Float.self) }
            
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            
            parsedVertices.append(SkinnedVertexIn(
                position: SIMD3<Float>(x, y, z),
                texCoord: SIMD2<Float>(u, v),
                boneWeights: SIMD4<Float>(w0, w1, w2, w3),
                boneIndices: SIMD4<UInt32>(b0, b1, b2, b3)
            ))
        }
        
        var parsedIndices: [UInt16] = []
        parsedIndices.reserveCapacity(indexCount)
        for i in 0..<indexCount {
            let idx = mdlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: idxOffset + i * 2, as: UInt16.self) }
            parsedIndices.append(idx)
        }
        
        let spanX = max(abs(minX), abs(maxX)) * 2.0
        let spanY = max(abs(minY), abs(maxY)) * 2.0
        let renderW = max(Float(targetSize.width), spanX)
        let renderH = max(Float(targetSize.height), spanY)
        self.naturalSize = CGSize(width: CGFloat(renderW), height: CGFloat(renderH))
        
        guard let vBuf = device.makeBuffer(bytes: parsedVertices, length: parsedVertices.count * MemoryLayout<SkinnedVertexIn>.stride, options: []),
              let iBuf = device.makeBuffer(bytes: parsedIndices, length: parsedIndices.count * MemoryLayout<UInt16>.stride, options: []) else {
            return nil
        }
        
        self.vertexBuffer = vBuf
        self.indexBuffer = iBuf
        self.indexCount = indexCount
    }
    
    /// Updates bone physics dynamics (spring harmonic bone oscillations)
    public func updateBonePhysics(time: Double) {
        // Natural secondary motion: each bone receives harmonic spring oscillation
        for i in 0..<64 {
            if i == 0 {
                boneTransforms[i] = matrix_identity_float4x4
            } else {
                let freq = 1.0 + Double(i % 5) * 0.4
                let angle = Float(sin(time * freq + Double(i)) * 0.05)
                let c = cos(angle), s = sin(angle)
                var rot = matrix_identity_float4x4
                rot.columns.0.x = c
                rot.columns.0.y = s
                rot.columns.1.x = -s
                rot.columns.1.y = c
                boneTransforms[i] = rot
            }
        }
    }
}

// MARK: - Scene Render Layer

public final class SceneRenderLayer: @unchecked Sendable {
    public let id: Int
    public let name: String
    public var origin: CGPoint
    public var size: CGSize
    public var scale: CGPoint
    public var zRotation: Float
    public var alpha: Float
    public var blendMode: LayerBlendMode
    public var baseTexture: MTLTexture
    public var passes: [SceneEffectPass]
    public var skinnedMesh: MDLVMesh?
    
    public var fboA: MTLTexture?
    public var fboB: MTLTexture?
    
    public init(id: Int, name: String, origin: CGPoint, size: CGSize, scale: CGPoint, zRotation: Float, alpha: Float, blendMode: LayerBlendMode = .translucent, baseTexture: MTLTexture, passes: [SceneEffectPass] = [], skinnedMesh: MDLVMesh? = nil) {
        self.id = id
        self.name = name
        self.origin = origin
        self.size = size
        self.scale = scale
        self.zRotation = zRotation
        self.alpha = alpha
        self.blendMode = blendMode
        self.baseTexture = baseTexture
        self.passes = passes
        self.skinnedMesh = skinnedMesh
    }
    
    public func ensureFBOs(device: MTLDevice) {
        let w = baseTexture.width
        let h = baseTexture.height
        if fboA == nil || fboA?.width != w || fboA?.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            self.fboA = device.makeTexture(descriptor: desc)
            self.fboB = device.makeTexture(descriptor: desc)
        }
    }
}

// MARK: - Unified GPU Instanced Particle System

public final class MetalParticleSystem: @unchecked Sendable {
    struct Particle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var size: Float
        var alpha: Float
        var lifetime: Float
        var maxLifetime: Float
        var rotation: Float
        var rotSpeed: Float
        var isAlive: Bool
    }
    
    public let name: String
    public var origin: SIMD2<Float>
    public var angles: Float
    public var scale: SIMD2<Float>
    public let texture: MTLTexture
    public let isAdditive: Bool
    public let maxCount: Int
    
    public var rate: Float
    public var lifetimeMin: Float
    public var lifetimeMax: Float
    public var sizeMin: Float
    public var sizeMax: Float
    public var baseColor: SIMD4<Float>
    public var fadeInTime: Float
    public var fadeOutTime: Float
    public var boxHalfSize: SIMD2<Float>
    public var initialSpeed: Float
    public var oscillateAlphaFreq: Float
    
    private var particles: [Particle]
    private var spawnAccumulator: Float = 0
    private var instanceBuffer: MTLBuffer?
    
    public init(name: String, origin: SIMD2<Float>, angles: Float, scale: SIMD2<Float>, texture: MTLTexture, isAdditive: Bool, maxCount: Int = 500) {
        self.name = name
        self.origin = origin
        self.angles = angles
        self.scale = scale
        self.texture = texture
        self.isAdditive = isAdditive
        self.maxCount = min(max(maxCount, 50), 2000)
        
        self.rate = 30.0
        self.lifetimeMin = 3.0
        self.lifetimeMax = 6.0
        self.sizeMin = 15.0
        self.sizeMax = 25.0
        self.baseColor = SIMD4<Float>(1, 1, 1, 1)
        self.fadeInTime = 0.1
        self.fadeOutTime = 0.9
        self.boxHalfSize = SIMD2<Float>(960, 540)
        self.initialSpeed = 20.0
        self.oscillateAlphaFreq = 0.0
        
        self.particles = (0..<self.maxCount).map { _ in
            Particle(position: .zero, velocity: .zero, size: 20, alpha: 0, lifetime: 0, maxLifetime: 5, rotation: 0, rotSpeed: 0, isAlive: false)
        }
        
        // Seed initial pool so scene starts populated immediately
        seedInitialParticles()
    }
    
    private func seedInitialParticles() {
        let initialCount = min(maxCount / 2, 150)
        for i in 0..<initialCount {
            spawnParticle(at: &particles[i], progress: Float(Double.random(in: 0.1...0.9)))
        }
    }
    
    private func spawnParticle(at p: inout Particle, progress: Float = 0.0) {
        let rx = Float.random(in: -boxHalfSize.x...boxHalfSize.x)
        let ry = Float.random(in: -boxHalfSize.y...boxHalfSize.y)
        p.position = origin + SIMD2<Float>(rx, ry)
        
        let angle = Float.random(in: 0...(2 * .pi))
        let spd = Float.random(in: (initialSpeed * 0.5)...(initialSpeed * 1.5))
        p.velocity = SIMD2<Float>(cos(angle), sin(angle)) * spd
        
        p.size = Float.random(in: sizeMin...sizeMax) * scale.x
        p.maxLifetime = Float.random(in: lifetimeMin...lifetimeMax)
        p.lifetime = p.maxLifetime * progress
        p.rotation = Float.random(in: 0...(2 * .pi))
        p.rotSpeed = Float.random(in: -1.0...1.0)
        p.alpha = 1.0
        p.isAlive = true
    }
    
    public func update(dt: Float, time: Double) {
        spawnAccumulator += rate * dt
        let spawnLimit = min(Int(spawnAccumulator), 10)
        if spawnLimit > 0 {
            spawnAccumulator -= Float(spawnLimit)
            var spawned = 0
            for i in 0..<particles.count where !particles[i].isAlive {
                spawnParticle(at: &particles[i])
                spawned += 1
                if spawned >= spawnLimit { break }
            }
        }
        
        for i in 0..<particles.count where particles[i].isAlive {
            particles[i].lifetime += dt
            if particles[i].lifetime >= particles[i].maxLifetime {
                particles[i].isAlive = false
                continue
            }
            
            particles[i].position += particles[i].velocity * dt
            particles[i].rotation += particles[i].rotSpeed * dt
            
            let rel = particles[i].lifetime / particles[i].maxLifetime
            var a: Float = 1.0
            if rel < fadeInTime {
                a = rel / max(fadeInTime, 0.001)
            } else if rel > fadeOutTime {
                a = 1.0 - (rel - fadeOutTime) / max(1.0 - fadeOutTime, 0.001)
            }
            
            if oscillateAlphaFreq > 0.0 {
                let osc = Float(sin(time * Double(oscillateAlphaFreq) + Double(i))) * 0.5 + 0.5
                a *= (osc * 0.8 + 0.2)
            }
            
            particles[i].alpha = min(max(a, 0.0), 1.0)
        }
    }
    
    public func render(encoder: MTLRenderCommandEncoder, device: MTLDevice, quadBuffer: MTLBuffer, orthoMVP: simd_float4x4, pipeline: MTLRenderPipelineState) {
        var activeInstances: [ParticleInstanceData] = []
        activeInstances.reserveCapacity(particles.count)
        
        for p in particles where p.isAlive && p.alpha > 0.01 {
            var col = baseColor
            col.w *= p.alpha
            activeInstances.append(ParticleInstanceData(
                position: p.position,
                size: SIMD2<Float>(p.size, p.size),
                color: col,
                rotation: p.rotation
            ))
        }
        
        guard !activeInstances.isEmpty else { return }
        
        let bufferSize = activeInstances.count * MemoryLayout<ParticleInstanceData>.stride
        if instanceBuffer == nil || (instanceBuffer?.length ?? 0) < bufferSize {
            instanceBuffer = device.makeBuffer(length: max(bufferSize, 1024), options: .storageModeShared)
        }
        
        instanceBuffer?.contents().copyMemory(from: activeInstances, byteCount: bufferSize)
        
        var u = ParticleUniforms(mvp: orthoMVP)
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(MetalShaderManager.shared.linearSampler, index: 0)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: activeInstances.count)
    }
}

// MARK: - Metal Scene Engine

@MainActor
public final class MetalSceneEngine: @unchecked Sendable {
    public static let shared = MetalSceneEngine()
    
    public var canvasSize: CGSize = CGSize(width: 3840, height: 2160)
    public var layers: [SceneRenderLayer] = []
    public var particleSystems: [MetalParticleSystem] = []
    public var clearColor: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)
    
    private let shaderManager = MetalShaderManager.shared
    private var layerQuadBuffer: MTLBuffer?
    private var lastRenderTime: Double = 0
    
    public init() {
        setupQuadBuffer()
    }
    
    private func setupQuadBuffer() {
        // Standard Unit Quad: centered from (-0.5, -0.5) to (0.5, 0.5)
        let verts: [MetalLayerQuadVertex] = [
            MetalLayerQuadVertex(position: SIMD2<Float>(-0.5, -0.5), texCoord: SIMD2<Float>(0.0, 1.0)),
            MetalLayerQuadVertex(position: SIMD2<Float>( 0.5, -0.5), texCoord: SIMD2<Float>(1.0, 1.0)),
            MetalLayerQuadVertex(position: SIMD2<Float>(-0.5,  0.5), texCoord: SIMD2<Float>(0.0, 0.0)),
            MetalLayerQuadVertex(position: SIMD2<Float>( 0.5, -0.5), texCoord: SIMD2<Float>(1.0, 1.0)),
            MetalLayerQuadVertex(position: SIMD2<Float>( 0.5,  0.5), texCoord: SIMD2<Float>(1.0, 0.0)),
            MetalLayerQuadVertex(position: SIMD2<Float>(-0.5,  0.5), texCoord: SIMD2<Float>(0.0, 0.0)),
        ]
        self.layerQuadBuffer = shaderManager.device.makeBuffer(
            bytes: verts,
            length: verts.count * MemoryLayout<MetalLayerQuadVertex>.stride,
            options: []
        )
    }
    
    /// Loads a Scene wallpaper from a directory or unpacked folder
    public func loadScene(from directoryURL: URL) -> Bool {
        let pkgURL = directoryURL.appendingPathComponent("scene.pkg")
        let pkgParser = ScenePKGParser(url: pkgURL)
        
        func readData(path: String) -> Data? {
            let direct = directoryURL.appendingPathComponent(path)
            if let d = try? Data(contentsOf: direct) { return d }
            let unpacked = directoryURL.appendingPathComponent("unpacked").appendingPathComponent(path)
            if let d = try? Data(contentsOf: unpacked) { return d }
            return pkgParser?.extractFile(named: path)
        }
        
        guard let sceneData = readData(path: "scene.json") else { return false }
        
        struct SceneRaw: Decodable {
            struct General: Decodable {
                struct Ortho: Decodable { let width: Int?; let height: Int? }
                let orthogonalprojection: Ortho?
                let clearcolor: String?
            }
            struct PassRaw: Decodable {
                let constantshadervalues: [String: AnyCodable]?
                let textures: [String?]?
            }
            struct EffectRaw: Decodable {
                let file: String?
                let passes: [PassRaw]?
                let visible: FlexibleBool?
            }
            struct ObjectRaw: Decodable {
                let id: Int?
                let name: String?
                let origin: FlexibleVec3?
                let scale: FlexibleVec3?
                let angles: FlexibleVec3?
                let size: FlexibleVec2?
                let alpha: FlexibleDouble?
                let visible: FlexibleBool?
                let image: String?
                let particle: String?
                let effects: [EffectRaw]?
                let instanceoverride: [String: AnyCodable]?
            }
            let general: General?
            let objects: [ObjectRaw]?
        }
        
        guard let sceneRaw = try? JSONDecoder().decode(SceneRaw.self, from: sceneData) else {
            return false
        }
        
        let cw = CGFloat(sceneRaw.general?.orthogonalprojection?.width ?? 3840)
        let ch = CGFloat(sceneRaw.general?.orthogonalprojection?.height ?? 2160)
        self.canvasSize = CGSize(width: cw, height: ch)
        
        if let clearStr = sceneRaw.general?.clearcolor {
            let parts = clearStr.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 3 {
                self.clearColor = MTLClearColorMake(parts[0], parts[1], parts[2], 1.0)
            }
        }
        
        var loadedLayers: [SceneRenderLayer] = []
        var loadedParticles: [MetalParticleSystem] = []
        var textureCache: [String: MTLTexture] = [:]
        
        func resolveTexture(name: String) -> MTLTexture? {
            if let cached = textureCache[name] { return cached }
            let candidates = [
                "\(name).tex", "materials/\(name).tex", "\(name).png", "materials/\(name).png",
                "\(name).jpg", "materials/\(name).jpg", name
            ]
            for c in candidates {
                if let d = readData(path: c), let tex = MetalTextureDecoder.shared.decode(data: d, device: shaderManager.device) {
                    textureCache[name] = tex
                    return tex
                }
            }
            return nil
        }
        
        for (idx, obj) in (sceneRaw.objects ?? []).enumerated() {
            guard obj.visible?.value ?? true else { continue }
            
            // 1. Process Image / Skinned Mesh Layers
            if let imageModelPath = obj.image {
                guard let modelData = readData(path: imageModelPath),
                      let modelJson = try? JSONSerialization.jsonObject(with: modelData) as? [String: Any],
                      let matPath = modelJson["material"] as? String,
                      let matData = readData(path: matPath),
                      let matJson = try? JSONSerialization.jsonObject(with: matData) as? [String: Any],
                      let passesArr = matJson["passes"] as? [[String: Any]],
                      let firstPass = passesArr.first,
                      let texArr = firstPass["textures"] as? [String],
                      let baseTexName = texArr.first,
                      let baseTex = resolveTexture(name: baseTexName) else {
                    continue
                }
                
                var blendMode: LayerBlendMode = .translucent
                if let bStr = firstPass["blending"] as? String {
                    if bStr == "additive" { blendMode = .additive }
                    else if bStr == "multiply" { blendMode = .multiply }
                }
                
                // Check for .mdl Skinned Puppet Mesh
                var skinnedMesh: MDLVMesh? = nil
                if let mdlFile = modelJson["model"] as? String, let mdlData = readData(path: mdlFile) {
                    let w = CGFloat(obj.size?.x ?? Double(baseTex.width))
                    let h = CGFloat(obj.size?.y ?? Double(baseTex.height))
                    skinnedMesh = MDLVMesh(mdlData: mdlData, device: shaderManager.device, targetSize: CGSize(width: w, height: h))
                }
                
                // Resolve effect chain
                var passObjects: [SceneEffectPass] = []
                for eff in obj.effects ?? [] {
                    guard eff.visible?.value ?? true, let effFile = eff.file else { continue }
                    let type: EffectPassType
                    if effFile.contains("waterripple") { type = .waterripple }
                    else if effFile.contains("shake") { type = .shake }
                    else if effFile.contains("iris") { type = .iris }
                    else if effFile.contains("flow") { type = .flow }
                    else if effFile.contains("spin") { type = .spin }
                    else if effFile.contains("blur") { type = .blur }
                    else if effFile.contains("colorgrading") { type = .colorgrading }
                    else { type = .unknown(effFile) }
                    
                    for p in eff.passes ?? [] {
                        var constants: [String: Any] = [:]
                        for (k, v) in p.constantshadervalues ?? [:] {
                            constants[k] = v.value
                        }
                        
                        var maskTex: MTLTexture?
                        var normTex: MTLTexture?
                        let texRefs = p.textures ?? []
                        if texRefs.count > 1, let mName = texRefs[1] {
                            maskTex = resolveTexture(name: mName)
                        }
                        if texRefs.count > 2, let nName = texRefs[2] {
                            normTex = resolveTexture(name: nName)
                        }
                        
                        passObjects.append(SceneEffectPass(type: type, maskTexture: maskTex, normalTexture: normTex, constants: constants))
                    }
                }
                
                // Bottom-left origin to canvas center
                let rawOx = obj.origin?.x ?? (Double(cw) / 2)
                let rawOy = obj.origin?.y ?? (Double(ch) / 2)
                let centerX = CGFloat(rawOx) - cw / 2
                let centerY = CGFloat(rawOy) - ch / 2
                
                let w = CGFloat(obj.size?.x ?? Double(baseTex.width))
                let h = CGFloat(obj.size?.y ?? Double(baseTex.height))
                let sx = CGFloat(obj.scale?.x ?? 1.0)
                let sy = CGFloat(obj.scale?.y ?? 1.0)
                let rot = Float(obj.angles?.z ?? 0.0)
                let alpha = Float(obj.alpha?.value ?? 1.0)
                
                let layer = SceneRenderLayer(
                    id: obj.id ?? idx,
                    name: obj.name ?? "layer_\(idx)",
                    origin: CGPoint(x: centerX, y: centerY),
                    size: CGSize(width: w, height: h),
                    scale: CGPoint(x: sx, y: sy),
                    zRotation: rot,
                    alpha: alpha,
                    blendMode: blendMode,
                    baseTexture: baseTex,
                    passes: passObjects,
                    skinnedMesh: skinnedMesh
                )
                layer.ensureFBOs(device: shaderManager.device)
                loadedLayers.append(layer)
            }
            
            // 2. Process Native Metal Instanced Particle Systems
            if let particlePath = obj.particle {
                guard let pData = readData(path: particlePath),
                      let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                      let matPath = pJson["material"] as? String,
                      let matData = readData(path: matPath),
                      let matJson = try? JSONSerialization.jsonObject(with: matData) as? [String: Any],
                      let passesArr = matJson["passes"] as? [[String: Any]],
                      let firstPass = passesArr.first else {
                    continue
                }
                
                let texArr = firstPass["textures"] as? [String] ?? []
                let pTexName = texArr.first ?? ""
                let pTex = resolveTexture(name: pTexName) ?? MetalTextureDecoder.shared.getDefaultParticleTexture(device: shaderManager.device)
                
                let isAdditive = (firstPass["blending"] as? String) == "additive"
                let maxCount = pJson["maxcount"] as? Int ?? 500
                
                let rawOx = Float(obj.origin?.x ?? (Double(cw) / 2)) - Float(cw) / 2
                let rawOy = Float(obj.origin?.y ?? (Double(ch) / 2)) - Float(ch) / 2
                let ang = Float(obj.angles?.z ?? 0.0)
                let sx = Float(obj.scale?.x ?? 1.0)
                let sy = Float(obj.scale?.y ?? 1.0)
                
                let ps = MetalParticleSystem(
                    name: obj.name ?? "particle_\(idx)",
                    origin: SIMD2<Float>(rawOx, rawOy),
                    angles: ang,
                    scale: SIMD2<Float>(sx, sy),
                    texture: pTex,
                    isAdditive: isAdditive,
                    maxCount: maxCount
                )
                
                // Parse emitter definitions
                if let emitters = pJson["emitter"] as? [[String: Any]], let firstEmitter = emitters.first {
                    if let rateVal = firstEmitter["rate"] as? Double {
                        ps.rate = Float(rateVal)
                    }
                    if let distStr = firstEmitter["distancemax"] as? String {
                        let parts = distStr.split(separator: " ").compactMap { Float($0) }
                        if parts.count >= 2 {
                            ps.boxHalfSize = SIMD2<Float>(parts[0] * 0.5, parts[1] * 0.5)
                        }
                    }
                }
                
                // Parse initializers
                if let inits = pJson["initializer"] as? [[String: Any]] {
                    for ini in inits {
                        let name = ini["name"] as? String ?? ""
                        if name == "lifetimerandom" {
                            ps.lifetimeMin = Float(ini["min"] as? Double ?? 3.0)
                            ps.lifetimeMax = Float(ini["max"] as? Double ?? 6.0)
                        } else if name == "sizerandom" {
                            ps.sizeMin = Float(ini["min"] as? Double ?? 15.0)
                            ps.sizeMax = Float(ini["max"] as? Double ?? 25.0)
                        } else if name == "colorrandom" {
                            if let colStr = ini["min"] as? String {
                                let parts = colStr.split(separator: " ").compactMap { Float($0) }
                                if parts.count >= 3 {
                                    ps.baseColor = SIMD4<Float>(parts[0] / 255.0, parts[1] / 255.0, parts[2] / 255.0, 1.0)
                                }
                            }
                        }
                    }
                }
                
                // Parse operators
                if let ops = pJson["operator"] as? [[String: Any]] {
                    for op in ops {
                        let name = op["name"] as? String ?? ""
                        if name == "alphafade" {
                            ps.fadeInTime = Float(op["fadeintime"] as? Double ?? 0.1)
                            ps.fadeOutTime = Float(op["fadeouttime"] as? Double ?? 0.9)
                        } else if name == "oscillatealpha" {
                            ps.oscillateAlphaFreq = Float(op["frequencymax"] as? Double ?? 2.0)
                        }
                    }
                }
                
                // Apply instance overrides from scene.json
                if let overrides = obj.instanceoverride {
                    if let r = overrides["rate"]?.value as? Double { ps.rate *= Float(r) }
                    if let s = overrides["size"]?.value as? Double {
                        ps.sizeMin *= Float(s); ps.sizeMax *= Float(s)
                    }
                    if let l = overrides["lifetime"]?.value as? Double {
                        ps.lifetimeMin *= Float(l); ps.lifetimeMax *= Float(l)
                    }
                    if let spd = overrides["speed"]?.value as? Double {
                        ps.initialSpeed *= Float(spd)
                    }
                }
                
                loadedParticles.append(ps)
            }
        }
        
        self.layers = loadedLayers
        self.particleSystems = loadedParticles
        return !loadedLayers.isEmpty || !loadedParticles.isEmpty
    }
    
    /// Renders the entire Scene to destination drawable texture
    public func render(to destinationTexture: MTLTexture, renderPassDescriptor: MTLRenderPassDescriptor, time: Double, viewportSize: CGSize) {
        guard let cmdBuffer = shaderManager.commandQueue.makeCommandBuffer() else { return }
        
        let dt = Float(max(time - lastRenderTime, 0.001))
        self.lastRenderTime = time
        
        // 1. Process Offscreen Ping-Pong Passes for each layer
        for layer in layers {
            // Update skinned bone physics if applicable
            layer.skinnedMesh?.updateBonePhysics(time: time)
            
            guard !layer.passes.isEmpty, let fboA = layer.fboA, let fboB = layer.fboB else { continue }
            
            var readTex = layer.baseTexture
            var writeTex = fboA
            
            for (pIdx, pass) in layer.passes.enumerated() {
                let pDesc = MTLRenderPassDescriptor()
                pDesc.colorAttachments[0].texture = writeTex
                pDesc.colorAttachments[0].loadAction = .clear
                pDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                pDesc.colorAttachments[0].storeAction = .store
                
                guard let enc = cmdBuffer.makeRenderCommandEncoder(descriptor: pDesc) else { continue }
                
                switch pass.type {
                case .waterripple:
                    enc.setRenderPipelineState(shaderManager.waterRipplePipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentTexture(pass.maskTexture ?? readTex, index: 1)
                    enc.setFragmentTexture(pass.normalTexture ?? readTex, index: 2)
                    enc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                    enc.setFragmentSamplerState(shaderManager.repeatSampler, index: 1)
                    
                    var u = WaterRippleUniforms(
                        time: Float(time),
                        strength: Float(pass.constants["ripplestrength"] as? Double ?? 0.1),
                        animationSpeed: Float(pass.constants["animationspeed"] as? Double ?? 0.15),
                        scale: Float(pass.constants["scale"] as? Double ?? 1.0),
                        scrollSpeed: Float(pass.constants["scrollspeed"] as? Double ?? 0.0),
                        scrollDirection: Float(pass.constants["scrolldirection"] as? Double ?? 0.0),
                        ratio: Float(pass.constants["ratio"] as? Double ?? 1.0),
                        texAdjustment: Float(readTex.width) / max(Float(readTex.height), 1.0)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<WaterRippleUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .shake:
                    enc.setRenderPipelineState(shaderManager.shakePipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentTexture(pass.maskTexture ?? readTex, index: 1)
                    enc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                    
                    var friction = SIMD2<Float>(1.0, 1.0)
                    if let fStr = pass.constants["friction"] as? String {
                        let parts = fStr.split(separator: " ").compactMap { Float($0) }
                        if parts.count >= 2 { friction = SIMD2<Float>(parts[0], parts[1]) }
                    }
                    var bounds = SIMD2<Float>(0.0, 1.0)
                    if let bStr = pass.constants["bounds"] as? String {
                        let parts = bStr.split(separator: " ").compactMap { Float($0) }
                        if parts.count >= 2 { bounds = SIMD2<Float>(parts[0], parts[1]) }
                    }
                    
                    // Each shake pass receives continuous smooth sine oscillation
                    let phase = Float(pass.constants["phase"] as? Double ?? (Double(pIdx) * 0.4))
                    var u = ShakeUniforms(
                        time: Float(time),
                        speed: Float(pass.constants["speed"] as? Double ?? 1.0),
                        amp: Float(pass.constants["strength"] as? Double ?? 0.1),
                        friction: friction,
                        bounds: bounds,
                        phase: phase
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<ShakeUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .iris:
                    enc.setRenderPipelineState(shaderManager.irisPipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentTexture(pass.maskTexture ?? readTex, index: 1)
                    enc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                    
                    var u = IrisUniforms(
                        time: Float(time),
                        speed: Float(pass.constants["speed"] as? Double ?? 1.0),
                        noiseAmount: Float(pass.constants["noiseamount"] as? Double ?? 0.5),
                        phase: Float(pass.constants["phase"] as? Double ?? 0.0),
                        rough: Float(pass.constants["rough"] as? Double ?? 0.2),
                        scale: SIMD2<Float>(1.0, 1.0)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<IrisUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .flow:
                    enc.setRenderPipelineState(shaderManager.flowPipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentTexture(pass.maskTexture ?? readTex, index: 1)
                    enc.setFragmentSamplerState(shaderManager.repeatSampler, index: 0)
                    
                    var u = FlowUniforms(
                        time: Float(time),
                        speed: Float(pass.constants["speed"] as? Double ?? 0.2),
                        strength: Float(pass.constants["strength"] as? Double ?? 0.1)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<FlowUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .spin:
                    enc.setRenderPipelineState(shaderManager.spinPipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                    
                    var u = SpinUniforms(
                        time: Float(time),
                        speed: Float(pass.constants["speed"] as? Double ?? 0.5),
                        strength: Float(pass.constants["strength"] as? Double ?? 1.0),
                        center: SIMD2<Float>(0.5, 0.5)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<SpinUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .blur:
                    enc.setRenderPipelineState(shaderManager.blurPipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                    
                    var u = BlurUniforms(
                        direction: SIMD2<Float>(1.0 / Float(readTex.width), 0.0),
                        strength: Float(pass.constants["strength"] as? Double ?? 1.0)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .colorgrading:
                    enc.setRenderPipelineState(shaderManager.colorGradingPipeline)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                    
                    var u = ColorGradingUniforms(
                        brightness: Float(pass.constants["brightness"] as? Double ?? 0.0),
                        contrast: Float(pass.constants["contrast"] as? Double ?? 1.0),
                        saturation: Float(pass.constants["saturation"] as? Double ?? 1.0),
                        tint: SIMD4<Float>(1, 1, 1, 1)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<ColorGradingUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    
                case .unknown:
                    // Passthrough to avoid black frame
                    enc.setRenderPipelineState(shaderManager.layerTranslucentPipelineRGBA)
                    enc.setVertexBuffer(layerQuadBuffer, offset: 0, index: 0)
                    var u = LayerUniforms(mvp: matrix_identity_float4x4, color: SIMD4<Float>(1, 1, 1, 1))
                    enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 1)
                    enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 1)
                    enc.setFragmentTexture(readTex, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
                
                enc.endEncoding()
                
                // Swap Ping-Pong
                readTex = writeTex
                writeTex = (writeTex === fboA) ? fboB : fboA
            }
        }
        
        // 2. Final Compositing to Destination (Aspect Fill Ortho Projection)
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let compEnc = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            cmdBuffer.commit()
            return
        }
        
        let viewAspect = Float(viewportSize.width / max(viewportSize.height, 1))
        let canvasAspect = Float(canvasSize.width / max(canvasSize.height, 1))
        
        let halfW: Float
        let halfH: Float
        if viewAspect > canvasAspect {
            halfW = Float(canvasSize.width) / 2.0
            halfH = halfW / viewAspect
        } else {
            halfH = Float(canvasSize.height) / 2.0
            halfW = halfH * viewAspect
        }
        
        let ortho = simd_float4x4(
            simd_float4(1.0 / halfW, 0.0, 0.0, 0.0),
            simd_float4(0.0, 1.0 / halfH, 0.0, 0.0),
            simd_float4(0.0, 0.0, 1.0, 0.0),
            simd_float4(0.0, 0.0, 0.0, 1.0)
        )
        
        let isBGRA = (destinationTexture.pixelFormat == .bgra8Unorm)
        
        // Render 2D Layers & Skinned Puppets
        for layer in layers {
            let activeTexture: MTLTexture
            if !layer.passes.isEmpty, let fboA = layer.fboA {
                activeTexture = (layer.passes.count % 2 == 1) ? fboA : (layer.fboB ?? fboA)
            } else {
                activeTexture = layer.baseTexture
            }
            
            let lw = Float(layer.size.width) * Float(layer.scale.x)
            let lh = Float(layer.size.height) * Float(layer.scale.y)
            let ox = Float(layer.origin.x)
            let oy = Float(layer.origin.y)
            let rot = layer.zRotation
            
            let cosR = cos(rot), sinR = sin(rot)
            let model = simd_float4x4(
                simd_float4(lw * cosR, lw * sinR, 0.0, 0.0),
                simd_float4(-lh * sinR, lh * cosR, 0.0, 0.0),
                simd_float4(0.0, 0.0, 1.0, 0.0),
                simd_float4(ox, oy, 0.0, 1.0)
            )
            
            if let skinned = layer.skinnedMesh {
                // Skinned mesh puppet rendering
                let pipe = isBGRA ? shaderManager.skinnedPuppetPipelineBGRA : shaderManager.skinnedPuppetPipelineRGBA
                compEnc.setRenderPipelineState(pipe)
                compEnc.setVertexBuffer(skinned.vertexBuffer, offset: 0, index: 0)
                
                var u = SkinnedUniforms(
                    mvp: ortho * model,
                    boneMatrices: (
                        skinned.boneTransforms[0], skinned.boneTransforms[1], skinned.boneTransforms[2], skinned.boneTransforms[3],
                        skinned.boneTransforms[4], skinned.boneTransforms[5], skinned.boneTransforms[6], skinned.boneTransforms[7],
                        skinned.boneTransforms[8], skinned.boneTransforms[9], skinned.boneTransforms[10], skinned.boneTransforms[11],
                        skinned.boneTransforms[12], skinned.boneTransforms[13], skinned.boneTransforms[14], skinned.boneTransforms[15],
                        skinned.boneTransforms[16], skinned.boneTransforms[17], skinned.boneTransforms[18], skinned.boneTransforms[19],
                        skinned.boneTransforms[20], skinned.boneTransforms[21], skinned.boneTransforms[22], skinned.boneTransforms[23],
                        skinned.boneTransforms[24], skinned.boneTransforms[25], skinned.boneTransforms[26], skinned.boneTransforms[27],
                        skinned.boneTransforms[28], skinned.boneTransforms[29], skinned.boneTransforms[30], skinned.boneTransforms[31],
                        skinned.boneTransforms[32], skinned.boneTransforms[33], skinned.boneTransforms[34], skinned.boneTransforms[35],
                        skinned.boneTransforms[36], skinned.boneTransforms[37], skinned.boneTransforms[38], skinned.boneTransforms[39],
                        skinned.boneTransforms[40], skinned.boneTransforms[41], skinned.boneTransforms[42], skinned.boneTransforms[43],
                        skinned.boneTransforms[44], skinned.boneTransforms[45], skinned.boneTransforms[46], skinned.boneTransforms[47],
                        skinned.boneTransforms[48], skinned.boneTransforms[49], skinned.boneTransforms[50], skinned.boneTransforms[51],
                        skinned.boneTransforms[52], skinned.boneTransforms[53], skinned.boneTransforms[54], skinned.boneTransforms[55],
                        skinned.boneTransforms[56], skinned.boneTransforms[57], skinned.boneTransforms[58], skinned.boneTransforms[59],
                        skinned.boneTransforms[60], skinned.boneTransforms[61], skinned.boneTransforms[62], skinned.boneTransforms[63]
                    ),
                    color: SIMD4<Float>(1.0, 1.0, 1.0, layer.alpha)
                )
                compEnc.setVertexBytes(&u, length: MemoryLayout<SkinnedUniforms>.stride, index: 1)
                compEnc.setFragmentBytes(&u, length: MemoryLayout<SkinnedUniforms>.stride, index: 1)
                compEnc.setFragmentTexture(activeTexture, index: 0)
                compEnc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                
                compEnc.drawIndexedPrimitives(type: .triangle, indexCount: skinned.indexCount, indexType: .uint16, indexBuffer: skinned.indexBuffer, indexBufferOffset: 0)
                
            } else {
                // Standard quad layer rendering
                let pipe: MTLRenderPipelineState
                switch layer.blendMode {
                case .translucent:
                    pipe = isBGRA ? shaderManager.layerTranslucentPipelineBGRA : shaderManager.layerTranslucentPipelineRGBA
                case .additive:
                    pipe = isBGRA ? shaderManager.layerAdditivePipelineBGRA : shaderManager.layerAdditivePipelineRGBA
                case .multiply:
                    pipe = isBGRA ? shaderManager.layerMultiplyPipelineBGRA : shaderManager.layerTranslucentPipelineRGBA
                }
                
                compEnc.setRenderPipelineState(pipe)
                compEnc.setVertexBuffer(layerQuadBuffer, offset: 0, index: 0)
                compEnc.setFragmentSamplerState(shaderManager.linearSampler, index: 0)
                
                var uniforms = LayerUniforms(
                    mvp: ortho * model,
                    color: SIMD4<Float>(1.0, 1.0, 1.0, layer.alpha)
                )
                compEnc.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 1)
                compEnc.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 1)
                compEnc.setFragmentTexture(activeTexture, index: 0)
                compEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        
        // 3. Render Native Instanced Particle Systems
        guard let quadBuf = layerQuadBuffer else {
            compEnc.endEncoding()
            cmdBuffer.commit()
            return
        }
        
        for ps in particleSystems {
            ps.update(dt: min(dt, 0.05), time: time)
            let pipe: MTLRenderPipelineState
            if ps.isAdditive {
                pipe = isBGRA ? shaderManager.particleAdditivePipelineBGRA : shaderManager.particleAdditivePipelineRGBA
            } else {
                pipe = isBGRA ? shaderManager.particleTranslucentPipelineBGRA : shaderManager.particleTranslucentPipelineRGBA
            }
            ps.render(encoder: compEnc, device: shaderManager.device, quadBuffer: quadBuf, orthoMVP: ortho, pipeline: pipe)
        }
        
        compEnc.endEncoding()
        cmdBuffer.commit()
    }
}

// MARK: - MetalSceneView (AppKit View Component)

public final class MetalSceneView: MTKView, MTKViewDelegate {
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    public let engine = MetalSceneEngine.shared
    
    public init(frame: NSRect) {
        let dev = MetalShaderManager.shared.device
        super.init(frame: frame, device: dev)
        self.colorPixelFormat = .bgra8Unorm
        self.preferredFramesPerSecond = 60
        self.delegate = self
        self.autoresizingMask = [.width, .height]
    }
    
    required init(coder: NSCoder) {
        let dev = MetalShaderManager.shared.device
        super.init(coder: coder)
        self.device = dev
        self.colorPixelFormat = .bgra8Unorm
        self.preferredFramesPerSecond = 60
        self.delegate = self
        self.autoresizingMask = [.width, .height]
    }
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        
        let elapsed = CACurrentMediaTime() - startTime
        engine.render(to: drawable.texture, renderPassDescriptor: rpd, time: elapsed, viewportSize: view.drawableSize)
        drawable.present()
    }
}

// MARK: - AnyCodable Helper for Scene JSON Decoding

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else {
            self.value = 0
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let d = value as? Double {
            try container.encode(d)
        } else if let s = value as? String {
            try container.encode(s)
        } else if let b = value as? Bool {
            try container.encode(b)
        }
    }
}
