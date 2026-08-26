import CoreMotion
import SpriteKit
import SwiftUI
import simd

/// The voice orb on the wrist.
///
/// watchOS has no Metal and no SwiftUI `Canvas`, so the phone's shader-based renderer
/// cannot come across. SpriteKit can: the motion itself lives in the shared
/// `OrbSimulation`, and this file only turns its output into sprite nodes. The two
/// shaders in `Particles.metal` become two baked textures — a soft dot and a radial
/// glow — composited additively, which is what those shaders were doing anyway.
struct OrbSpriteView: View {
    let levelMeter: AudioLevelMeter
    var isActive: Bool
    /// 0 = `OrbConfig.quiet`, 1 = full. Dropped to 0 when the phone is out of reach, so
    /// the orb going sparse *is* the "not ready" signal, exactly as it is on the phone
    /// before the speech model exists.
    var presence: Double
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene: OrbScene

    init(levelMeter: AudioLevelMeter, isActive: Bool, presence: Double) {
        self.levelMeter = levelMeter
        self.isActive = isActive
        self.presence = presence
        _scene = State(initialValue: OrbScene(levelMeter: levelMeter))
    }

    var body: some View {
        SpriteView(scene: scene, isPaused: scenePhase != .active, preferredFramesPerSecond: 60)
            .onChange(of: isActive, initial: true) { scene.simulation.isActive = isActive }
            .onChange(of: presence, initial: true) {
                scene.simulation.targetPresence = Float(presence)
            }
            .onChange(of: scenePhase, initial: true) { scene.setVisible(scenePhase == .active) }
    }
}

final class OrbScene: SKScene {
    let simulation = OrbSimulation()

    private let levelMeter: AudioLevelMeter
    private let motion = CMMotionManager()
    private var container = SKNode()
    private var glowNode = SKSpriteNode()
    private var nodes: [SKSpriteNode] = []
    /// Scratch buffer the simulation writes into, allocated once alongside the nodes.
    private var particles: [OrbParticle] = []
    private var lastTime: TimeInterval = 0
    private var elapsed: TimeInterval = 0

    /// The glow texture is sampled out to this many glow radii. Past it the shader's
    /// halo term is under 0.2% and contributes nothing but fill rate.
    private static let glowExtent: CGFloat = 4

    init(levelMeter: AudioLevelMeter) {
        self.levelMeter = levelMeter
        super.init(size: .zero)
        simulation.config = .watch
        scaleMode = .resizeFill
        backgroundColor = UIColor(white: 0.04, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Built on the first frame rather than from `didMove(to:)`: `SKView` does not exist
    /// on watchOS, so the usual attach hook is unavailable, and `update` is the first
    /// point where the scene has a real size to lay nodes out against anyway.
    private func buildIfNeeded() {
        guard nodes.isEmpty else { return }
        let cfg = simulation.config
        let rgb = cfg.rgb
        let tint = UIColor(
            red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)

        glowNode = SKSpriteNode(texture: Self.glowTexture(cfg))
        glowNode.blendMode = .add
        glowNode.zPosition = -1
        glowNode.color = UIColor(
            red: CGFloat(cfg.glowRgb.x), green: CGFloat(cfg.glowRgb.y),
            blue: CGFloat(cfg.glowRgb.z), alpha: 1)
        glowNode.colorBlendFactor = 1
        glowNode.alpha = 0
        addChild(glowNode)

        addChild(container)
        particles = Array(
            repeating: OrbParticle(position: .zero, size: 0, brightness: 0),
            count: simulation.particleCount)
        let dot = Self.dotTexture(falloff: Float(cfg.falloff))
        nodes.reserveCapacity(simulation.particleCount)
        for _ in 0..<simulation.particleCount {
            let node = SKSpriteNode(texture: dot)
            node.blendMode = .add
            node.color = tint
            node.colorBlendFactor = 1
            node.isHidden = true
            container.addChild(node)
            nodes.append(node)
        }
    }

    /// Motion is only worth sampling while the orb is on screen; a paused scene with a
    /// live 30 Hz sampler behind it is pure battery burn.
    func setVisible(_ visible: Bool) {
        guard motion.isDeviceMotionAvailable else { return }
        if visible {
            guard !motion.isDeviceMotionActive else { return }
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates()
        } else {
            motion.stopDeviceMotionUpdates()
            simulation.resetTiltBaseline()
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        buildIfNeeded()

        let dt = lastTime == 0 ? 1.0 / 60.0 : min(currentTime - lastTime, 1.0 / 30.0)
        lastTime = currentTime
        elapsed += dt

        let aspect = Float(size.width / size.height)
        let gravity = motion.deviceMotion.map {
            SIMD2<Float>(Float($0.gravity.x), Float($0.gravity.y))
        }

        let frame = particles.withUnsafeMutableBufferPointer { buffer in
            simulation.step(
                dt: Float(dt), time: Float(elapsed), aspect: aspect, level: levelMeter.read(),
                gravity: gravity, touches: [:], into: buffer)
        }

        // The vertex shader maps design space straight to NDC after correcting for
        // aspect, which makes ±1 the *shorter* axis on both platforms.
        let scale = min(size.width, size.height) / 2
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        // Particle sizes are authored in drawable pixels, and SpriteKit works in points.
        let pixel = WKInterfaceDevice.current().screenScale
        let expand = 1 + frame.level * Float(frame.config.sizeExpand)

        for i in 0..<nodes.count {
            let node = nodes[i]
            guard i < frame.drawCount else {
                if !node.isHidden { node.isHidden = true }
                continue
            }
            let p = particles[i]
            node.isHidden = false
            node.position = CGPoint(
                x: centre.x + CGFloat(p.position.x) * scale,
                y: centre.y + CGFloat(p.position.y) * scale)

            var diameter = CGFloat(min(max(p.size * expand, 1), 64)) / pixel
            // Additive blending on the phone lets brightness run past 1; SpriteKit's
            // alpha clamps there. Spend the overflow on size so a shout still reads as
            // brighter rather than flattening out at the top of the range.
            let bright = CGFloat(p.brightness)
            if bright > 1 { diameter *= 1 + (bright - 1) * 0.25 }
            node.size = CGSize(width: diameter, height: diameter)
            node.alpha = min(bright, 1)
        }

        let glowAlpha = CGFloat(frame.glowIntensity)
        glowNode.alpha = min(max(glowAlpha, 0), 1)
        if glowAlpha > 0.001 {
            let extent = CGFloat(frame.glowRadius) * Self.glowExtent * scale * 2
            glowNode.size = CGSize(width: extent, height: extent)
            glowNode.position = CGPoint(
                x: centre.x + CGFloat(frame.tilt.x) * 0.7 * scale,
                y: centre.y + CGFloat(frame.tilt.y) * 0.7 * scale)
        }
    }

    // MARK: - Baked textures

    /// `particle_fragment`: a unit disc shaded `exp(-r² · falloff)`, discarded outside.
    private static func dotTexture(falloff: Float) -> SKTexture {
        texture(side: 64) { u, v in
            let r2 = u * u + v * v
            return r2 > 1 ? 0 : exp(-r2 * falloff)
        }
    }

    /// `glow_fragment`: a core and a wider halo of the same exponential, mixed. Baked at
    /// a normalised radius of 1 and scaled per frame, which is what `params.y` does on
    /// the phone. The shader's dither is dropped — the watch panel does not band the way
    /// a large phone gradient does.
    private static func glowTexture(_ cfg: OrbConfig) -> SKTexture {
        let falloff = Float(cfg.glowFalloff)
        let haloMix = Float(cfg.glowHaloMix)
        let extent = Float(glowExtent)
        return texture(side: 128) { u, v in
            let rn2 = (u * u + v * v) * extent * extent
            let core = exp(-rn2 * falloff)
            let halo = exp(-rn2 * falloff * 0.16)
            return mix(core, halo, haloMix)
        }
    }

    /// Builds a premultiplied-white texture from an alpha function over −1…1. Drawn
    /// straight into a pixel buffer rather than through a renderer: the shading is
    /// per-pixel maths, and there is no drawing command that expresses it.
    private static func texture(side: Int, alpha: (Float, Float) -> Float) -> SKTexture {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let u = (Float(x) + 0.5) / Float(side) * 2 - 1
                let v = (Float(y) + 0.5) / Float(side) * 2 - 1
                let a = UInt8(min(max(alpha(u, v), 0), 1) * 255)
                let i = (y * side + x) * 4
                pixels[i] = a
                pixels[i + 1] = a
                pixels[i + 2] = a
                pixels[i + 3] = a
            }
        }
        let texture: SKTexture? = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let image = context.makeImage()
            else { return nil }
            return SKTexture(cgImage: image)
        }
        return texture ?? SKTexture()
    }
}
