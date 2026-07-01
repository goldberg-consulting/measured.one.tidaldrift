import Foundation
import AppKit
import MetalKit
import OSLog
import CoreVideo

class MetalRenderer: NSObject, MTKViewDelegate {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "MetalRenderer")
    private let mtkView: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var nv12PipelineState: MTLRenderPipelineState?
    
    private var textureCache: CVMetalTextureCache?

    /// A decoded frame plus the references that keep its IOSurface alive. The
    /// MTLTexture(s) are backed by the CVImageBuffer via the texture cache, so we
    /// must retain both the CVMetalTexture wrapper(s) and the source buffer for as
    /// long as the texture is in use, or VideoToolbox recycles that IOSurface
    /// for a later frame and the GPU samples a buffer being overwritten (tearing).
    /// NV12 frames carry a luma (`texture`, plane 0) and chroma (`chromaTexture`,
    /// plane 1); BGRA frames (region-aware tiles' heal path) carry only `texture`.
    private struct DecodedFrame {
        let texture: MTLTexture
        let chromaTexture: MTLTexture?
        let cvTextures: [CVMetalTexture]
        let pixelBuffer: CVImageBuffer
        let isNV12: Bool
        let width: Int
        let height: Int
    }

    // MARK: - Adaptive jitter buffer
    //
    // Frames arrive in clumps (the link's ±30-40 ms jitter), so presenting each
    // one the instant it decodes makes motion play back unevenly even when no
    // frame is lost. We queue decoded frames and release them on a steady,
    // time-based cadence (the measured source interval), decoupled from both
    // bursty arrival and the display refresh rate. The buffer depth adapts to
    // measured jitter: deeper when the link is jittery, ~1 frame when it's
    // clean, so we add only as much latency as smoothness requires.
    private let frameQueueLock = NSLock()
    private var frameQueue: [DecodedFrame] = []
    private var lastPresentedFrame: DecodedFrame?
    private var primed = false
    private var lastPresentTime: CFTimeInterval = 0

    private var lastArrival: CFTimeInterval = 0
    private var arrivalIntervalEWMA: Double = 1.0 / 60.0  // est. source frame interval
    private var jitterEWMA: Double = 0
    private var targetDepth = 2
    var latencyMode: LocalCastConfiguration.LatencyMode =
        (UserDefaults.standard.string(forKey: "localCastLatencyMode")
            .flatMap(LocalCastConfiguration.LatencyMode.init(rawValue:))) ?? .low

    private var minDepth: Int {
        switch latencyMode {
        case .low: return 0
        case .balanced: return 1
        case .smooth: return 2
        }
    }

    private var maxDepth: Int {
        switch latencyMode {
        case .low: return 2
        case .balanced: return 6
        case .smooth: return 10
        }
    }

    // MARK: - Region-aware canvas
    //
    // When the host streams region-aware (tile) updates, the client keeps a
    // persistent canvas texture: full frames replace it, tiles patch sub-rects,
    // and the canvas is presented every display tick. Activated on the first
    // tileUpdate, so the default full-frame jitter-buffer path is unchanged.
    // All canvas mutations and presentation happen on the main thread (the MTKView
    // draw callback and the dispatched apply/update blocks), so blits and the
    // present are committed to one queue in order (no GPU read/write race).
    private var canvasMode = false
    private var canvasTexture: MTLTexture?

    /// Set whenever the canvas contents change (tile blit, full-frame heal,
    /// resize), cleared after the canvas is presented. Lets the draw loop skip
    /// GPU passes on ticks where nothing changed. Main thread only, like all
    /// canvas mutations.
    private var canvasDirty = false

    // MARK: - Pause control
    //
    // The MTKView display link runs continuously while streaming (the jitter
    // buffer paces against it), but there is no reason to keep it firing when
    // the session is disconnected or the window is not visible. Reasons are
    // independent so occlusion and disconnect cannot stomp each other's state.
    // Main thread only.
    enum PauseReason: Hashable {
        case disconnected
        case notVisible
    }
    private var pauseReasons: Set<PauseReason> = []

    /// Add or remove a pause reason; the view is paused while any reason holds.
    func setPaused(_ paused: Bool, reason: PauseReason) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if paused {
                self.pauseReasons.insert(reason)
            } else {
                self.pauseReasons.remove(reason)
            }
            self.mtkView.isPaused = !self.pauseReasons.isEmpty
        }
    }

    /// Current jitter-buffer depth (frames queued), for the stats HUD.
    var currentBufferDepth: Int {
        frameQueueLock.lock(); defer { frameQueueLock.unlock() }
        return frameQueue.count
    }

    /// MTKView size for input coordinate normalization.
    var viewSize: CGSize { mtkView.frame.size }

    /// Convert a point from the SwiftUI hosting content view into the MTKView's
    /// coordinate space. This keeps input aligned in full screen where overlays
    /// live in the hosting view but the video is rendered by the Metal view.
    func viewPoint(fromContentPoint point: NSPoint, in contentView: NSView) -> NSPoint {
        let windowPoint = contentView.convert(point, to: nil)
        return mtkView.convert(windowPoint, from: nil)
    }

    /// Convert a window-base point (e.g. `NSEvent.locationInWindow`) into the
    /// MTKView's coordinate space. Input must be normalized against the Metal
    /// view's own bounds, not the hosting view: with a full-size content view and
    /// a transparent titlebar SwiftUI insets the Metal view by the top safe area
    /// in windowed mode, so mapping against the hosting view leaves a vertical
    /// offset that vanishes in full screen (no titlebar). This routes input
    /// through the exact surface the video is drawn on.
    func viewPoint(fromWindowPoint point: NSPoint) -> NSPoint {
        mtkView.convert(point, from: nil)
    }

    /// Whether the Metal view uses a flipped (top-left origin) coordinate space.
    var isViewFlipped: Bool { mtkView.isFlipped }
    private var vertices: MTLBuffer?
    private var texCoords: MTLBuffer?
    /// Full-screen (-1..1) quad, used when converting an NV12 heal frame into
    /// the BGRA canvas (no letterboxing, the target is exactly source-sized).
    private var identityVertices: MTLBuffer?
    
    private var frameCount = 0
    private var hasLoggedSuccess = false
    
    // Track source resolution for aspect-ratio-preserving scaling
    private var sourceWidth: Int = 0
    private var sourceHeight: Int = 0
    
    // Track last drawable size so we recalculate vertices when it changes
    private var lastDrawableSize: CGSize = .zero
    
    deinit {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
    
    init(mtkView: MTKView) {
        self.mtkView = mtkView
        self.device = mtkView.device ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        
        // Create texture cache for converting CVPixelBuffer to MTLTexture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
        
        // Create a simple render pipeline for displaying textures
        // MUST compile shaders from source since we don't have a .metallib in bundle
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                       constant float2 *vertices [[buffer(0)]],
                                       constant float2 *texCoords [[buffer(1)]]) {
            VertexOut out;
            out.position = float4(vertices[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }
        
        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> texture [[texture(0)]]) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            return texture.sample(textureSampler, in.texCoord);
        }
        
        // Full-range BT.709: Y is sampled from the luma (r8) plane, Cb/Cr from
        // the chroma (rg8) plane. Capture is kCVPixelFormatType_420Yp...FullRange,
        // so Y is not scaled (full 0..1) and only the chroma is centred at 0.5.
        // These coefficients must match the capture range/primaries or output
        // is washed out (wrong range) or tinted (wrong matrix).
        fragment float4 fragmentShaderNV12(VertexOut in [[stage_in]],
                                           texture2d<float> lumaTexture [[texture(0)]],
                                           texture2d<float> chromaTexture [[texture(1)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            float y = lumaTexture.sample(s, in.texCoord).r;
            float2 cbcr = chromaTexture.sample(s, in.texCoord).rg;
            float cb = cbcr.r - 0.5;
            float cr = cbcr.g - 0.5;
            float r = y + 1.5748 * cr;
            float g = y - 0.1873 * cb - 0.4681 * cr;
            float b = y + 1.8556 * cb;
            return float4(r, g, b, 1.0);
        }
        """
        
        // Compile shaders
        var library: MTLLibrary?
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
            logger.info("🖥️ MetalRenderer: Compiled inline shaders successfully")
        } catch {
            logger.error("🖥️ MetalRenderer: Failed to compile shaders: \(error.localizedDescription)")
        }
        
        // Create pipeline state
        if let library = library,
           let vertexFunc = library.makeFunction(name: "vertexShader"),
           let fragmentFunc = library.makeFunction(name: "fragmentShader") {
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunc
            pipelineDescriptor.fragmentFunction = fragmentFunc
            pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            
            do {
                self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
                logger.info("🖥️ MetalRenderer: Created render pipeline state")
            } catch {
                logger.error("🖥️ MetalRenderer: Failed to create pipeline state: \(error.localizedDescription)")
                self.pipelineState = nil
            }

            // Separate pipeline for NV12 video frames: same vertex stage, YUV->RGB
            // fragment stage sampling the two planes. The view's color format is
            // bgra8Unorm, which also matches the canvas heal render target.
            if let nv12Func = library.makeFunction(name: "fragmentShaderNV12") {
                let nv12Descriptor = MTLRenderPipelineDescriptor()
                nv12Descriptor.vertexFunction = vertexFunc
                nv12Descriptor.fragmentFunction = nv12Func
                nv12Descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
                do {
                    self.nv12PipelineState = try device.makeRenderPipelineState(descriptor: nv12Descriptor)
                    logger.info("🖥️ MetalRenderer: Created NV12 render pipeline state")
                } catch {
                    logger.error("🖥️ MetalRenderer: Failed to create NV12 pipeline state: \(error.localizedDescription)")
                    self.nv12PipelineState = nil
                }
            }
        } else {
            logger.error("🖥️ MetalRenderer: Could not create shader functions")
            self.pipelineState = nil
        }
        
        // Create initial vertex buffer for a full-screen quad (will be updated for aspect ratio)
        let vertexData: [Float] = [
            -1.0, -1.0,  // Bottom left
             1.0, -1.0,  // Bottom right
            -1.0,  1.0,  // Top left
             1.0,  1.0   // Top right
        ]
        self.vertices = device.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.stride, options: [])
        
        let texCoordData: [Float] = [
            0.0, 1.0,  // Bottom left
            1.0, 1.0,  // Bottom right
            0.0, 0.0,  // Top left
            1.0, 0.0   // Top right
        ]
        self.texCoords = device.makeBuffer(bytes: texCoordData, length: texCoordData.count * MemoryLayout<Float>.stride, options: [])
        
        let identityData: [Float] = [
            -1.0, -1.0,
             1.0, -1.0,
            -1.0,  1.0,
             1.0,  1.0
        ]
        self.identityVertices = device.makeBuffer(bytes: identityData, length: identityData.count * MemoryLayout<Float>.stride, options: [])
        
        super.init()
        
        mtkView.device = device
        mtkView.delegate = self
        // Display-linked: draw at the display cadence and release one buffered
        // frame per measured source interval. The jitter buffer needs a steady
        // tick to pace against, so we cannot use draw-on-demand here.
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = Self.displayMaxFPS(for: mtkView)
        mtkView.framebufferOnly = false  // Allow texture sampling
        
        if pipelineState != nil {
            logger.info("MetalRenderer initialized successfully")
        } else {
            logger.error("MetalRenderer initialized but pipeline state is INVALID - video will NOT render!")
        }
    }
    
    /// Update vertex buffer to maintain aspect ratio when view/source size changes.
    /// Pass the view size explicitly to avoid reading a stale `drawableSize`.
    private func updateVertexBufferForAspectRatio(viewSize: CGSize? = nil) {
        guard sourceWidth > 0 && sourceHeight > 0 else { return }
        
        let size = viewSize ?? mtkView.drawableSize
        guard size.width > 0 && size.height > 0 else { return }
        
        // Skip if nothing changed
        if size == lastDrawableSize { return }
        lastDrawableSize = size
        
        let sourceAspect = CGFloat(sourceWidth) / CGFloat(sourceHeight)
        let viewAspect = size.width / size.height
        
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        
        if sourceAspect > viewAspect {
            // Source is wider than view — letterbox (black bars top/bottom)
            scaleY = Float(viewAspect / sourceAspect)
        } else if sourceAspect < viewAspect {
            // Source is taller than view — pillarbox (black bars left/right)
            scaleX = Float(sourceAspect / viewAspect)
        }
        // If equal, no scaling needed (full screen fill)
        
        // Update vertex positions to maintain aspect ratio
        let vertexData: [Float] = [
            -scaleX, -scaleY,  // Bottom left
             scaleX, -scaleY,  // Bottom right
            -scaleX,  scaleY,  // Top left
             scaleX,  scaleY   // Top right
        ]
        
        self.vertices = device.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.stride, options: [])
    }
    
    func update(with imageBuffer: CVImageBuffer) {
        guard let cache = textureCache else {
            if !hasLoggedSuccess {
                lcDebug("🖥️ MetalRenderer: ❌ No texture cache available")
            }
            return
        }
        
        guard pipelineState != nil else {
            if !hasLoggedSuccess {
                lcDebug("🖥️ MetalRenderer: ❌ No valid pipeline state - cannot render")
            }
            return
        }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        // Pick the pipeline per frame off the incoming pixel format so a mixed
        // session renders both: decoded video arrives as NV12 (two planes), the
        // region-aware heal path also arrives as NV12, and any BGRA buffer falls
        // back to the single-texture pipeline.
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        // Only full-range routes to the NV12 pipeline: the shader applies
        // full-range BT.709 math (no 16-235 expansion). Capture and decode are
        // both FullRange, so a VideoRange buffer never reaches here; treating one
        // as full range would wash the image out.
        let isNV12 = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        guard let frame = isNV12
            ? makeNV12Frame(imageBuffer, width: width, height: height, cache: cache)
            : makeBGRAFrame(imageBuffer, width: width, height: height, cache: cache, pixelFormat: pixelFormat) else {
            return
        }

        // Region-aware: a full frame replaces the canvas (it's the periodic /
        // on-request refresh that heals lost tiles). The canvas is BGRA (tiles
        // arrive as BGRA), so an NV12 heal frame is converted to BGRA first. Done
        // on the main thread so it orders correctly with tile blits and present.
        if canvasMode {
            frameCount += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.ensureCanvas(width: width, height: height, seedFrom: nil)
                if frame.isNV12 {
                    if let bgra = self.renderNV12ToBGRA(frame) {
                        self.blitIntoCanvas(bgra, atX: 0, y: 0, retain: bgra)
                    }
                } else {
                    self.blitIntoCanvas(frame.texture, atX: 0, y: 0, retain: frame)
                }
            }
            return
        }

        // Adapt the buffer depth to measured arrival jitter: depth grows with
        // (jitter / frame interval) so a jittery link gets enough cushion, while
        // a clean link stays near one frame of latency.
        let now = CACurrentMediaTime()
        if lastArrival > 0 {
            let interval = now - lastArrival
            let a = 0.1
            let dev = abs(interval - arrivalIntervalEWMA)
            arrivalIntervalEWMA = (1 - a) * arrivalIntervalEWMA + a * interval
            jitterEWMA = (1 - a) * jitterEWMA + a * dev
            let fi = max(arrivalIntervalEWMA, 1.0 / 120.0)
            targetDepth = min(maxDepth, max(minDepth, Int((jitterEWMA / fi).rounded()) + 1))
        }
        lastArrival = now

        frameQueueLock.lock()
        frameQueue.append(frame)
        // Drop-to-newest if the queue outgrows the cap (we're behind).
        if frameQueue.count > maxDepth {
            frameQueue.removeFirst(frameQueue.count - maxDepth)
        }
        frameQueueLock.unlock()

        frameCount += 1
        // A live frame means the stream is (back) up; clear any disconnect
        // pause so the display link resumes presenting.
        setPaused(false, reason: .disconnected)
        if !hasLoggedSuccess {
            logger.info("🖥️ MetalRenderer: First frame received! \(width)x\(height)")
            hasLoggedSuccess = true
        }
        if frameCount % 120 == 0, let cache = textureCache {
            // Flush stale cache entries periodically to bound GPU memory.
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
    
    /// Maximum refresh rate of the screen hosting the view (falling back to the
    /// main screen, then 60). 120 on ProMotion panels, so a 120fps stream is not
    /// halved by the display link.
    private static func displayMaxFPS(for view: NSView) -> Int {
        let fps = (view.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        return fps > 0 ? fps : 60
    }

    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        logger.info("View size changed to \(size.width)x\(size.height)")
        // The view has a window by now (and may have moved displays), so refresh
        // the display-link cap from the hosting screen's real refresh rate.
        view.preferredFramesPerSecond = Self.displayMaxFPS(for: view)
        // Recalculate aspect ratio using the new size (not the possibly-stale drawableSize)
        updateVertexBufferForAspectRatio(viewSize: size)
        // Trigger a redraw so the new vertices take effect immediately
        DispatchQueue.main.async { view.needsDisplay = true }
    }
    
    func draw(in view: MTKView) {
        guard pipelineState != nil else { return }

        // A display tick only needs a GPU pass when there is something new: a
        // freshly dequeued frame, a canvas update, or a drawable resize.
        // Re-presenting the identical texture every tick ran a full render +
        // present at up to 120 Hz on a static or disconnected stream, which was
        // the client's dominant CPU/GPU heat source. The drawable retains its
        // last contents between presents, so skipping is visually a no-op.
        let sizeChanged = view.drawableSize != lastDrawableSize

        // Region-aware: present the persistent canvas only when it changed.
        if canvasMode {
            guard let canvas = canvasTexture else { return }
            if !canvasDirty && !sizeChanged { return }
            canvasDirty = false
            presentTexture(canvas, chroma: nil, srcWidth: canvas.width, srcHeight: canvas.height, in: view, retain: nil)
            return
        }

        // Pacing: release one buffered frame per measured source interval, after
        // priming to the adaptive target depth.
        let now = CACurrentMediaTime()
        frameQueueLock.lock()
        if !primed, frameQueue.count >= targetDepth {
            primed = true
        }
        var dequeuedNewFrame = false
        if primed {
            let interval = max(arrivalIntervalEWMA, 1.0 / 120.0)
            // Low latency: with at most one queued frame there is no backlog to
            // pace through, so present it on this tick instead of waiting out
            // the gate (saves up to a display interval per frame). Pacing still
            // applies in .low when the queue is deeper, and always in the
            // other modes.
            let bypassPacing = latencyMode == .low && frameQueue.count <= 1
            let due = bypassPacing || (now - lastPresentTime) >= interval * 0.85
            if due {
                if frameQueue.isEmpty {
                    if !bypassPacing {
                        primed = false  // underrun: re-buffer before resuming
                    }
                } else {
                    lastPresentedFrame = frameQueue.removeFirst()
                    lastPresentTime = now
                    dequeuedNewFrame = true
                }
            }
        }
        let frame = lastPresentedFrame
        frameQueueLock.unlock()

        guard let frame = frame else { return }
        if !dequeuedNewFrame && !sizeChanged { return }
        presentTexture(frame.texture, chroma: frame.chromaTexture, srcWidth: frame.width, srcHeight: frame.height, in: view, retain: frame)
    }

    /// Draw a texture to the view's drawable with aspect-ratio letterboxing.
    /// When `chroma` is non-nil the source is NV12 and the YUV->RGB pipeline runs
    /// (luma at index 0, chroma at index 1); otherwise the BGRA pipeline samples
    /// `texture` directly. `retain` is held until the GPU finishes so a recycled
    /// IOSurface can't be overwritten mid-read.
    private func presentTexture(_ texture: MTLTexture, chroma: MTLTexture?, srcWidth: Int, srcHeight: Int, in view: MTKView, retain: Any?) {
        let pipeline = chroma != nil ? nv12PipelineState : pipelineState
        guard let pipeline,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        if srcWidth != sourceWidth || srcHeight != sourceHeight {
            sourceWidth = srcWidth
            sourceHeight = srcHeight
            lastDrawableSize = .zero
            updateVertexBufferForAspectRatio(viewSize: view.drawableSize)
            logger.info("🖥️ MetalRenderer: Source resolution changed to \(srcWidth)x\(srcHeight)")
        }
        let currentSize = view.drawableSize
        if currentSize != lastDrawableSize {
            updateVertexBufferForAspectRatio(viewSize: currentSize)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setVertexBuffer(vertices, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(texCoords, offset: 0, index: 1)
        renderEncoder.setFragmentTexture(texture, index: 0)
        if let chroma { renderEncoder.setFragmentTexture(chroma, index: 1) }
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        if let retain { commandBuffer.addCompletedHandler { _ in _ = retain } }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Wrap an NV12 image buffer as two Metal textures: plane 0 luma as `.r8Unorm`
    /// (full res) and plane 1 chroma as `.rg8Unorm` (half res). Both texture-cache
    /// wrappers are retained so the source IOSurface stays alive while in use.
    private func makeNV12Frame(_ imageBuffer: CVImageBuffer, width: Int, height: Int, cache: CVMetalTextureCache) -> DecodedFrame? {
        let lumaWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 1)

        var lumaCV: CVMetalTexture?
        var chromaCV: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, imageBuffer, nil, .r8Unorm, lumaWidth, lumaHeight, 0, &lumaCV)
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, imageBuffer, nil, .rg8Unorm, chromaWidth, chromaHeight, 1, &chromaCV)

        guard lumaStatus == kCVReturnSuccess, chromaStatus == kCVReturnSuccess,
              let lumaCV, let chromaCV,
              let luma = CVMetalTextureGetTexture(lumaCV),
              let chroma = CVMetalTextureGetTexture(chromaCV) else {
            logger.error("🖥️ MetalRenderer: Failed to create NV12 plane textures: \(lumaStatus)/\(chromaStatus)")
            return nil
        }

        return DecodedFrame(
            texture: luma,
            chromaTexture: chroma,
            cvTextures: [lumaCV, chromaCV],
            pixelBuffer: imageBuffer,
            isNV12: true,
            width: width,
            height: height
        )
    }

    /// Wrap a packed BGRA (or RGBA) image buffer as a single Metal texture.
    private func makeBGRAFrame(_ imageBuffer: CVImageBuffer, width: Int, height: Int, cache: CVMetalTextureCache, pixelFormat: OSType) -> DecodedFrame? {
        let mtlPixelFormat: MTLPixelFormat = pixelFormat == kCVPixelFormatType_32RGBA ? .rgba8Unorm : .bgra8Unorm
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, imageBuffer, nil, mtlPixelFormat, width, height, 0, &cvTexture)

        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let mtlTexture = CVMetalTextureGetTexture(cvTex) else {
            logger.error("🖥️ MetalRenderer: Failed to create Metal texture: \(status)")
            return nil
        }

        return DecodedFrame(
            texture: mtlTexture,
            chromaTexture: nil,
            cvTextures: [cvTex],
            pixelBuffer: imageBuffer,
            isNV12: false,
            width: width,
            height: height
        )
    }

    /// Convert an NV12 frame to a BGRA texture via the YUV->RGB pipeline so it can
    /// patch the BGRA canvas. The dest is exactly source-sized, so a full-screen
    /// quad fills it 1:1. Committed on the same queue as the canvas blit, so the
    /// render completes before the blit reads it. Main thread only.
    private func renderNV12ToBGRA(_ frame: DecodedFrame) -> MTLTexture? {
        guard frame.isNV12,
              let chroma = frame.chromaTexture,
              let nv12Pipeline = nv12PipelineState,
              let identityVertices, let texCoords else {
            return nil
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        guard let dest = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = dest
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return nil }

        encoder.setRenderPipelineState(nv12Pipeline)
        encoder.setVertexBuffer(identityVertices, offset: 0, index: 0)
        encoder.setVertexBuffer(texCoords, offset: 0, index: 1)
        encoder.setFragmentTexture(frame.texture, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        let retain = frame
        commandBuffer.addCompletedHandler { _ in _ = retain }
        commandBuffer.commit()
        return dest
    }

    // MARK: - Region-aware tiles (main thread)

    /// Apply a changed screen region into the persistent canvas. Called off the
    /// transport thread; hops to main so it serializes with the present.
    func applyTile(x: Int, y: Int, width: Int, height: Int, bgra: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.canvasTexture == nil {
                // Need a base canvas sized to the stream; seed from the last
                // full frame so we don't start from black.
                guard self.sourceWidth > 0, self.sourceHeight > 0 else { return }
                self.ensureCanvas(width: self.sourceWidth, height: self.sourceHeight, seedFrom: self.lastPresentedFrame)
            }
            guard let canvas = self.canvasTexture,
                  x >= 0, y >= 0, x + width <= canvas.width, y + height <= canvas.height,
                  let tileTex = self.makeSharedTexture(width: width, height: height) else {
                return
            }
            bgra.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                tileTex.replace(region: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
            }
            self.canvasMode = true
            self.blitIntoCanvas(tileTex, atX: x, y: y, retain: tileTex)
        }
    }

    /// Create or resize the canvas, optionally seeding it from a prior frame.
    /// Main thread only.
    private func ensureCanvas(width: Int, height: Int, seedFrom: DecodedFrame?) {
        canvasMode = true
        if let c = canvasTexture, c.width == width, c.height == height { return }
        guard let tex = makeSharedTexture(width: width, height: height) else { return }
        canvasTexture = tex
        sourceWidth = width
        sourceHeight = height
        if let seed = seedFrom, seed.width == width, seed.height == height {
            // The canvas is BGRA; an NV12 seed must be converted first, otherwise
            // the blit copies an r8 luma plane into a bgra8 target (incompatible
            // bytes-per-pixel).
            if seed.isNV12 {
                if let bgra = renderNV12ToBGRA(seed) {
                    blitIntoCanvas(bgra, atX: 0, y: 0, retain: bgra)
                }
            } else {
                blitIntoCanvas(seed.texture, atX: 0, y: 0, retain: seed)
            }
        }
    }

    private func makeSharedTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    /// Copy a source texture into the canvas at (x, y). Main thread only.
    private func blitIntoCanvas(_ src: MTLTexture, atX x: Int, y: Int, retain: Any?) {
        guard let canvas = canvasTexture else { return }
        let w = min(src.width, canvas.width - x)
        let h = min(src.height, canvas.height - y)
        guard w > 0, h > 0,
              let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: canvas, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: x, y: y, z: 0))
        blit.endEncoding()
        if let retain { cb.addCompletedHandler { _ in _ = retain } }
        cb.commit()
        canvasDirty = true
    }
}
