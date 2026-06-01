import AppKit
import Metal
import MetalKit
import QuartzCore
import simd
import Foundation
import Darwin

// MARK: - Embedded Metal Shaders

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                              constant float4x4& mvp [[buffer(1)]]) {
    VertexOut out;
    out.position = mvp * float4(in.position, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> texture [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return texture.sample(s, in.texCoord);
}
"""

// MARK: - Vertex Structure

struct TileVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

// MARK: - Math Helpers

/// Top-down view matrix. Camera at (camX, altitude, camZ) looking straight down.
/// Screen-right = world +X (east), screen-up = world +Z (north).
func topDownViewMatrix(camX: Float, camZ: Float, altitude: Float) -> float4x4 {
    return float4x4(columns: (
        SIMD4<Float>( 1,  0,  0, 0),  // world +X → view +X
        SIMD4<Float>( 0,  0, -1, 0),  // world +Y → view -Z
        SIMD4<Float>( 0,  1,  0, 0),  // world +Z → view +Y
        SIMD4<Float>(-camX, -camZ, altitude, 1)
    ))
}

/// Orthographic projection for Metal [0,1] depth range.
func matrix4x4_orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> float4x4 {
    let rl = 1.0 / (right - left)
    let tb = 1.0 / (top - bottom)
    let fn = 1.0 / (far - near)
    return float4x4(columns: (
        SIMD4<Float>(2.0 * rl, 0, 0, 0),
        SIMD4<Float>(0, 2.0 * tb, 0, 0),
        SIMD4<Float>(0, 0, fn, 0),
        SIMD4<Float>(-(right + left) * rl, -(top + bottom) * tb, -near * fn, 1)
    ))
}

func matrix4x4_translation(_ t: SIMD3<Float>) -> float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

func matrix4x4_scale(_ s: SIMD3<Float>) -> float4x4 {
    return float4x4(columns: (
        SIMD4<Float>(s.x, 0, 0, 0),
        SIMD4<Float>(0, s.y, 0, 0),
        SIMD4<Float>(0, 0, s.z, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

// MARK: - Renderer

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer

    var textures: [MTLTexture] = []
    var imageCount: Int = 0

    // ── Streaming ──
    var streamingEnabled = false
    var streamServerSock: Int32 = -1
    var streamClientSock: Int32 = -1
    var streamLock = NSLock()
    var lastStreamTime: Double = 0
    let streamFPS: Double = 30.0
    let streamPort: UInt16 = 9999
    // ── Ground grid (built dynamically from image count) ──
    let tileSize: Float = 1.0
    var gridWidth: Int = 1       // tiles in X direction
    var gridHeight: Int = 1      // tiles in Z direction
    var groundMaxX: Float = 1    // gridWidth * tileSize
    var groundMaxZ: Float = 1    // gridHeight * tileSize

    // ── Camera state ──
    var cameraX: Float = 0.0
    var cameraZ: Float = 0.0
    var altitude: Float = 2.0
    var minAltitude: Float = 0.06
    var maxAltitude: Float = 25.0

    // Smooth camera target
    var targetX: Float = 0.0
    var targetZ: Float = 0.0
    var targetAltitude: Float = 5.0

    // Key state
    var keyWPressed = false
    var keyAPressed = false
    var keySPressed = false
    var keyDPressed = false
    var keyHPressed = false
    var keyLPressed = false

    // Camera starting position (for reset)
    var cameraStartX: Float = 0.0
    var cameraStartZ: Float = 0.0
    var cameraStartAltitude: Float = 0.0

    // FPS tracking
    var currentFPS: Double = 0.0
    private var frameCount: Int = 0
    private var lastFPSTime: Double = 0.0
    private var lastFrameTime: Double = 0.0
    private var rawFrameTimes: [Double] = []

    init(device: MTLDevice, view: MTKView) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        // ── Shader library ──
        let library = try! device.makeLibrary(source: metalShaderSource, options: nil)
        let vertexFunction = library.makeFunction(name: "vertex_main")!
        let fragmentFunction = library.makeFunction(name: "fragment_main")!

        // ── Vertex descriptor ──
        // Attribute 0: position (float3) at offset 0, from buffer 0
        // Attribute 1: texCoord (float2) at offset 16, from buffer 0
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TileVertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        // ── Pipeline state ──
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        // No depth attachment — all tiles on same plane

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        // ── Unit quad on XZ plane (4 vertices, 2 triangles) ──
        let vertices: [TileVertex] = [
            TileVertex(position: SIMD3<Float>(0, 0, 0), texCoord: SIMD2<Float>(0, 0)),
            TileVertex(position: SIMD3<Float>(1, 0, 0), texCoord: SIMD2<Float>(1, 0)),
            TileVertex(position: SIMD3<Float>(1, 0, 1), texCoord: SIMD2<Float>(1, 1)),
            TileVertex(position: SIMD3<Float>(0, 0, 1), texCoord: SIMD2<Float>(0, 1)),
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        self.vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<TileVertex>.stride * vertices.count,
            options: []
        )!
        self.indexBuffer = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt16>.stride * indices.count,
            options: []
        )!

        super.init()

        // ── Load textures ──
        loadTextures()

        // ── Calculate ground grid from image count ──
        setupGround()

        view.device = device
        view.delegate = self
        view.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1.0)
        view.depthStencilPixelFormat = .invalid
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = 1
        view.preferredFramesPerSecond = 60

        // Center camera on ground
        cameraX = groundMaxX / 2.0
        cameraZ = groundMaxZ / 2.0
        targetX = cameraX
        targetZ = cameraZ
        // ── TUNABLE: Starting altitude ──────────────────────────
        // Starts low — close to the ground, showing ~3 tiles across.
        altitude = minAltitude * 3.0    // <-- CHANGE: set to any value between minAltitude and maxAltitude
        targetAltitude = altitude

        // Store starting position for reset (key 'C')
        cameraStartX = cameraX
        cameraStartZ = cameraZ
        cameraStartAltitude = altitude
    }

    // MARK: - Texture Loading

    func loadTextures() {
        let loader = MTKTextureLoader(device: device)

        // Search for images folder
        let exePath = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().path

        let searchPaths = [
            "images",
            "./images",
            "\(exePath)/images",
            "\(FileManager.default.currentDirectoryPath)/images",
        ]

        var imageDir: String? = nil
        for p in searchPaths where !p.isEmpty {
            if FileManager.default.fileExists(atPath: p) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                if isDir.boolValue { imageDir = p; break }
            }
        }

        var imageFiles: [String] = []
        if let dir = imageDir {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                imageFiles = contents
                    .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
                    .sorted()
                    .map { "\(dir)/\($0)" }
            }
        }

        if imageFiles.isEmpty {
            print("⚠️  No images found. Generating 16 procedural tiles.")
            generateProceduralTextures(count: 16)
            return
        }

        print("📷 Found \(imageFiles.count) images. Loading...")
        for (i, filePath) in imageFiles.enumerated() {
            let url = URL(fileURLWithPath: filePath)
            if let texture = try? loader.newTexture(URL: url, options: [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue as NSNumber,
                .textureStorageMode: MTLStorageMode.private.rawValue as NSNumber,
            ]) {
                textures.append(texture)
            }
            // show progress every 20 images
            if (i + 1) % 20 == 0 || i == imageFiles.count - 1 {
                // silent for now
            }
        }

        if textures.isEmpty {
            print("⚠️  Failed to load any images. Generating 16 procedural tiles.")
            generateProceduralTextures(count: 16)
            return
        }

        imageCount = textures.count
        print("✅ Loaded \(imageCount) textures.")
    }

    func generateProceduralTextures(count: Int) {
        let texSize = 64
        let hues: [Float] = [0.0, 0.08, 0.16, 0.25, 0.33, 0.42, 0.50, 0.58, 0.66, 0.75, 0.83, 0.92]

        for i in 0..<count {
            let hue = hues[i % hues.count] + Float.random(in: -0.03...0.03)
            let (r, g, b) = hslToRGB(h: hue, s: 0.5, l: 0.45)

            var pixels = [UInt8](repeating: 0, count: texSize * texSize * 4)
            for py in 0..<texSize {
                for px in 0..<texSize {
                    let base = (py * texSize + px) * 4
                    let n = Int8(truncatingIfNeeded: Int.random(in: -10...10))
                    pixels[base+0] = UInt8(clamping: Int(r) + Int(n))
                    pixels[base+1] = UInt8(clamping: Int(g) + Int(n))
                    pixels[base+2] = UInt8(clamping: Int(b) + Int(n))
                    pixels[base+3] = 255
                    if px % 16 == 0 || py % 16 == 0 {
                        pixels[base+0] = UInt8(clamping: Int(pixels[base+0]) - 20)
                        pixels[base+1] = UInt8(clamping: Int(pixels[base+1]) - 20)
                        pixels[base+2] = UInt8(clamping: Int(pixels[base+2]) - 20)
                    }
                }
            }

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: texSize, height: texSize, mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .managed

            if let tex = device.makeTexture(descriptor: desc) {
                tex.replace(region: MTLRegionMake2D(0, 0, texSize, texSize),
                            mipmapLevel: 0, withBytes: &pixels, bytesPerRow: texSize * 4)
                textures.append(tex)
            }
        }
        imageCount = textures.count
        print("🎨 Generated \(imageCount) procedural tile textures.")
    }

    private func hslToRGB(h: Float, s: Float, l: Float) -> (UInt8, UInt8, UInt8) {
        let c = (1 - abs(2*l - 1)) * s
        let hp = h * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c/2
        var rr: Float = 0, gg: Float = 0, bb: Float = 0
        switch Int(hp) % 6 {
        case 0: rr = c; gg = x
        case 1: rr = x; gg = c
        case 2: gg = c; bb = x
        case 3: gg = x; bb = c
        case 4: rr = x; bb = c
        case 5: rr = c; bb = x
        default: break
        }
        return (
            UInt8(clamping: Int((rr+m)*255)),
            UInt8(clamping: Int((gg+m)*255)),
            UInt8(clamping: Int((bb+m)*255))
        )
    }

    // MARK: - Ground Setup

    func setupGround() {
        let n = max(imageCount, 1)
        // Arrange as close to a square as possible
        gridWidth = Int(ceil(sqrt(Float(n))))
        gridHeight = Int(ceil(Float(n) / Float(gridWidth)))

        groundMaxX = Float(gridWidth) * tileSize
        groundMaxZ = Float(gridHeight) * tileSize

        // ── TUNABLE: Altitude range ──────────────────────────────
        // viewHeight = altitude * VIEW_SCALE  (see draw(), line ~379)
        // To see the ENTIRE ground at max altitude:
        //   maxAltitude = maxGroundDim * MARGIN / VIEW_SCALE
        let maxDim = max(groundMaxX, groundMaxZ)
        let viewScale: Float = 1.8      // <-- CHANGE: bigger = more zoomed out at same altitude
        let maxMargin: Float = 1.2      // <-- 1.0 = exact fit, >1 adds padding around ground
        maxAltitude = maxDim * maxMargin / viewScale

        // Minimum altitude — how close you can zoom in.
        // At altitude X you see (X * viewScale) units of ground.
        // e.g. altitude 0.3 shows 0.3*1.8 = 0.54 tiles → very close detail.
        let lowestAllowed: Float = 0.3   // <-- CHANGE: lower = can get closer to ground
        minAltitude = max(lowestAllowed, maxAltitude * 0.02)

        print("🗺  Ground: \(gridWidth)×\(gridHeight) tiles = \(n) images")
        print("   Size: \(groundMaxX)×\(groundMaxZ) world units")
        print("   Altitude range: \(String(format: "%.1f", minAltitude)) – \(String(format: "%.1f", maxAltitude))")
    }

    /// Returns texture index for tile at grid position (ix, iz), or -1 if out of bounds
    // MARK: - TCP Streaming Server

    func startStreamServer() {
        streamingEnabled = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runStreamServer()
        }
    }

    private func runStreamServer() {
        // Create socket
        streamServerSock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard streamServerSock >= 0 else {
            print("❌ TCP socket() failed: \(errno)")
            return
        }

        // Allow port reuse (prevents "address in use" on restart)
        var reuse: Int32 = 1
        setsockopt(streamServerSock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = streamPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(streamServerSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            print("❌ TCP bind() failed: \(errno)"); return
        }

        // Listen
        guard Darwin.listen(streamServerSock, 1) == 0 else {
            print("❌ TCP listen() failed: \(errno)"); return
        }

        print("📡 TCP stream server listening on port \(streamPort)")

        // Accept loop
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(streamServerSock, $0, &addrLen)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }

            print("📡 RTSP client connected")

            // Close previous client if any
            streamLock.lock()
            if streamClientSock >= 0 { Darwin.close(streamClientSock) }
            streamClientSock = client
            streamLock.unlock()
        }
    }

    func sendFrameOverTCP(_ data: Data) {
        streamLock.lock()
        let sock = streamClientSock
        streamLock.unlock()

        guard sock >= 0 else { return }

        // 4-byte big-endian size prefix + frame data
        var size = UInt32(data.count).bigEndian
        let header = Data(bytes: &size, count: 4)
        let packet = header + data

        // Send ALL bytes — TCP can do partial writes, so we loop.
        var sent = 0
        let total = packet.count
        while sent < total {
            let n = packet.withUnsafeBytes { ptr in
                Darwin.send(sock, ptr.baseAddress! + sent, total - sent, 0)
            }
            if n <= 0 {
                // Client disconnected or error — close socket
                streamLock.lock()
                Darwin.close(sock)
                streamClientSock = -1
                streamLock.unlock()
                return
            }
            sent += n
        }
    }

    // MARK: - Tile Indexing

    func textureIndexForTile(ix: Int, iz: Int) -> Int {
        guard ix >= 0, ix < gridWidth, iz >= 0, iz < gridHeight else { return -1 }
        let idx = iz * gridWidth + ix
        return idx < textures.count ? idx : -1
    }

    // MARK: - Camera Reset

    func resetCamera() {
        targetX = cameraStartX
        targetZ = cameraStartZ
        targetAltitude = cameraStartAltitude
    }

    // MARK: - Rendering

    func draw(in view: MTKView) {
        // ── FPS tracking ──
        let now = CACurrentMediaTime()
        var dt: Float = 1.0 / 60.0  // default fallback
        if lastFrameTime > 0 {
            let deltaTime = now - lastFrameTime
            dt = Float(min(deltaTime, 0.1))  // cap at 100ms to avoid jumps
            rawFrameTimes.append(deltaTime)
            if rawFrameTimes.count > 60 {
                rawFrameTimes.removeFirst()
            }
        }
        lastFrameTime = now
        frameCount += 1
        // Update FPS display every 0.5 seconds
        if now - lastFPSTime >= 0.5 {
            if !rawFrameTimes.isEmpty {
                let avg = rawFrameTimes.reduce(0, +) / Double(rawFrameTimes.count)
                currentFPS = avg > 0.0001 ? 1.0 / avg : 0.0
            }
            lastFPSTime = now
        }

        update(deltaTime: dt)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        enc.setRenderPipelineState(pipelineState)

        // ── Set vertex geometry at buffer index 0 (used by [[stage_in]]) ──
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let aspect = Float(view.drawableSize.width) / Float(view.drawableSize.height)

        // ── TUNABLE: viewScale (also in setupGround above) ───────
        // How much ground is visible at a given altitude.
        // viewHeight = altitude * viewScale
        // Bigger value = more zoomed out.  Must match setupGround().
        let viewScale: Float = 1.8
        let viewHeight = altitude * viewScale
        let viewWidth = viewHeight * aspect

        // Tile range visible on screen, clamped to ground bounds
        let tileMinI = max(Int(floor((cameraX - viewWidth/2) / tileSize)), 0)
        let tileMaxI = min(Int(ceil((cameraX + viewWidth/2) / tileSize)), gridWidth - 1)
        let tileMinJ = max(Int(floor((cameraZ - viewHeight/2) / tileSize)), 0)
        let tileMaxJ = min(Int(ceil((cameraZ + viewHeight/2) / tileSize)), gridHeight - 1)

        // Skip if nothing visible
        guard tileMinI <= tileMaxI, tileMinJ <= tileMaxJ else {
            enc.endEncoding()
            cmdBuf.present(drawable)
            cmdBuf.commit()
            return
        }

        // ── TUNABLE: Depth clipping planes ─────────────────────
        // nearP must be < minimum altitude (0.3) or tiles clip out.
        // farP should comfortably exceed max altitude.
        let nearP: Float = 0.05           // <-- CHANGE: must be < lowest altitude
        let farP: Float = altitude * 3 + 10

        // ── Build view-projection ONCE ──
        let viewM = topDownViewMatrix(camX: cameraX, camZ: cameraZ, altitude: altitude)
        let projM = matrix4x4_orthographic(
            left: -viewWidth/2, right: viewWidth/2,
            bottom: -viewHeight/2, top: viewHeight/2,
            near: nearP, far: farP
        )
        let vp = projM * viewM

        // ── Draw each tile ──
        for iz in tileMinJ...tileMaxJ {
            for ix in tileMinI...tileMaxI {
                let texIdx = textureIndexForTile(ix: ix, iz: iz)
                guard texIdx >= 0, texIdx < textures.count else { continue }

                let worldX = Float(ix) * tileSize
                let worldZ = Float(iz) * tileSize

                // Model matrix: unit quad → world tile
                let model = matrix4x4_translation(SIMD3<Float>(worldX, 0, worldZ))
                          * matrix4x4_scale(SIMD3<Float>(tileSize, 1, tileSize))

                var mvp = vp * model
                // ── Set MVP at buffer index 1 (separate from vertex geometry at index 0!) ──
                enc.setVertexBytes(&mvp, length: MemoryLayout<float4x4>.stride, index: 1)
                enc.setFragmentTexture(textures[texIdx], index: 0)

                enc.drawIndexedPrimitives(
                    type: .triangle, indexCount: 6,
                    indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0
                )
            }
        }

        enc.endEncoding()

        // ── Streaming: blit frame to shared buffer on SAME command buffer ──
        var streamBuf: MTLBuffer? = nil
        var streamTotalBytes: Int = 0
        if streamingEnabled {
            let now = CACurrentMediaTime()
            if now - lastStreamTime >= 1.0 / streamFPS {
                lastStreamTime = now
                let tex = drawable.texture
                let w = tex.width, h = tex.height
                let bytesPerRow = w * 4
                streamTotalBytes = bytesPerRow * h

                let buf = device.makeBuffer(length: streamTotalBytes, options: .storageModeShared)!
                if let blitEnc = cmdBuf.makeBlitCommandEncoder() {
                    blitEnc.copy(from: tex,
                                 sourceSlice: 0, sourceLevel: 0,
                                 sourceOrigin: MTLOriginMake(0, 0, 0),
                                 sourceSize: MTLSizeMake(w, h, 1),
                                 to: buf, destinationOffset: 0,
                                 destinationBytesPerRow: bytesPerRow,
                                 destinationBytesPerImage: streamTotalBytes)
                    blitEnc.endEncoding()
                    streamBuf = buf
                }
            }
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // ── GPU is done.  Shared buffer now contains the rendered frame. ──
        if let buf = streamBuf, streamTotalBytes > 0 {
            let data = Data(bytes: buf.contents(), count: streamTotalBytes)
            sendFrameOverTCP(data)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: - Update (movement + camera bounds)

    func update(deltaTime: Float) {
        let dt = min(deltaTime, 0.05)

        // ── TUNABLE: Movement speeds ─────────────────────────────
        // moveSpeed = SPEED_PER_ALT * altitude + BASE_SPEED
        // Higher altitude = faster movement (you cover more ground).
        let speedPerAlt: Float = 0.5    // <-- CHANGE: higher = faster at altitude
        let baseSpeed: Float = 0.05      // <-- CHANGE: minimum speed at altitude 0
        let moveSpeed = altitude * speedPerAlt + baseSpeed

        // How fast H/L keys change altitude (units per second)
        let altSpeed: Float = 1.5       // <-- CHANGE: higher = faster altitude change

        var mx: Float = 0, mz: Float = 0
        if keyWPressed { mz += 1 }
        if keySPressed { mz -= 1 }
        if keyDPressed { mx += 1 }
        if keyAPressed { mx -= 1 }

        if mx != 0 && mz != 0 {
            let inv = 1.0 / sqrt(mx*mx + mz*mz)
            mx *= inv; mz *= inv
        }

        targetX += mx * moveSpeed * dt
        targetZ += mz * moveSpeed * dt
        if keyHPressed { targetAltitude += altSpeed * dt }
        if keyLPressed { targetAltitude -= altSpeed * dt }

        // ── Clamp to ground bounds ──
        // Camera center stays within the ground (or slightly beyond)
        let margin = tileSize * 0.5
        targetX = max(margin, min(groundMaxX - margin, targetX))
        targetZ = max(margin, min(groundMaxZ - margin, targetZ))
        targetAltitude = max(minAltitude, min(maxAltitude, targetAltitude))

        // ── TUNABLE: Camera smoothness ──────────────────────────
        // Higher exponent = snappier camera. 12 = responsive, 5 = floaty.
        let smoothExponent: Float = 12.0
        let smooth: Float = 1.0 - exp(-smoothExponent * dt)
        cameraX += (targetX - cameraX) * smooth
        cameraZ += (targetZ - cameraZ) * smooth
        altitude += (targetAltitude - altitude) * smooth
    }
}

// MARK: - Game View (Keyboard Handling)

class GameView: MTKView {
    var rendererRef: Renderer?

    // HUD overlay
    private var hudLabel: NSTextField!
    private var hudUpdateTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        setupHUD()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupHUD()
    }

    private func setupHUD() {
        hudLabel = NSTextField(frame: NSRect(x: 10, y: 10, width: 400, height: 60))
        hudLabel.isBezeled = false
        hudLabel.drawsBackground = false
        hudLabel.isEditable = false
        hudLabel.isSelectable = false
        hudLabel.textColor = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9)
        hudLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        hudLabel.stringValue = "Camera Position: (0.00, 0.00)  |  Altitude: 0.00  |  FPS: --"
        // Shadow effect for readability
        hudLabel.wantsLayer = true
        hudLabel.layer?.shadowColor = NSColor.black.cgColor
        hudLabel.layer?.shadowOffset = CGSize(width: 0, height: -1)
        hudLabel.layer?.shadowRadius = 2
        hudLabel.layer?.shadowOpacity = 0.8
        self.addSubview(hudLabel)

        // Update HUD ~10 times per second
        hudUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateHUD()
        }
    }

    private func updateHUD() {
        guard let r = rendererRef else { return }
        let fpsStr = r.currentFPS > 0 ? String(format: "%.0f", r.currentFPS) : "--"
        hudLabel.stringValue = String(
            format: "Camera: (%.2f, %.2f)  |  Altitude: %.2f  |  FPS: %@",
            r.cameraX, r.cameraZ, r.altitude, fpsStr
        )
    }

    override func keyDown(with event: NSEvent) {
        apply(event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        apply(event, pressed: false)
    }

    private func apply(_ event: NSEvent, pressed: Bool) {
        guard let r = rendererRef else { return }
        // Handle 'c' key for camera reset (only on keyDown)
        if pressed, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.contains("c") {
            r.resetCamera()
            return
        }
        if let chars = event.charactersIgnoringModifiers?.lowercased() {
            for ch in chars {
                switch ch {
                case "w": r.keyWPressed = pressed
                case "a": r.keyAPressed = pressed
                case "s": r.keySPressed = pressed
                case "d": r.keyDPressed = pressed
                case "h": r.keyHPressed = pressed
                case "l": r.keyLPressed = pressed
                default: break
                }
            }
        }
        switch event.keyCode {
        case 126: r.keyWPressed = pressed
        case 125: r.keySPressed = pressed
        case 123: r.keyAPressed = pressed
        case 124: r.keyDPressed = pressed
        default: break
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenuItem.submenu = appMenu
appMenu.addItem(NSMenuItem(title: "Quit DroneView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
app.mainMenu = mainMenu
let appDel = AppDelegate()
app.delegate = appDel

guard let gpu = MTLCreateSystemDefaultDevice() else {
    print("ERROR: Metal not available."); exit(1)
}
print("🖥  GPU: \(gpu.name)")

let gameView = GameView(frame: NSRect(x: 0, y: 0, width: 640, height: 640), device: gpu)
gameView.translatesAutoresizingMaskIntoConstraints = false

// ── Streaming: if --stream flag, start TCP server on port 9999 ──
let streamingEnabled = CommandLine.arguments.contains("--stream")
gameView.wantsLayer = true
// NOTE: NOT setting contentsScale=1.0 — let Retina render natively.
// FFmpeg will scale the stream to 640×640.

let renderer = Renderer(device: gpu, view: gameView)
gameView.rendererRef = renderer

if streamingEnabled {
    renderer.startStreamServer()
}

let w: CGFloat = 640, h: CGFloat = 640
let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let origin = NSPoint(x: screen.midX - w/2, y: screen.midY - h/2)

let window = NSWindow(
    contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered, defer: false
)
window.title = "DroneView Simulator"
window.isReleasedWhenClosed = false
window.contentMinSize = NSSize(width: 640, height: 640)
window.contentMaxSize = NSSize(width: 640, height: 640)
window.contentView = gameView
window.makeFirstResponder(gameView)

if let cv = window.contentView {
    NSLayoutConstraint.activate([
        gameView.widthAnchor.constraint(equalTo: gameView.heightAnchor),
        gameView.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
        gameView.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
        gameView.widthAnchor.constraint(lessThanOrEqualTo: cv.widthAnchor),
        gameView.heightAnchor.constraint(lessThanOrEqualTo: cv.heightAnchor),
    ])
}

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

print("""
===========================================
DRONEVIEW SIMULATOR
  W/↑ = Forward    S/↓ = Backward
  A/← = Left       D/→ = Right
  H   = Higher     L   = Lower
  C   = Reset to start position
===========================================
""")

app.run()
