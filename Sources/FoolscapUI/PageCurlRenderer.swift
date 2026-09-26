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

    // The flat photograph at a page coordinate (mirrored when the free edge is on the right).
    static half4 flatSample(texture2d<half> page, sampler smp, constant CurlUniforms& u, float2 q) {
        float2 p = float2(u.flip > 0.5 ? u.size.x - q.x : q.x, q.y);
        return page.sample(smp, p / u.size);
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
            // The page has lifted away here: only its shadow on whatever lies beneath.
            float reach = u.radius * 1.5 + 20.0;
            float t = clamp((s - u.radius) / reach, 0.0, 1.0);
            float a = 0.30 * (1.0 - t) * (1.0 - t);
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
final class PageCurlAnimator: @unchecked Sendable {
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

    private func run() {
        let begun = CACurrentMediaTime()
        guard let texture = Self.makeTexture(from: image, pipeline: pipeline) else { return }
        if pageTurnLogging { NSLog("Foolscap turn: texture %.1f ms", (CACurrentMediaTime() - begun) * 1000) }
        let start = CACurrentMediaTime()
        var frames = 0
        while !lock.withLock({ cancelled }) {
            let x = min(1, (CACurrentMediaTime() - start) / frame.duration)
            let progress = PageTurnPace.eased(x)
            autoreleasepool { draw(progress: progress, texture: texture) }
            frames += 1
            if pageTurnLogging, frames == 1 { NSLog("Foolscap turn: first frame %.1f ms after the texture began", (CACurrentMediaTime() - begun) * 1000) }
            if x >= 1 { break }
        }
        if pageTurnLogging { NSLog("Foolscap turn: %d frames in %.0f ms", frames, (CACurrentMediaTime() - start) * 1000) }
    }

    /// One frame. `nextDrawable` waits for a free drawable, which paces the
    /// loop to the display.
    private func draw(progress: Double, texture: MTLTexture) {
        guard let drawable = layer.nextDrawable(), let command = pipeline.queue.makeCommandBuffer() else { return }
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
