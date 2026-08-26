import CoreMotion
import MetalKit
import SwiftUI
import simd

/// The Metal renderer for the voice orb. All of the motion lives in `OrbSimulation`,
/// which the watch app drives through SpriteKit; this file is the parts that only make
/// sense with a GPU: the pipeline, the touch and motion sources, and the uniforms.
struct VoiceOrbView: UIViewRepresentable {
    let levelMeter: AudioLevelMeter
    var isActive: Bool
    var config: OrbConfig
    /// 0 = `OrbConfig.quiet`, 1 = `config`. Ramped as the speech model loads so the
    /// wait reads as the orb assembling itself.
    var presence: Double = 1

    func makeCoordinator() -> Coordinator {
        Coordinator(levelMeter: levelMeter)
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.simulation.config = config
        context.coordinator.simulation.targetPresence = Float(presence)
        guard let device = MTLCreateSystemDefaultDevice(),
              context.coordinator.configure(device: device)
        else {
            let fallback = UIView()
            fallback.backgroundColor = UIColor(white: 0.04, alpha: 1)
            return fallback
        }

        let view = OrbMTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.isMultipleTouchEnabled = true
        view.onTouchesChanged = { [weak coordinator = context.coordinator] points in
            coordinator?.updateTouches(points)
        }
        view.onVisibilityChanged = { [weak coordinator = context.coordinator] visible in
            coordinator?.setVisible(visible)
        }
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.levelMeter = levelMeter
        context.coordinator.simulation.isActive = isActive
        context.coordinator.simulation.config = config
        context.coordinator.simulation.targetPresence = Float(presence)
    }

    struct Uniforms {
        var params: SIMD4<Float>
        var color: SIMD4<Float>
    }

    struct GlowUniforms {
        var params: SIMD4<Float>
        var params2: SIMD4<Float>
        var color: SIMD4<Float>
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        fileprivate var levelMeter: AudioLevelMeter
        let simulation = OrbSimulation()

        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var glowPipelineState: MTLRenderPipelineState?
        private var particleBuffer: MTLBuffer?

        private var startTime = CACurrentMediaTime()
        private var lastTime = CACurrentMediaTime()

        private let motion = CMMotionManager()
        private var touchTargets: [AnyHashable: SIMD2<Float>] = [:]

        init(levelMeter: AudioLevelMeter) {
            self.levelMeter = levelMeter
        }

        deinit {
            motion.stopDeviceMotionUpdates()
        }

        func updateTouches(_ points: [AnyHashable: SIMD2<Float>]) {
            touchTargets = points
        }

        func configure(device: MTLDevice) -> Bool {
            guard let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary(),
                  let vertexFn = library.makeFunction(name: "particle_vertex"),
                  let fragmentFn = library.makeFunction(name: "particle_fragment"),
                  let glowVertexFn = library.makeFunction(name: "glow_vertex"),
                  let glowFragmentFn = library.makeFunction(name: "glow_fragment")
            else { return false }

            func descriptor(_ vertex: MTLFunction, _ fragment: MTLFunction)
                -> MTLRenderPipelineDescriptor {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = .bgra8Unorm
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
                return descriptor
            }

            guard let state = try? device.makeRenderPipelineState(
                      descriptor: descriptor(vertexFn, fragmentFn)),
                  let glowState = try? device.makeRenderPipelineState(
                      descriptor: descriptor(glowVertexFn, glowFragmentFn)),
                  let buffer = device.makeBuffer(
                      length: simulation.particleCount * MemoryLayout<OrbParticle>.stride,
                      options: .storageModeShared)
            else { return false }

            commandQueue = queue
            pipelineState = state
            glowPipelineState = glowState
            particleBuffer = buffer

            return true
        }

        /// Device motion is only worth sampling while the orb is actually on screen —
        /// `setVisible(false)` covers both a backgrounded app and a detail view pushed
        /// on top, which would otherwise leave a second 60 Hz sampler running.
        func setVisible(_ visible: Bool) {
            guard motion.isDeviceMotionAvailable else { return }
            if visible {
                guard !motion.isDeviceMotionActive else { return }
                motion.deviceMotionUpdateInterval = 1.0 / 60.0
                motion.startDeviceMotionUpdates()
            } else {
                motion.stopDeviceMotionUpdates()
                simulation.resetTiltBaseline()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipelineState,
                  let commandQueue,
                  let particleBuffer,
                  let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor
            else { return }

            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastTime, 1.0 / 30.0))
            lastTime = now
            let t = Float(now - startTime)

            let size = view.drawableSize
            let aspect = size.height > 0 ? Float(size.width / size.height) : 1

            let gravity = motion.deviceMotion.map {
                SIMD2<Float>(Float($0.gravity.x), Float($0.gravity.y))
            }

            let gpu = UnsafeMutableBufferPointer(
                start: particleBuffer.contents().bindMemory(
                    to: OrbParticle.self, capacity: simulation.particleCount),
                count: simulation.particleCount)
            let frame = simulation.step(
                dt: dt, time: t, aspect: aspect, level: levelMeter.read(),
                gravity: gravity, touches: touchTargets, into: gpu)
            let cfg = frame.config

            let d = cfg.bgDarkness
            view.clearColor = MTLClearColor(red: d, green: d, blue: d * 1.1, alpha: 1)

            let rgb = cfg.rgb
            var uniforms = Uniforms(
                params: SIMD4(frame.level, Float(cfg.sizeExpand), aspect, Float(cfg.falloff)),
                color: SIMD4(rgb.x, rgb.y, rgb.z, 0))

            let glowRgb = cfg.glowRgb
            var glowUniforms = GlowUniforms(
                params: SIMD4(
                    frame.glowIntensity, frame.glowRadius,
                    Float(cfg.glowFalloff), Float(cfg.glowHaloMix)),
                params2: SIMD4(frame.tilt.x * 0.7, frame.tilt.y * 0.7, aspect, 1.0 / 255.0),
                color: SIMD4(glowRgb.x, glowRgb.y, glowRgb.z, 0))

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else { return }

            if let glowPipelineState, glowUniforms.params.x > 0.001 {
                encoder.setRenderPipelineState(glowPipelineState)
                encoder.setVertexBytes(
                    &glowUniforms, length: MemoryLayout<GlowUniforms>.stride, index: 2)
                encoder.setFragmentBytes(
                    &glowUniforms, length: MemoryLayout<GlowUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.drawCount)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

final class OrbMTKView: MTKView {
    var onTouchesChanged: (([AnyHashable: SIMD2<Float>]) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    private var points: [AnyHashable: SIMD2<Float>] = [:]
    private var isBackgrounded = false

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(applicationDidBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(applicationWillForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func applicationDidBackground() {
        isBackgrounded = true
        updateActivity()
    }

    @objc private func applicationWillForeground() {
        isBackgrounded = false
        updateActivity()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateActivity()
    }

    /// Submitting GPU work from the background is not allowed, and a full-rate particle
    /// system behind a pushed detail view is pure battery burn. Both stop the render loop.
    private func updateActivity() {
        let visible = window != nil && !isBackgrounded
        isPaused = !visible
        onVisibilityChanged?(visible)
    }

    private func normalized(_ touch: UITouch) -> SIMD2<Float> {
        let loc = touch.location(in: self)
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        return SIMD2(Float(loc.x / w) * 2 - 1, 1 - Float(loc.y / h) * 2)
    }

    private func add(_ touches: Set<UITouch>) {
        for touch in touches { points[ObjectIdentifier(touch)] = normalized(touch) }
        onTouchesChanged?(points)
    }

    private func remove(_ touches: Set<UITouch>) {
        for touch in touches { points.removeValue(forKey: ObjectIdentifier(touch)) }
        onTouchesChanged?(points)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { add(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { add(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
}
