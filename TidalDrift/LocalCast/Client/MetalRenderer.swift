import Foundation
import MetalKit
import OSLog
import CoreVideo

class MetalRenderer: NSObject, MTKViewDelegate {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "MetalRenderer")
    private let mtkView: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    
    private var textureCache: CVMetalTextureCache?

    /// A decoded frame plus the references that keep its IOSurface alive. The
    /// MTLTexture is backed by the CVImageBuffer via the texture cache, so we
    /// must retain both the CVMetalTexture wrapper and the source buffer for as
    /// long as the texture is in use, or VideoToolbox recycles that IOSurface
    /// for a later frame and the GPU samples a buffer being overwritten (tearing).
    private struct DecodedFrame {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
        let pixelBuffer: CVImageBuffer
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
    private let minDepth = 1
    private let maxDepth = 6
    private var vertices: MTLBuffer?
    private var texCoords: MTLBuffer?
    
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
        
        super.init()
        
        mtkView.device = device
        mtkView.delegate = self
        // Display-linked: draw at the display cadence and release one buffered
        // frame per measured source interval. The jitter buffer needs a steady
        // tick to pace against, so we cannot use draw-on-demand here.
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
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
        
        // Get pixel format
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let mtlPixelFormat: MTLPixelFormat
        
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            mtlPixelFormat = .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            mtlPixelFormat = .rgba8Unorm
        default:
            // Try BGRA as default
            mtlPixelFormat = .bgra8Unorm
            if frameCount < 5 {
                lcDebug("🖥️ MetalRenderer: Unknown pixel format \(pixelFormat), using BGRA")
            }
        }
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            imageBuffer,
            nil,
            mtlPixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let mtlTexture = CVMetalTextureGetTexture(cvTex) else {
            logger.error("🖥️ MetalRenderer: Failed to create Metal texture: \(status)")
            return
        }

        let frame = DecodedFrame(
            texture: mtlTexture,
            cvTexture: cvTex,
            pixelBuffer: imageBuffer,
            width: width,
            height: height
        )

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
        if !hasLoggedSuccess {
            logger.info("🖥️ MetalRenderer: First frame received! \(width)x\(height)")
            hasLoggedSuccess = true
        }
        if frameCount % 120 == 0, let cache = textureCache {
            // Flush stale cache entries periodically to bound GPU memory.
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        logger.info("View size changed to \(size.width)x\(size.height)")
        // Recalculate aspect ratio using the new size (not the possibly-stale drawableSize)
        updateVertexBufferForAspectRatio(viewSize: size)
        // Trigger a redraw so the new vertices take effect immediately
        DispatchQueue.main.async { view.needsDisplay = true }
    }
    
    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState else { return }

        // Pacing: release one buffered frame per measured source interval, after
        // priming to the adaptive target depth. Between releases (or on underrun)
        // re-present the last frame so the display tick always has content.
        let now = CACurrentMediaTime()
        frameQueueLock.lock()
        if !primed, frameQueue.count >= targetDepth {
            primed = true
        }
        if primed {
            let interval = max(arrivalIntervalEWMA, 1.0 / 120.0)
            let due = (now - lastPresentTime) >= interval * 0.85
            if due {
                if frameQueue.isEmpty {
                    primed = false  // underrun: re-buffer before resuming
                } else {
                    lastPresentedFrame = frameQueue.removeFirst()
                    lastPresentTime = now
                }
            }
        }
        let frame = lastPresentedFrame
        frameQueueLock.unlock()

        guard let frame = frame,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        // Update aspect ratio if the source resolution changed.
        if frame.width != sourceWidth || frame.height != sourceHeight {
            sourceWidth = frame.width
            sourceHeight = frame.height
            lastDrawableSize = .zero
            updateVertexBufferForAspectRatio(viewSize: view.drawableSize)
            logger.info("🖥️ MetalRenderer: Source resolution changed to \(frame.width)x\(frame.height)")
        }
        // Catch any missed resize events (full-screen transitions, etc.)
        let currentSize = view.drawableSize
        if currentSize != lastDrawableSize {
            updateVertexBufferForAspectRatio(viewSize: currentSize)
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Clear to black for letterbox/pillarbox areas
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        
        // Use proper render encoder for scaling
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertices, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(texCoords, offset: 0, index: 1)
        renderEncoder.setFragmentTexture(frame.texture, index: 0)
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()

        // Keep the sampled frame alive until the GPU finishes this draw, so its
        // IOSurface can't be recycled and overwritten mid-read.
        commandBuffer.addCompletedHandler { _ in _ = frame }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
