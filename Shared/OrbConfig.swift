#if os(iOS)
import DialKit
#endif
import simd

struct OrbConfig: Codable, Equatable {
    var density = 0.7
    var coreTightness = 2.6
    var cloudScale = 1.5
    var sizeScale = 0.6
    var bigFraction = 0.2
    var falloff = 2.0
    var color = "#FFFFFF"
    var bgDarkness = 0.0
    var idleBrightness = 1.1

    var driftAmount = 4.15
    var driftSpeed = 0.25
    var swirlSpeed = 0.6
    var twinkleAmount = 0.35

    var levelGain = 1.05
    var voiceDensity = 0.5
    var voiceSpeed = 2.45
    var breathGain = 0.64
    var jitterGain = 0.0
    var brightnessGain = 0.2
    var sizeExpand = 0.5
    var attack = 0.1
    var decay = 0.47

    var glowQuietIntensity = 0.08
    var glowLoudIntensity = 0.36
    var glowQuietRadius = 0.5
    var glowLoudRadius = 1.35
    var glowCurve = 0.7
    var glowFalloff = 2.5
    var glowHaloMix = 0.45
    var glowColor = "#FFFFFF"
    var glowFade = 0.45

    var tiltGain = 0.3
    var tiltSpeed = 11.0
    var tiltDamping = 1.2
    var touchRadius = 0.77
    var touchStrength = 0.23
    var touchSpeedIn = 6.0
    var touchSpeedOut = 3.0
    var touchDamping = 0.55

    #if os(watchOS)
    /// The wrist. Along with `OrbSimulation.defaultParticleCount`, this is the whole
    /// tuning surface for the watch orb.
    ///
    /// Particle sizes are authored in drawable pixels, and the watch's screen is about
    /// a third of the phone's across while running a tenth of the particles — so a
    /// literal port lands somewhere between invisible and blobby depending on which of
    /// those two you correct for. Shrinking `sizeScale` and thinning the large-particle
    /// family pulls it back toward dust rather than confetti.
    static let watch = OrbConfig(
        coreTightness: 2.2, cloudScale: 1.2, sizeScale: 0.34, bigFraction: 0.1)
    #endif

    /// The orb before the speech model exists: sparser, slightly looser, dimmer. Every
    /// other field matches the shipped defaults, so `blend` only has three values to
    /// actually move — which keeps it clear of the fields that misbehave when animated
    /// (`swirlSpeed`/`driftSpeed` are phase multipliers against a monotonic clock, and
    /// `bigFraction` is a threshold that pops particles between size families).
    static let quiet = OrbConfig(density: 0.3, coreTightness: 2.5, idleBrightness: 0.6)

    /// Linear interpolation across every numeric field. Written out in full rather than
    /// touching only the three that currently differ, so retuning `quiet` later needs no
    /// changes here. Colours are taken from `b` — they are hex strings, and `rgb` has no
    /// setter, so there is nothing sensible to interpolate.
    static func blend(_ a: OrbConfig, _ b: OrbConfig, _ t: Double) -> OrbConfig {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var out = b
        out.density = l(a.density, b.density)
        out.coreTightness = l(a.coreTightness, b.coreTightness)
        out.cloudScale = l(a.cloudScale, b.cloudScale)
        out.sizeScale = l(a.sizeScale, b.sizeScale)
        out.bigFraction = l(a.bigFraction, b.bigFraction)
        out.falloff = l(a.falloff, b.falloff)
        out.bgDarkness = l(a.bgDarkness, b.bgDarkness)
        out.idleBrightness = l(a.idleBrightness, b.idleBrightness)
        out.driftAmount = l(a.driftAmount, b.driftAmount)
        out.driftSpeed = l(a.driftSpeed, b.driftSpeed)
        out.swirlSpeed = l(a.swirlSpeed, b.swirlSpeed)
        out.twinkleAmount = l(a.twinkleAmount, b.twinkleAmount)
        out.levelGain = l(a.levelGain, b.levelGain)
        out.voiceDensity = l(a.voiceDensity, b.voiceDensity)
        out.voiceSpeed = l(a.voiceSpeed, b.voiceSpeed)
        out.breathGain = l(a.breathGain, b.breathGain)
        out.jitterGain = l(a.jitterGain, b.jitterGain)
        out.brightnessGain = l(a.brightnessGain, b.brightnessGain)
        out.sizeExpand = l(a.sizeExpand, b.sizeExpand)
        out.attack = l(a.attack, b.attack)
        out.decay = l(a.decay, b.decay)
        out.glowQuietIntensity = l(a.glowQuietIntensity, b.glowQuietIntensity)
        out.glowLoudIntensity = l(a.glowLoudIntensity, b.glowLoudIntensity)
        out.glowQuietRadius = l(a.glowQuietRadius, b.glowQuietRadius)
        out.glowLoudRadius = l(a.glowLoudRadius, b.glowLoudRadius)
        out.glowCurve = l(a.glowCurve, b.glowCurve)
        out.glowFalloff = l(a.glowFalloff, b.glowFalloff)
        out.glowHaloMix = l(a.glowHaloMix, b.glowHaloMix)
        out.glowFade = l(a.glowFade, b.glowFade)
        out.tiltGain = l(a.tiltGain, b.tiltGain)
        out.tiltSpeed = l(a.tiltSpeed, b.tiltSpeed)
        out.tiltDamping = l(a.tiltDamping, b.tiltDamping)
        out.touchRadius = l(a.touchRadius, b.touchRadius)
        out.touchStrength = l(a.touchStrength, b.touchStrength)
        out.touchSpeedIn = l(a.touchSpeedIn, b.touchSpeedIn)
        out.touchSpeedOut = l(a.touchSpeedOut, b.touchSpeedOut)
        out.touchDamping = l(a.touchDamping, b.touchDamping)
        return out
    }

    var rgb: SIMD3<Float> {
        Self.parseHex(color)
    }

    var glowRgb: SIMD3<Float> {
        Self.parseHex(glowColor)
    }

    static func parseHex(_ hex: String) -> SIMD3<Float> {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        guard let value = UInt32(s.prefix(6), radix: 16), s.count >= 6 else {
            return SIMD3(0.85, 0.88, 0.95)
        }
        let r = Float((value >> 16) & 0xFF) / 255
        let g = Float((value >> 8) & 0xFF) / 255
        let b = Float(value & 0xFF) / 255
        return SIMD3(r, g, b)
    }

    #if os(iOS)
    static let dialControls: [DialControl<OrbConfig>] = [
        .group("appearance", children: [
            .slider("density", keyPath: \.density, range: 0.1...1.0, step: 0.05),
            .slider("coreTightness", keyPath: \.coreTightness, range: 0.5...3.0, step: 0.1),
            .slider("cloudScale", keyPath: \.cloudScale, range: 0.2...2.0, step: 0.01),
            .slider("sizeScale", keyPath: \.sizeScale, range: 0.3...2.5, step: 0.05),
            .slider("bigFraction", keyPath: \.bigFraction, range: 0.0...0.5, step: 0.01),
            .slider("falloff", keyPath: \.falloff, range: 1.0...8.0, step: 0.1),
            .color("color", keyPath: \.color),
            .slider("bgDarkness", keyPath: \.bgDarkness, range: 0.0...0.2, step: 0.01),
            .slider("idleBrightness", keyPath: \.idleBrightness, range: 0.0...2.0, step: 0.05),
        ]),
        .group("glow", children: [
            .slider("glowQuietIntensity", keyPath: \.glowQuietIntensity, range: 0.0...0.8, step: 0.01),
            .slider("glowLoudIntensity", keyPath: \.glowLoudIntensity, range: 0.0...0.8, step: 0.01),
            .slider("glowQuietRadius", keyPath: \.glowQuietRadius, range: 0.1...2.5, step: 0.05),
            .slider("glowLoudRadius", keyPath: \.glowLoudRadius, range: 0.1...2.5, step: 0.05),
            .slider("glowCurve", keyPath: \.glowCurve, range: 0.3...3.0, step: 0.05),
            .slider("glowFalloff", keyPath: \.glowFalloff, range: 0.5...8.0, step: 0.1),
            .slider("glowHaloMix", keyPath: \.glowHaloMix, range: 0.0...1.0, step: 0.05),
            .slider("glowFade", keyPath: \.glowFade, range: 0.05...1.5, step: 0.05, unit: "s"),
            .color("glowColor", keyPath: \.glowColor),
        ]),
        .group("idleMotion", children: [
            .slider("driftAmount", keyPath: \.driftAmount, range: 0.0...6.0, step: 0.05),
            .slider("driftSpeed", keyPath: \.driftSpeed, range: 0.0...2.5, step: 0.05),
            .slider("swirlSpeed", keyPath: \.swirlSpeed, range: 0.0...3.0, step: 0.05),
            .slider("twinkleAmount", keyPath: \.twinkleAmount, range: 0.0...1.0, step: 0.05),
        ]),
        .group("voiceReactivity", children: [
            .slider("levelGain", keyPath: \.levelGain, range: 0.3...3.0, step: 0.05),
            .slider("voiceDensity", keyPath: \.voiceDensity, range: 0.0...1.0, step: 0.02),
            .slider("voiceSpeed", keyPath: \.voiceSpeed, range: 0.0...4.0, step: 0.05),
            .slider("breathGain", keyPath: \.breathGain, range: 0.0...1.0, step: 0.01),
            .slider("jitterGain", keyPath: \.jitterGain, range: 0.0...0.3, step: 0.005),
            .slider("brightnessGain", keyPath: \.brightnessGain, range: 0.0...2.5, step: 0.05),
            .slider("sizeExpand", keyPath: \.sizeExpand, range: 0.0...5.0, step: 0.1),
        ]),
        .group("response", children: [
            .slider("attack", keyPath: \.attack, range: 0.01...0.3, step: 0.005, unit: "s"),
            .slider("decay", keyPath: \.decay, range: 0.05...1.0, step: 0.01, unit: "s"),
        ]),
        .group("sensors", children: [
            .slider("tiltGain", keyPath: \.tiltGain, range: 0.0...0.3, step: 0.005),
            .slider("tiltSpeed", keyPath: \.tiltSpeed, range: 0.5...15.0, step: 0.5),
            .slider("tiltDamping", keyPath: \.tiltDamping, range: 0.2...1.5, step: 0.05),
            .slider("touchRadius", keyPath: \.touchRadius, range: 0.05...1.0, step: 0.01),
            .slider("touchStrength", keyPath: \.touchStrength, range: 0.0...0.5, step: 0.01),
            .slider("touchSpeedIn", keyPath: \.touchSpeedIn, range: 1.0...20.0, step: 0.5),
            .slider("touchSpeedOut", keyPath: \.touchSpeedOut, range: 1.0...20.0, step: 0.5),
            .slider("touchDamping", keyPath: \.touchDamping, range: 0.2...1.5, step: 0.05),
        ]),
    ]
    #endif
}
