import Foundation
import simd

/// One particle's rendered state, in design space.
///
/// Layout is load-bearing: `SIMD2<Float>` is 8-byte aligned, so this is a 16-byte
/// stride that matches `GPUParticle` in `Particles.metal` field for field. The iOS
/// renderer writes these straight into its `MTLBuffer`; the watch renderer reads the
/// same values into `SKSpriteNode` properties.
struct OrbParticle {
    var position: SIMD2<Float>
    var size: Float
    var brightness: Float
}

/// Everything a renderer needs from a step that isn't per-particle.
struct OrbFrame {
    /// Smoothed voice level, 0…1.5. Feeds the vertex shader's size expansion on iOS.
    var level: Float
    /// Particles `0..<drawCount` hold live values; the rest of the buffer is stale.
    var drawCount: Int
    var glowIntensity: Float
    var glowRadius: Float
    /// Design-space offset of the whole cloud from device tilt. The glow follows it at
    /// 0.7× so the light source lags the particles slightly.
    var tilt: SIMD2<Float>
    /// `config` blended toward `.quiet` by the current presence — what the renderer
    /// should actually draw with, not the config that was set.
    var config: OrbConfig
}

/// The voice orb's motion, with no rendering in it.
///
/// Extracted from the Metal view so the watch can drive the same field through
/// SpriteKit: watchOS has no Metal, and a second hand-ported copy of the drift,
/// twinkle and spring math would drift out of sync with this one within a release.
/// Everything here is plain CPU arithmetic over a fixed particle array.
final class OrbSimulation {
    #if os(watchOS)
    /// The wrist runs an order of magnitude fewer particles: SpriteKit moves real
    /// nodes on the CPU each frame rather than filling one GPU buffer, and this is
    /// the knob that decides how much battery the orb costs. Tune here.
    static let defaultParticleCount = 300
    #else
    static let defaultParticleCount = 3000
    #endif

    /// Slow enough to read as the orb gathering itself, short enough that a cached
    /// launch has settled before the user reaches for the record button.
    private static let presenceTau: Float = 0.6

    let particleCount: Int
    /// Particles fade in across this many indices at the active edge, so a rising voice
    /// level thickens the cloud instead of popping new points into it.
    ///
    /// Proportional rather than the flat 250 this started as: at the watch's particle
    /// count a fixed band is wider than the whole active range, which drags `edgeFade`
    /// below 1 for *every* particle and leaves the orb uniformly dim. The divisor is
    /// chosen to reproduce exactly 250 at the iOS count.
    private let fadeBand: Float
    var config = OrbConfig()
    var isActive = false
    /// 0 = `OrbConfig.quiet`, 1 = `config`. Ramped as the speech model loads (iOS) or
    /// as the phone connection comes and goes (watch), so the wait reads as the orb
    /// assembling itself.
    var targetPresence: Float = 1

    private var particles: [Particle] = []
    private var smoothedLevel: Float = 0
    private var glowPresence: Float = 0
    /// Seeded from the first target rather than starting at 0, so a launch that is
    /// already ready settles from its floor instead of building from empty.
    private var smoothedPresence: Float?
    /// Advanced by `dt` scaled by voice speed, so idle drift never rewinds when the
    /// user stops talking.
    private var motionClock: Double = 0

    private var gravitySpring = Spring2D()
    private var baselineX: Float = 0
    private var baselineY: Float = 0
    private var baselineSet = false
    private var touchSprings: [AnyHashable: TouchSpring] = [:]

    init(particleCount: Int = OrbSimulation.defaultParticleCount) {
        self.particleCount = particleCount
        self.fadeBand = max(1, Float(particleCount) / 12)
        seedParticles()
    }

    /// Forgets the tilt baseline. Call when the orb stops being sampled, so the next
    /// hold position becomes "level" rather than inheriting a stale one.
    func resetTiltBaseline() {
        baselineSet = false
    }

    private func seedParticles() {
        var rng = SplitMix64(state: 0xCAFE_BABE_DEAD_BEEF)
        particles.removeAll(keepingCapacity: true)
        particles.reserveCapacity(particleCount)
        for _ in 0..<particleCount {
            particles.append(
                Particle(
                    homeAngle: rng.range(0, 2 * .pi),
                    radiusRand: rng.float01(),
                    bigPick: rng.float01(),
                    sizeRand: rng.float01(),
                    brightPick: rng.float01(),
                    brightRand: rng.float01(),
                    driftSpeedX: rng.range(0.08, 0.7),
                    driftSpeedY: rng.range(0.08, 0.7),
                    driftPhaseX: rng.range(0, 2 * .pi),
                    driftPhaseY: rng.range(0, 2 * .pi),
                    driftAmpX: rng.range(0.05, 0.16),
                    driftAmpY: rng.range(0.05, 0.16),
                    angSpeed: rng.range(-0.28, 0.28),
                    twinklePhase: rng.range(0, 2 * .pi),
                    twinkleSpeed: rng.range(0.3, 1.2),
                    jitterSeedA: rng.range(0, 2 * .pi),
                    jitterSeedB: rng.range(0, 2 * .pi)
                ))
        }
    }

    /// Advances one frame and fills `out` with the first `OrbFrame.drawCount` particles.
    ///
    /// - Parameters:
    ///   - dt: Seconds since the last step, already clamped by the caller.
    ///   - time: Seconds since the renderer started. Drives twinkle, which is
    ///     deliberately on wall time rather than the voice-accelerated clock.
    ///   - aspect: Drawable width / height.
    ///   - level: Raw voice level, 0…1, straight off `AudioLevelMeter`.
    ///   - gravity: Raw device gravity, or nil where motion is unavailable. Baseline
    ///     adaptation lives in here so both platforms get the same "any hold position
    ///     becomes level" behaviour.
    ///   - touches: Normalised −1…1 points, keyed by touch identity. Empty is fine.
    func step(
        dt: Float,
        time: Float,
        aspect: Float,
        level rawLevel: Float,
        gravity: SIMD2<Float>?,
        touches: [AnyHashable: SIMD2<Float>],
        into out: UnsafeMutableBufferPointer<OrbParticle>
    ) -> OrbFrame {
        // Eased here rather than in SwiftUI: the download's progress callbacks arrive
        // in chunky network-sized steps, so the raw fraction alone would visibly
        // staircase. Seeding from the first target avoids a ramp-in.
        let presence = smoothedPresence.map {
            $0 + (targetPresence - $0) * (1 - exp(-dt / Self.presenceTau))
        } ?? targetPresence
        smoothedPresence = presence
        let cfg = OrbConfig.blend(.quiet, config, Double(presence))

        let rawTarget = isActive ? min(rawLevel * Float(cfg.levelGain), 1.5) : 0
        let tau = rawTarget > smoothedLevel ? Float(cfg.attack) : Float(cfg.decay)
        smoothedLevel += (rawTarget - smoothedLevel) * (1 - exp(-dt / max(tau, 0.001)))
        let level = smoothedLevel

        let glowTarget: Float = isActive ? 1 : 0
        glowPresence += (glowTarget - glowPresence)
            * (1 - exp(-dt / max(Float(cfg.glowFade), 0.001)))
        if glowTarget == 0 && glowPresence < 0.002 { glowPresence = 0 }

        let tightness = Float(cfg.coreTightness)
        let cloudScale = Float(cfg.cloudScale)
        let sizeScale = Float(cfg.sizeScale)
        let bigFraction = Float(cfg.bigFraction)
        let driftAmount = Float(cfg.driftAmount)
        let driftSpeed = Float(cfg.driftSpeed)
        let swirlSpeed = Float(cfg.swirlSpeed)
        let twinkleAmount = Float(cfg.twinkleAmount)
        let breathGain = Float(cfg.breathGain)
        let jitterGain = Float(cfg.jitterGain)
        let brightnessGain = Float(cfg.brightnessGain)
        let idleBrightness = Float(cfg.idleBrightness)
        let voiceSpeed = Float(cfg.voiceSpeed)
        let voiceDensity = Float(cfg.voiceDensity)

        let speedFactor = 1 + level * voiceSpeed
        motionClock += Double(dt * speedFactor)
        let clk = Float(motionClock)

        if let g = gravity {
            if baselineSet {
                let adapt = 1 - exp(-dt / 2.0)
                baselineX += (g.x - baselineX) * adapt
                baselineY += (g.y - baselineY) * adapt
            } else {
                baselineX = g.x
                baselineY = g.y
                baselineSet = true
            }
            gravitySpring.step(
                to: SIMD2(g.x - baselineX, g.y - baselineY),
                omega: Float(cfg.tiltSpeed), zeta: Float(cfg.tiltDamping), dt: dt)
        }
        let tiltX = gravitySpring.value.x * Float(cfg.tiltGain)
        let tiltY = gravitySpring.value.y * Float(cfg.tiltGain)

        let touchZeta = Float(cfg.touchDamping)
        let inOmega = Float(cfg.touchSpeedIn)
        let outOmega = Float(cfg.touchSpeedOut)
        // Both aspect corrections have to agree with the vertex shader's, or a touch
        // pushes particles away from somewhere other than the finger.
        func toDesign(_ p: SIMD2<Float>) -> SIMD2<Float> {
            aspect < 1 ? SIMD2(p.x, p.y / aspect) : SIMD2(p.x * aspect, p.y)
        }
        for (id, target) in touches {
            var spring = touchSprings[id] ?? TouchSpring(pos: toDesign(target))
            spring.pos.step(to: toDesign(target), omega: inOmega, zeta: touchZeta, dt: dt)
            spring.level.step(to: 1, omega: inOmega, zeta: touchZeta, dt: dt)
            touchSprings[id] = spring
        }
        for id in Array(touchSprings.keys) where touches[id] == nil {
            var spring = touchSprings[id]!
            spring.level.step(to: 0, omega: outOmega, zeta: touchZeta, dt: dt)
            if spring.level.value < 0.01 && abs(spring.level.velocity) < 0.05 {
                touchSprings.removeValue(forKey: id)
            } else {
                touchSprings[id] = spring
            }
        }
        let activeTouches = touchSprings.values.compactMap { spring -> (SIMD2<Float>, Float)? in
            let lvl = max(0, spring.level.value)
            return lvl > 0.001 ? (spring.pos.value, lvl) : nil
        }
        let touchRadius = Float(cfg.touchRadius)
        let touchStrength = Float(cfg.touchStrength)

        let activeFraction = min(1, Float(cfg.density) + level * voiceDensity)
        let activeCount = activeFraction * Float(particleCount)
        let drawCount = max(1, min(min(particleCount, out.count), Int(activeCount + fadeBand)))

        for i in 0..<drawCount {
            let p = particles[i]
            let r01 = pow(p.radiusRand, tightness)
            let anchorR = r01 * cloudScale
            let ang = p.homeAngle + clk * p.angSpeed * swirlSpeed
            let ax = cos(ang) * anchorR
            let ay = sin(ang) * anchorR
            let dx = sin(clk * p.driftSpeedX * driftSpeed + p.driftPhaseX) * p.driftAmpX * driftAmount
            let dy = cos(clk * p.driftSpeedY * driftSpeed + p.driftPhaseY) * p.driftAmpY * driftAmount
            let breath = level * breathGain * r01
            let jx = sin(clk * 22 + p.jitterSeedA) * level * jitterGain
            let jy = cos(clk * 25 + p.jitterSeedB) * level * jitterGain
            var x = ax + dx + cos(ang) * breath + jx
            var y = ay + dy + sin(ang) * breath + jy

            x += tiltX * (0.7 + 0.3 * r01)
            y += tiltY * (0.7 + 0.3 * r01)

            for (tp, lvl) in activeTouches {
                let ddx = x - tp.x
                let ddy = y - tp.y
                let dist2 = ddx * ddx + ddy * ddy
                let g = exp(-dist2 / max(touchRadius * touchRadius, 1e-4))
                let inv = 1 / max(dist2.squareRoot(), 1e-3)
                x += ddx * inv * g * touchStrength * lvl
                y += ddy * inv * g * touchStrength * lvl
            }

            let big = p.bigPick < bigFraction
            let baseSize = (big ? mix(16, 30, p.sizeRand) : mix(3, 9, p.sizeRand)) * sizeScale
            let baseBright: Float
            if big {
                baseBright = mix(0.10, 0.22, p.brightRand)
            } else if p.brightPick < 0.08 {
                baseBright = mix(0.8, 1.0, p.brightRand)
            } else {
                baseBright = mix(0.30, 0.75, p.brightRand)
            }
            let twinkle = (1 - twinkleAmount)
                + twinkleAmount * (0.5 + 0.5 * sin(time * p.twinkleSpeed + p.twinklePhase))
            let edgeFade = min(1, max(0, (activeCount - Float(i)) / fadeBand))
            let bright = min(baseBright * twinkle * idleBrightness + level * brightnessGain, 1.8) * edgeFade
            out[i] = OrbParticle(position: SIMD2(x, y), size: baseSize, brightness: bright)
        }

        let glowT = pow(min(max(level, 0), 1), Float(cfg.glowCurve))
        return OrbFrame(
            level: level,
            drawCount: drawCount,
            glowIntensity: mix(
                Float(cfg.glowQuietIntensity), Float(cfg.glowLoudIntensity), glowT) * glowPresence,
            glowRadius: mix(Float(cfg.glowQuietRadius), Float(cfg.glowLoudRadius), glowT),
            tilt: SIMD2(tiltX, tiltY),
            config: cfg)
    }
}

// MARK: - Per-particle constants

/// The immutable seed of one particle. Everything time-varying is derived from these
/// plus the clock, so the whole field is a pure function of `(seed, time, level)` and
/// needs no per-frame state.
private struct Particle {
    var homeAngle: Float
    var radiusRand: Float
    var bigPick: Float
    var sizeRand: Float
    var brightPick: Float
    var brightRand: Float
    var driftSpeedX: Float
    var driftSpeedY: Float
    var driftPhaseX: Float
    var driftPhaseY: Float
    var driftAmpX: Float
    var driftAmpY: Float
    var angSpeed: Float
    var twinklePhase: Float
    var twinkleSpeed: Float
    var jitterSeedA: Float
    var jitterSeedB: Float
}

// MARK: - Springs and noise

struct Spring1D {
    var value: Float = 0
    var velocity: Float = 0

    mutating func step(to target: Float, omega: Float, zeta: Float, dt: Float) {
        let h = min(dt, 1.0 / 60.0)
        let accel = omega * omega * (target - value) - 2 * zeta * omega * velocity
        velocity += accel * h
        value += velocity * h
    }
}

struct Spring2D {
    var value = SIMD2<Float>(0, 0)
    var velocity = SIMD2<Float>(0, 0)

    mutating func step(to target: SIMD2<Float>, omega: Float, zeta: Float, dt: Float) {
        let h = min(dt, 1.0 / 60.0)
        let accel = omega * omega * (target - value) - 2 * zeta * omega * velocity
        velocity += accel * h
        value += velocity * h
    }
}

struct TouchSpring {
    var pos = Spring2D()
    var level = Spring1D()

    init(pos value: SIMD2<Float>) {
        self.pos.value = value
    }
}

func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

/// Fixed-seed PRNG, so the cloud is laid out identically on every launch and on both
/// platforms rather than reshuffling itself.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func float01() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func range(_ a: Float, _ b: Float) -> Float {
        a + (b - a) * float01()
    }
}
