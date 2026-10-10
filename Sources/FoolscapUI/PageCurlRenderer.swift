import AppKit
import MetalKit
import FoolscapCore

/// Draws a photographed page bent around a cylinder. The shader is compiled
/// from source when the app starts (the OS's Metal compiler, no toolchain
/// needed) and the result shared by every curl that follows.
///
/// The fold is the line dot(p, axis) == line in page coordinates (the free
/// edge at x = 0). The page beyond the fold rises over a roll of `radius` and
/// comes back down on top of itself, mirrored: a point at unbent distance `a`
/// from the fold sits at projected distance r·sin(a/r) while on the roll and
/// at π·r − a once flat again. Each pixel walks the faces from the top down
/// and shows the first one with page under it.
@MainActor
enum PageCurlRenderer {
    nonisolated static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CurlUniforms {
        float2 origin;   // where the page's top-left corner sits in the view, in points
        float2 size;     // the page, in points
        float2 axis;     // unit normal to the fold, pointing at the lifted side
        float line;
        float radius;
        float flip;      // 1 when the free edge is on the right
        float scale;     // pixels per point
        float4 paper;    // the underside's colour
        float opacity;   // the whole curl, for the fade at the end
    };

    vertex float4 curlVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    // How much of the page covers a point: its corners are rounded, widely on the
    // free edge (x = 0 here) and barely at the spine, as PageShape draws them.
    static float coverage(constant CurlUniforms& u, float2 q) {
        bool fore = q.x < u.size.x * 0.5;
        float r = fore ? \(Float(PageShape.foreRadius)) : \(Float(PageShape.spineRadius));
        // From the centre of the nearest corner's arc, outward; inside the page's
        // straight edges one of the two is not positive.
        float2 c = float2(fore ? r - q.x : q.x - (u.size.x - r),
                          q.y < u.size.y * 0.5 ? r - q.y : q.y - (u.size.y - r));
        if (c.x <= 0.0 || c.y <= 0.0) return 1.0;
        return clamp(r - length(c) + 0.5, 0.0, 1.0);
    }

    // The flat photograph at a page coordinate (mirrored when the free edge is on the right),
    // with the leather the photograph caught beyond the rounded corners left out.
    static half4 flatSample(texture2d<half> page, sampler smp, constant CurlUniforms& u, float2 q) {
        float2 p = float2(u.flip > 0.5 ? u.size.x - q.x : q.x, q.y);
        return page.sample(smp, p / u.size) * half(coverage(u, q));
    }

    // The underside of the page: paper, with a ghost of the ink showing through.
    static half4 underside(half4 sample, float4 paper, float shade) {
        half3 ink = sample.rgb / max(sample.a, 0.002h);
        half3 rgb = mix(half3(paper.rgb), ink, 0.10h) * half(shade);
        return half4(rgb * sample.a, sample.a);
    }

    static half4 curlColour(float4 frag, constant CurlUniforms& u, texture2d<half> page, sampler smp) {
        const float PI = 3.14159265;
        float2 rel = frag.xy / u.scale - u.origin;
        if (u.flip > 0.5) rel.x = u.size.x - rel.x;
        float s = dot(rel, u.axis) - u.line;

        if (s > u.radius) {
            // The page has lifted away here: only its shadow on the page beneath. Not on
            // the leather around it, where its hard edge read as the cover itself turning.
            bool inside = all(rel >= 0.0) && all(rel <= u.size);
            float under = inside ? coverage(u, rel) : 0.0;
            float reach = u.radius * 1.5 + 20.0;
            float t = clamp((s - u.radius) / reach, 0.0, 1.0);
            float a = 0.30 * (1.0 - t) * (1.0 - t) * under;
            return half4(0.0h, 0.0h, 0.0h, half(a));
        }
        if (s >= 0.0) {
            // On the roll: the underside coming back down lies over the front going up.
            float phi = asin(clamp(s / u.radius, 0.0, 1.0));
            half4 back = flatSample(page, smp, u, rel + u.axis * (u.radius * (PI - phi) - s));
            if (back.a > 0.002h) {
                return underside(back, u.paper, 1.0 - 0.42 * (s / u.radius));
            }
            half4 front = flatSample(page, smp, u, rel + u.axis * (u.radius * phi - s));
            float shade = 1.0 - 0.30 * (s / u.radius);
            return half4(front.rgb * half(shade), front.a);
        }
        // Flat: the part already turned over lies on top of what has not moved.
        half4 over = flatSample(page, smp, u, rel + u.axis * (PI * u.radius - 2.0 * s));
        if (over.a > 0.002h) {
            return underside(over, u.paper, 1.0);
        }
        return flatSample(page, smp, u, rel);
    }

    fragment half4 curlFragment(float4 frag [[position]],
                                constant CurlUniforms& u [[buffer(0)]],
                                texture2d<half> page [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
        return curlColour(frag, u, page, smp) * half(u.opacity);
    }
    """

    struct Uniforms {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var axis: SIMD2<Float>
        var line: Float
        var radius: Float
        var flip: Float
        var scale: Float
        var paper: SIMD4<Float>
        var opacity: Float = 1
    }

    /// Everything a curl needs to draw, built once the shader has compiled.
    struct Pipeline: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLRenderPipelineState
        let sampler: MTLSamplerState
        let loader: MTKTextureLoader
    }

    private(set) static var pipeline: Pipeline?
    private static var started = false

    /// Compile the shader off the main thread; `pipeline` is set when it is ready.
    static func warmUp() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async {
            let built = build()
            DispatchQueue.main.async { pipeline = built }
        }
    }

    private nonisolated static func build() -> Pipeline? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "curlVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "curlFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToZero
            samplerDescriptor.tAddressMode = .clampToZero
            samplerDescriptor.normalizedCoordinates = true
            guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
            return Pipeline(device: device, queue: queue, state: state, sampler: sampler, loader: MTKTextureLoader(device: device))
        } catch {
            NSLog("Foolscap: page curl shader failed to build: \(error)")
            return nil
        }
    }
}

/// Plays one curl into a Metal layer from a thread of its own, paced by the
/// display. The main thread is free the whole time, so the new page can be
/// built underneath without the curl stopping for it, and the curl starts the
/// moment it is asked for.
///
/// Frames come from a `CAMetalDisplayLink` run on the curl's thread: it hands over
/// a drawable per display refresh and carries the request for the display's full
/// rate (a ProMotion panel sits at 60–80 Hz unless the content that draws asks for
/// 120; `nextDrawable` alone asks for nothing). Should the link not fire, the old
/// `nextDrawable` loop plays the turn instead.
final class PageCurlAnimator: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Frame: Sendable {
        var origin: CGPoint      // the page's top-left in the layer, in points
        var size: CGSize         // the page, in points
        var scale: Double        // pixels per point
        var spineOnRight: Bool
        var paper: RGBA
        var style: PageCurlStyle
        var duration: TimeInterval
    }

    private let pipeline: PageCurlRenderer.Pipeline
    private let layer: CAMetalLayer
    private let image: CGImage
    private let frame: Frame
    private let lock = NSLock()
    private var cancelled = false
    // The curl thread's own: the texture, the clock and the frame count.
    private var texture: MTLTexture?
    private var started: CFTimeInterval = 0
    private var frames = 0
    private var finished = false

    init(pipeline: PageCurlRenderer.Pipeline, layer: CAMetalLayer, image: CGImage, frame: Frame) {
        self.pipeline = pipeline; self.layer = layer; self.image = image; self.frame = frame
    }

    /// Start at once; `onEnd` runs on the main thread when the page has gone.
    func start(onEnd: @escaping @MainActor @Sendable () -> Void) {
        let thread = Thread { [self] in
            run()
            DispatchQueue.main.async { onEnd() }
        }
        thread.name = "Foolscap page curl"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() { lock.withLock { cancelled = true } }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func run() {
        let begun = CACurrentMediaTime()
        // Without leave to read the window the window server hands back an empty image:
        // then there is nothing to curl and the page simply changes underneath.
        guard Self.hasContent(image), let texture = Self.makeTexture(from: image, pipeline: pipeline) else {
            if pageTurnLogging { NSLog("Foolscap turn: empty photograph, no curl") }
            return
        }
        self.texture = texture
        if pageTurnLogging { NSLog("Foolscap turn: texture %.1f ms", (CACurrentMediaTime() - begun) * 1000) }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.preferredFrameLatency = 1
        link.delegate = self
        link.add(to: .current, forMode: .default)
        started = CACurrentMediaTime()
        // The link calls back on this run loop; a link that never fires (nothing
        // on screen yet) hands over to the polling loop after a few frames' worth.
        while !finished, !isCancelled {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if frames == 0, CACurrentMediaTime() - started > 0.1 { break }
        }
        link.invalidate()
        if frames == 0, !isCancelled {
            if pageTurnLogging { NSLog("Foolscap turn: the display link did not fire; polling") }
            runPolling(texture: texture, begun: begun)
            return
        }
        if pageTurnLogging { NSLog("Foolscap turn: %d frames in %.0f ms (display link)", frames, (CACurrentMediaTime() - started) * 1000) }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let texture, !finished, !isCancelled else { return }
        // Progress at the moment this frame will be on screen.
        let x = min(1, max(0, (update.targetTimestamp - started) / frame.duration))
        autoreleasepool { draw(progress: PageTurnPace.eased(x), drawable: update.drawable, texture: texture) }
        frames += 1
        if pageTurnLogging, frames == 1 { NSLog("Foolscap turn: first frame %.1f ms after the clock started", (CACurrentMediaTime() - started) * 1000) }
        if x >= 1 { finished = true }
    }

    /// The fallback: `nextDrawable` waits for a free drawable, which paces the
    /// loop to the display at whatever rate it is running.
    private func runPolling(texture: MTLTexture, begun: CFTimeInterval) {
        let start = CACurrentMediaTime()
        var frames = 0
        while !isCancelled {
            let x = min(1, (CACurrentMediaTime() - start) / frame.duration)
            let progress = PageTurnPace.eased(x)
            autoreleasepool {
                if let drawable = layer.nextDrawable() { draw(progress: progress, drawable: drawable, texture: texture) }
            }
            frames += 1
            if x >= 1 { break }
        }
        if pageTurnLogging { NSLog("Foolscap turn: %d frames in %.0f ms (polling)", frames, (CACurrentMediaTime() - start) * 1000) }
    }

    /// One frame into `drawable`.
    private func draw(progress: Double, drawable: CAMetalDrawable, texture: MTLTexture) {
        guard let command = pipeline.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let fold = PageCurlGeometry(style: frame.style, size: frame.size, progress: progress, overshoot: NotebookMetrics.facingWidth)
        // The last sliver over the facing strip fades rather than vanishing.
        let tail = max(0, min(1, (progress - 0.88) / 0.12))
        var u = PageCurlRenderer.Uniforms(
            origin: SIMD2(Float(frame.origin.x), Float(frame.origin.y)), size: SIMD2(Float(frame.size.width), Float(frame.size.height)),
            axis: SIMD2(Float(fold.axis.x), Float(fold.axis.y)), line: Float(fold.line), radius: Float(fold.radius),
            flip: frame.spineOnRight ? 0 : 1, scale: Float(frame.scale),
            paper: SIMD4(Float(frame.paper.r), Float(frame.paper.g), Float(frame.paper.b), 1),
            opacity: Float(1 - tail * tail * (3 - 2 * tail)))
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBytes(&u, length: MemoryLayout<PageCurlRenderer.Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(pipeline.sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// A page always has something in the middle; an all-zero photograph is the
    /// window server refusing. Reads the bytes, so it runs here, not on the main thread.
    private static func hasContent(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        for (fx, fy) in [(0.5, 0.5), (0.2, 0.2), (0.8, 0.8)] {
            let offset = Int(Double(image.height) * fy) * image.bytesPerRow + Int(Double(image.width) * fx) * 4
            guard offset + 4 <= length else { continue }
            if (0..<4).contains(where: { bytes[offset + $0] != 0 }) { return true }
        }
        return false
    }

    /// The photograph as a texture. Its bytes go straight in when they are
    /// 32-bit premultiplied in either byte order (the window server's and the
    /// bitmap cache's formats); anything else goes through the texture loader.
    private static func makeTexture(from image: CGImage, pipeline: PageCurlRenderer.Pipeline) -> MTLTexture? {
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let format: MTLPixelFormat?
        switch (image.alphaInfo, little) {
        case (.premultipliedFirst, true), (.noneSkipFirst, true): format = .bgra8Unorm
        case (.premultipliedLast, false), (.noneSkipLast, false): format = .rgba8Unorm
        default: format = nil
        }
        if image.bitsPerPixel == 32, let format, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * image.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: image.width, height: image.height, mipmapped: false)
            descriptor.usage = .shaderRead
            if let texture = pipeline.device.makeTexture(descriptor: descriptor) {
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: image.bytesPerRow)
                return texture
            }
        }
        return try? pipeline.loader.newTexture(cgImage: image, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
    }
}
