// Spinaural for Mac: spins everything your Mac plays around your head, live.
//
// How the sound gets here: a Core Audio process tap (macOS 14.2+) grabs the system mix and
// mutes the original while we hold it. The tap and the current output device are joined in a
// private aggregate device, so one real-time callback reads the system mix, runs it through the
// spatializer below, and writes it straight to the speakers or headphones.
//
// The spatializer mirrors the web app (spinaural.rennko.tech): same paths, presets, 8D/16D modes,
// bass crossover, bass boost and room echo. HRTF is approximated with a spherical-head model:
// interaural time delay (Woodworth) plus a per-ear head-shadow shelf (Brown & Duda 1998),
// and a darker tone when the sound passes behind you.

import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

let TAU = Double.pi * 2

// MARK: - Settings and presets

enum Pattern: Int, Codable, CaseIterable {
    case orbit, spiral, swing, wander
    var label: String { ["Orbit", "Spiral", "Ear to ear", "Wander"][rawValue] }
    var hint: String {
        ["Goes round and round your head in a steady circle.",
         "Circles while it drifts in close, then back out.",
         "Sweeps from one ear to the other across your face.",
         "Drifts around you and never takes the same path twice."][rawValue]
    }
}

enum Room: Int, Codable, CaseIterable {
    case studio, hall, cathedral
    var label: String { ["Studio", "Hall", "Cathedral"][rawValue] }
    var feedback: Float { [0.72, 0.84, 0.92][rawValue] }
    var damp: Float { [0.38, 0.26, 0.18][rawValue] }
}

struct Settings: Codable, Equatable {
    var pattern: Pattern = .orbit
    var dir: Double = 1
    var lap: Double = 8
    var dist: Double = 1.6
    var height: Double = 25
    var room: Room = .hall
    var echo: Double = 30
    var bass = true
    var layers = 8
    var boost: Double = 0   // dB, not part of presets

    func matches(_ p: Settings) -> Bool {
        pattern == p.pattern && dir == p.dir && abs(lap - p.lap) < 0.01 && abs(dist - p.dist) < 0.01 &&
        abs(height - p.height) < 0.5 && room == p.room && abs(echo - p.echo) < 0.5 && bass == p.bass && layers == p.layers
    }
}

struct Preset { let no: String, name: String, desc: String, s: Settings }

func mk(_ p: Pattern, _ dir: Double, _ lap: Double, _ dist: Double, _ h: Double, _ r: Room, _ e: Double, _ bass: Bool, _ layers: Int) -> Settings {
    Settings(pattern: p, dir: dir, lap: lap, dist: dist, height: h, room: r, echo: e, bass: bass, layers: layers)
}

let PRESETS: [Preset] = [
    Preset(no: "A1", name: "Classic 8D", desc: "The one you know. Steady circle, hall echo.", s: mk(.orbit, 1, 8, 1.6, 25, .hall, 30, true, 8)),
    Preset(no: "A2", name: "Slow Dream", desc: "A long, far-off lap in a big stone room.", s: mk(.orbit, 1, 18, 2.8, 45, .cathedral, 48, true, 8)),
    Preset(no: "A3", name: "Fast Spin", desc: "Tight and quick, a lap every three seconds.", s: mk(.orbit, 1, 3, 1.2, 10, .studio, 14, true, 8)),
    Preset(no: "A4", name: "Whisper", desc: "Right up against your ears, side to side.", s: mk(.swing, 1, 6, 1.0, 0, .studio, 6, false, 8)),
    Preset(no: "B1", name: "Concert Hall", desc: "Wanders around the room like a live band.", s: mk(.wander, 1, 12, 3.2, 20, .hall, 55, true, 8)),
    Preset(no: "B2", name: "Head Rush", desc: "Spirals in and out while it climbs and dips.", s: mk(.spiral, -1, 5, 2.4, 80, .hall, 28, true, 8)),
    Preset(no: "B3", name: "Late Night", desc: "Lazy drift, small warm room. Good for lo-fi.", s: mk(.wander, -1, 20, 1.8, 15, .studio, 35, true, 8)),
    Preset(no: "B4", name: "Pendulum", desc: "Swings slowly ear to ear through a big hall.", s: mk(.swing, 1, 10, 2, 0, .cathedral, 32, true, 8)),
    Preset(no: "C1", name: "16D Classic", desc: "Mids and highs circle you in opposite directions.", s: mk(.orbit, 1, 9, 1.8, 30, .hall, 32, true, 16)),
    Preset(no: "C2", name: "Crossfire", desc: "Two fast, tight orbits crossing behind your head.", s: mk(.orbit, -1, 4, 1.3, 15, .studio, 16, true, 16)),
    Preset(no: "C3", name: "Swarm", desc: "Every layer wanders off on its own in a big hall.", s: mk(.wander, 1, 11, 2.6, 55, .cathedral, 42, true, 16)),
    Preset(no: "C4", name: "Tug of War", desc: "Layers swing ear to ear, pulling against each other.", s: mk(.swing, 1, 7, 1.5, 0, .hall, 22, true, 16)),
    Preset(no: "D1", name: "Front Row", desc: "Right by the stage, the crowd and room around you.", s: mk(.orbit, 1, 8, 1.6, 25, .hall, 34, true, 360)),
    Preset(no: "D2", name: "Arena", desc: "Far from the stage in a huge echoing space.", s: mk(.orbit, 1, 8, 3.4, 25, .cathedral, 52, true, 360)),
    Preset(no: "D3", name: "Living Room", desc: "Like the band is playing in your house.", s: mk(.orbit, 1, 8, 1.2, 25, .studio, 22, true, 360)),
    Preset(no: "D4", name: "Club", desc: "Close, warm and loud, with sound bouncing off the walls.", s: mk(.orbit, 1, 8, 2, 25, .hall, 40, false, 360)),
]

let MODE_HINTS: [Int: String] = [
    8: "The whole song moves as one voice around your head.",
    16: "The song splits in layers. Bass stays put, mids go one way, highs go the other, faster.",
    360: "Puts you in the room. The band plays in front, the room echoes all around you, and nothing spins.",
]

// 360 mode: virtual speakers around you (same layout as the web app)
struct Speaker { let az: Double, el: Double, src: Int, ms: Double, gain: Float, rm: Double }  // src 0 = L, 1 = R, 2 = mid
let SPEAKERS: [Speaker] = [
    Speaker(az: -30, el: 0, src: 0, ms: 0, gain: 0.9, rm: 1), Speaker(az: 30, el: 0, src: 1, ms: 0, gain: 0.9, rm: 1),
    Speaker(az: 0, el: 0, src: 2, ms: 0, gain: 0.55, rm: 1),
    Speaker(az: -100, el: 0, src: 0, ms: 13, gain: 0.55, rm: 1.15), Speaker(az: 100, el: 0, src: 1, ms: 17, gain: 0.55, rm: 1.15),
    Speaker(az: -145, el: 0, src: 0, ms: 23, gain: 0.45, rm: 1.25), Speaker(az: 145, el: 0, src: 1, ms: 29, gain: 0.45, rm: 1.25),
    Speaker(az: -55, el: 40, src: 2, ms: 9, gain: 0.22, rm: 1.3), Speaker(az: 55, el: 40, src: 2, ms: 11, gain: 0.22, rm: 1.3),
]

// MARK: - The path (same maths as the web app)

struct Pos { var x: Double, y: Double, z: Double, behind: Double }

// Listener at the origin facing -z. Angle 0 is in front, +90° is the right ear.
func pos(_ t: Double, _ s: Settings) -> Pos {
    let P = t / s.lap
    var a: Double, r = s.dist
    switch s.pattern {
    case .spiral: a = TAU * P; r = max(0.75, s.dist * (0.5 + 0.5 * (0.5 + 0.5 * cos(TAU * P / 4))))
    case .swing: a = (Double.pi / 2) * sin(TAU * P)
    case .wander:
        a = TAU * (0.6 * P + 0.25 * sin(TAU * P * 0.31 + 1.3) + 0.15 * sin(TAU * P * 0.77 + 0.4))
        r = s.dist * (0.85 + 0.15 * sin(TAU * P * 0.43))
    case .orbit: a = TAU * P
    }
    a *= s.dir
    let y = s.height / 100 * 1.4 * sin(TAU * P * 0.5 + 0.9)
    let x = r * sin(a), z = -r * cos(a)
    return Pos(x: x, y: y, z: z, behind: max(0, z / max(0.001, hypot(x, z))))
}

// 16D second voice: the highs go the other way, faster and a bit farther out
func posB(_ t: Double, _ s: Settings) -> Pos {
    var s2 = s; s2.lap = s.lap * 0.62; s2.dir = -s.dir; s2.dist = min(4, s.dist * 1.15)
    return pos(t + s.lap * 0.3, s2)
}

func spkPos(_ i: Int, _ t: Double, _ s: Settings) -> Pos {
    let sp = SPEAKERS[i]
    let a = (sp.az + 5 * sin(TAU * t * (0.07 + Double(i) * 0.013) + Double(i) * 1.7)) * Double.pi / 180
    let e = sp.el * Double.pi / 180, r = s.dist * sp.rm, h = r * cos(e)
    let x = h * sin(a), z = -h * cos(a)
    return Pos(x: x, y: r * sin(e), z: z, behind: max(0, z / max(0.001, hypot(x, z))))
}

// MARK: - DSP building blocks

struct BQ {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0, z1: Float = 0, z2: Float = 0
    init() {}
    init(highpass: Bool, _ f: Double, _ sr: Double, q: Double = 0.5.squareRoot()) {
        let w = TAU * f / sr, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        if highpass { b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0) }
        else { b0 = Float((1 - c) / 2 / a0); b1 = Float((1 - c) / a0) }
        b2 = b0; a1 = Float(-2 * c / a0); a2 = Float((1 - al) / a0)
    }
    mutating func lowShelf(_ f: Double, _ db: Double, _ sr: Double) {
        let A = pow(10, db / 40), w = TAU * f / sr, c = cos(w), al = sin(w) / 2 * 2.0.squareRoot(), sq = 2 * A.squareRoot() * al
        let a0 = (A + 1) + (A - 1) * c + sq
        b0 = Float(A * ((A + 1) - (A - 1) * c + sq) / a0)
        b1 = Float(2 * A * ((A - 1) - (A + 1) * c) / a0)
        b2 = Float(A * ((A + 1) - (A - 1) * c - sq) / a0)
        a1 = Float(-2 * ((A - 1) + (A + 1) * c) / a0)
        a2 = Float(((A + 1) + (A - 1) * c - sq) / a0)
    }
    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y
    }
}

// Brown & Duda head-shadow: H(s) = (2w0 + a*s) / (2w0 + s), w0 = c/a_head
struct Shelf {
    var p: Float = 0, k: Float = 0, a1: Float = 0, x1: Float = 0, y1: Float = 0
    var alpha: Float = 1, alphaT: Float = 1, ready = false
    mutating func set(alpha a: Double, sr: Double) {
        let w0 = 343.0 / 0.0875, K = 2 * sr, d = 2 * w0 + K
        p = Float(2 * w0 / d); k = Float(K / d); a1 = Float((2 * w0 - K) / d)
        alphaT = Float(a); if !ready { ready = true; alpha = alphaT }
    }
    // b0 = p + alpha*k, b1 = p - alpha*k, so alpha can glide sample by sample
    @inline(__always) mutating func run(_ x: Float) -> Float {
        alpha += (alphaT - alpha) * 0.004
        let ak = alpha * k
        let y = (p + ak) * x + (p - ak) * x1 - a1 * y1; x1 = x; y1 = y; return y
    }
}

@inline(__always) func shadowAlpha(_ theta: Double) -> Double {
    1.05 + 0.95 * cos(theta / (150.0 * Double.pi / 180) * Double.pi)   // 2.0 facing the ear, 0.1 at 150°
}

final class Voice {
    let sr: Double
    let N = 512, mask = 511
    let buf: UnsafeMutablePointer<Float>
    var w = 0
    var dL: Float = 0, dR: Float = 0, tL: Float = 0, tR: Float = 0
    var shL = Shelf(), shR = Shelf()
    var lp: Float = 0, lpc: Float = 0, lpcT: Float = 0
    var g: Float = 1, gT: Float = 1
    var eL: Float = 1, eR: Float = 1, eLT: Float = 1, eRT: Float = 1  // extra far-ear dip, the 8D 'swing'
    var primed = false

    init(sr: Double) { self.sr = sr; buf = .allocate(capacity: N); buf.initialize(repeating: 0, count: N) }

    func target(_ p: Pos) {
        let d = max(0.3, (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot())
        let ux = max(-1, min(1, p.x / d))
        let lat = asin(ux)
        let itd = Float(0.0875 / 343 * (abs(lat) + sin(abs(lat))) * sr)
        if lat > 0 { tL = itd; tR = 0 } else { tR = itd; tL = 0 }
        shR.set(alpha: shadowAlpha(acos(ux)), sr: sr)
        shL.set(alpha: shadowAlpha(acos(-ux)), sr: sr)
        let fc = 17000 * pow(0.3, p.behind)
        lpcT = Float(exp(-TAU * fc / sr))
        gT = Float(0.82 / (1 + 0.45 * (d - 1)))
        let far = Float(pow(10, -6 * abs(ux) / 20))
        if ux > 0 { eLT = far; eRT = 1 } else { eRT = far; eLT = 1 }
        if !primed { primed = true; lpc = lpcT; g = gT; dL = tL; dR = tR; eL = eLT; eR = eRT }
    }

    @inline(__always) func read(_ d: Float) -> Float {
        let p = Float(w) - d, i0 = Int(p.rounded(.down)), f = p - Float(i0)
        let a = buf[i0 & mask], b = buf[(i0 + 1) & mask]
        return a + (b - a) * f
    }

    @inline(__always) func run(_ x: Float, _ l: inout Float, _ r: inout Float) {
        lpc += (lpcT - lpc) * 0.002; g += (gT - g) * 0.002
        lp = x * (1 - lpc) + lp * lpc
        buf[w] = lp * g
        dL += (tL - dL) * 0.003; dR += (tR - dR) * 0.003
        eL += (eLT - eL) * 0.003; eR += (eRT - eR) * 0.003
        l = shL.run(read(dL)) * eL; r = shR.run(read(dR)) * eR
        w = (w + 1) & mask
    }
}

final class Line {
    let buf: UnsafeMutablePointer<Float>, n: Int
    var i = 0, store: Float = 0
    init(_ n: Int) { self.n = max(1, n); buf = .allocate(capacity: self.n); buf.initialize(repeating: 0, count: self.n) }
    @inline(__always) func comb(_ x: Float, _ fb: Float, _ damp: Float) -> Float {
        let y = buf[i]; store = y * (1 - damp) + store * damp; buf[i] = x + store * fb
        i += 1; if i >= n { i = 0 }; return y
    }
    @inline(__always) func allpass(_ x: Float) -> Float {
        let b = buf[i], y = -x + b; buf[i] = x + b * 0.5
        i += 1; if i >= n { i = 0 }; return y
    }
}

// Freeverb (Jezar's tunings)
final class Reverb {
    let cL: [Line], cR: [Line], aL: [Line], aR: [Line]
    init(sr: Double) {
        let k = sr / 44100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], aps = [556, 441, 341, 225]
        cL = combs.map { Line(Int(Double($0) * k)) }; cR = combs.map { Line(Int(Double($0 + 23) * k)) }
        aL = aps.map { Line(Int(Double($0) * k)) }; aR = aps.map { Line(Int(Double($0 + 23) * k)) }
    }
    @inline(__always) func run(_ x: Float, _ fb: Float, _ damp: Float, _ l: inout Float, _ r: inout Float) {
        let inp = x * 0.015
        var sl: Float = 0, sr: Float = 0
        for c in cL { sl += c.comb(inp, fb, damp) }
        for c in cR { sr += c.comb(inp, fb, damp) }
        for a in aL { sl = a.allpass(sl) }
        for a in aR { sr = a.allpass(sr) }
        l = sl; r = sr
    }
}

// MARK: - The spatializer

final class DSP {
    let sr: Double
    private var s = Settings()
    private var pending = Settings()
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    var bypass = false

    private var boL = BQ(), boR = BQ(), boostDB = 0.0
    private var lpL1: BQ, lpL2: BQ, lpR1: BQ, lpR2: BQ, hpL1: BQ, hpL2: BQ, hpR1: BQ, hpR2: BQ
    private var m1: BQ, m2: BQ, h1: BQ, h2: BQ
    private let A: Voice, B: Voice
    private let spk: [Voice]
    private let spkDelay: [Int]
    private let dly: UnsafeMutablePointer<Float>   // 3 rings (L, R, mid) of 8192 samples
    private var dw = 0
    private var surG: Float = 0
    private let rev: Reverb
    private var fx: Float = 1, env: Float = 0
    private var dryG: Float = 1, wetG: Float = 0, mixG: Float = 1, bassG: Float = 1, splitG: Float = 0

    // read by the UI
    var t: Double = 0
    var meterL: Float = 0, meterR: Float = 0, inLevel: Float = 0
    // health: late callbacks, short input buffers, worst processing time vs. buffer length
    var calls = 0, late = 0, short = 0, worst: Double = 0, lastHost: UInt64 = 0

    init(sr: Double) {
        self.sr = sr
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
        lpL1 = BQ(highpass: false, 140, sr); lpL2 = lpL1; lpR1 = lpL1; lpR2 = lpL1
        hpL1 = BQ(highpass: true, 140, sr); hpL2 = hpL1; hpR1 = hpL1; hpR2 = hpL1
        m1 = BQ(highpass: false, 2400, sr); m2 = m1
        h1 = BQ(highpass: true, 2400, sr); h2 = h1
        A = Voice(sr: sr); B = Voice(sr: sr); rev = Reverb(sr: sr)
        spk = SPEAKERS.map { _ in Voice(sr: sr) }
        spkDelay = SPEAKERS.map { Int($0.ms / 1000 * sr) }
        dly = .allocate(capacity: 3 * 8192); dly.initialize(repeating: 0, count: 3 * 8192)
        boL.lowShelf(100, 0, sr); boR = boL
    }

    func update(_ n: Settings) { os_unfair_lock_lock(lock); pending = n; os_unfair_lock_unlock(lock) }

    /// Process `frames` samples. Inputs/outputs are strided Float32 pointers.
    func process(_ frames: Int, _ iL: UnsafePointer<Float>, _ iR: UnsafePointer<Float>, _ iStride: Int,
                 _ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>, _ oStride: Int) {
        if os_unfair_lock_trylock(lock) { s = pending; os_unfair_lock_unlock(lock) }
        if s.boost != boostDB {
            boostDB = s.boost
            boL.lowShelf(100, boostDB, sr); boR.b0 = boL.b0; boR.b1 = boL.b1; boR.b2 = boL.b2; boR.a1 = boL.a1; boR.a2 = boL.a2
        }
        let split = s.layers == 16, sur = s.layers == 360
        let surT: Float = sur ? 1 : 0
        let mix = Float(s.echo / 100)
        let wetT = mix * 2.2 * Float(0.75 + 0.25 * (s.dist - 1) / 3)
        let dryT = 1 - 0.3 * mix
        let mixT = Float((1.05 + 0.25 * (s.dist - 1)) * pow(10, -s.boost / 40))
        let bassT: Float = s.bass ? 1 : 0, splitT: Float = split ? 1 : 0
        let fxT: Float = bypass ? 0 : 1
        let fb = s.room.feedback, damp = s.room.damp
        var sumL: Float = 0, sumR: Float = 0, sumIn: Float = 0

        var i = 0
        while i < frames {
            let chunk = min(32, frames - i)
            A.target(pos(t, s))
            if split { B.target(posB(t, s)) }
            if sur || surG > 0.001 { for k in 0..<spk.count { spk[k].target(spkPos(k, t, s)) } }
            for j in i..<(i + chunk) {
                let inL = iL[j * iStride], inR = iR[j * iStride]
                sumIn += inL * inL + inR * inR
                dryG += (dryT - dryG) * 0.001; wetG += (wetT - wetG) * 0.001; mixG += (mixT - mixG) * 0.001
                bassG += (bassT - bassG) * 0.001; splitG += (splitT - splitG) * 0.001; fx += (fxT - fx) * 0.0015
                surG += (surT - surG) * 0.001

                let xL = boL.run(inL), xR = boR.run(inR)
                let bL = lpL2.run(lpL1.run(xL)), bR = lpR2.run(lpR1.run(xR))
                let hL = hpL2.run(hpL1.run(xL)), hR = hpR2.run(hpR1.run(xR))
                // with the bass centred, only the highpassed part spins
                let mono = ((hL + hR) * bassG + (xL + xR) * (1 - bassG)) * 0.5
                let mid = m2.run(m1.run(mono)), hi = h2.run(h1.run(mono)) * 1.1
                var aL: Float = 0, aR: Float = 0, cL: Float = 0, cR: Float = 0
                A.run((mono * (1 - splitG) + mid * splitG) * (1 - surG), &aL, &aR)
                if split || splitG > 0.001 { B.run(hi * splitG, &cL, &cR) }
                var vL = aL + cL, vR = aR + cR
                if sur || surG > 0.001 {
                    // stereo (non-bass) signal into the speaker rings, then each speaker reads its delayed copy
                    let sL = (hL * bassG + xL * (1 - bassG)) * surG, sR = (hR * bassG + xR * (1 - bassG)) * surG
                    dly[dw] = sL; dly[8192 + dw] = sR; dly[16384 + dw] = (sL + sR) * 0.5
                    for k in 0..<spk.count {
                        let sp = SPEAKERS[k]
                        let v = dly[sp.src * 8192 + ((dw - spkDelay[k]) & 8191)] * sp.gain * 0.75
                        var l: Float = 0, r: Float = 0
                        spk[k].run(v, &l, &r); vL += l; vR += r
                    }
                    dw = (dw + 1) & 8191
                }
                var rL: Float = 0, rR: Float = 0
                rev.run((vL + vR) * 0.5, fb, damp, &rL, &rR)
                var l = (bL * bassG + vL * dryG + rL * wetG) * mixG
                var r = (bR * bassG + vR * dryG + rR * wetG) * mixG
                l = l * fx + inL * (1 - fx); r = r * fx + inR * (1 - fx)
                // brickwall-ish limiter
                env = max(abs(l), abs(r), env * 0.9997)
                if env > 0.96 { let k = 0.96 / env; l *= k; r *= k }
                oL[j * oStride] = l; oR[j * oStride] = r
                sumL += l * l; sumR += r * r
            }
            t += Double(chunk) / sr
            i += chunk
        }
        let n = Float(max(1, frames))
        meterL = (sumL / n).squareRoot(); meterR = (sumR / n).squareRoot()
        inLevel = inLevel * 0.97 + (sumIn / (2 * n)).squareRoot() * 0.03
    }
}

// MARK: - Live system audio (process tap + aggregate device)

struct SpinError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

func check(_ st: OSStatus, _ what: String) throws {
    if st != noErr { throw SpinError(msg: "\(what) failed (error \(st)).") }
}

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ fallback: T) -> T {
    var a = addr(sel), size = UInt32(MemoryLayout<T>.size)
    var v = fallback
    let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    return st == noErr ? v : fallback
}

func stringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var v: Unmanaged<CFString>? = nil
    let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    guard st == noErr, let u = v else { return nil }
    return u.takeRetainedValue() as String
}

let zeros: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 16384); p.initialize(repeating: 0, count: 16384); return p }()
let scratch: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 32768); p.initialize(repeating: 0, count: 32768); return p }()

final class LiveEngine {
    private(set) var dsp: DSP?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var outputName = ""
    var settings = Settings() { didSet { dsp?.update(settings) } }
    var bypass = false { didSet { dsp?.bypass = bypass } }
    var running: Bool { procID != nil }

    func start() throws {
        stop()
        do { try startInner() } catch { stop(); throw error }
    }

    private func startInner() throws {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let out: AudioObjectID = prop(sys, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
        guard out != kAudioObjectUnknown, let outUID = stringProp(out, kAudioDevicePropertyDeviceUID) else {
            throw SpinError(msg: "No sound output found. Plug in headphones or pick an output in Sound settings.")
        }
        outputName = stringProp(out, kAudioObjectPropertyName) ?? "your output"

        // Leave our own sound out of the tap, or we'd hear ourselves forever
        var pid = getpid(), me = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        AudioObjectGetPropertyData(sys, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        guard me != kAudioObjectUnknown else { throw SpinError(msg: "Couldn't set up the audio tap (no process object).") }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        desc.uuid = UUID()
        desc.name = "Spinaural"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Tapping system audio")

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spinaural",
            kAudioAggregateDeviceUIDKey: "tech.rennko.spinaural." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID), "Creating the audio device")

        let sr: Float64 = prop(aggID, kAudioDevicePropertyNominalSampleRate, 48000.0)
        let dsp = DSP(sr: sr); dsp.update(settings); dsp.bypass = bypass
        self.dsp = dsp
        // A plain C IOProc runs on the HAL's real-time IO thread (the block + dispatch-queue variant
        // hops to an ordinary thread, which can miss deadlines and crackle).
        let ioProc: AudioDeviceIOProc = { _, _, inData, _, outData, _, client in
            guard let client else { return noErr }
            render(Unmanaged<DSP>.fromOpaque(client).takeUnretainedValue(), inData, outData)
            return noErr
        }
        try check(AudioDeviceCreateIOProcID(aggID, ioProc, Unmanaged.passUnretained(dsp).toOpaque(), &procID), "Starting audio")
        onlyTapInput()
        try check(AudioDeviceStart(aggID, procID), "Starting audio")
    }

    // The output device may have a microphone (AirPods do). Switch every input stream off except
    // the tap's, so we never wake the mic or drop headphones into call mode.
    private func onlyTapInput() {
        guard let procID else { return }
        var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggID, &a, 0, nil, &size) == noErr else { return }
        let n = Int(size) / MemoryLayout<AudioStreamID>.size
        guard n > 1 else { return }
        let bytes = 16 + 4 * n
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
        raw.storeBytes(of: UInt32(n), toByteOffset: 8, as: UInt32.self)
        for k in 0..<n { raw.storeBytes(of: UInt32(k == n - 1 ? 1 : 0), toByteOffset: 12 + 4 * k, as: UInt32.self) }
        var u = addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        AudioObjectSetPropertyData(aggID, &u, 0, nil, UInt32(12 + 4 * n), raw)
    }

    func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        dsp = nil
    }
}

let timebase: Double = { var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return Double(tb.numer) / Double(tb.denom) / 1e9 }()
@inline(__always) func ticksToSec(_ t: UInt64) -> Double { Double(t) * timebase }

// Real-time callback: tap audio comes in as the last input stream; write to the output device.
func render(_ dsp: DSP, _ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    guard outs.count > 0 else { return }
    for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    let o0 = outs[0], och = Int(max(1, o0.mNumberChannels))
    guard let ob = o0.mData?.assumingMemoryBound(to: Float.self) else { return }
    let frames = min(Int(o0.mDataByteSize) / (4 * och), 8192)

    var oL = ob, oR = ob, oStride = och
    var monoOut = false
    if och >= 2 { oR = ob + 1 }
    else if outs.count >= 2, let r = outs[1].mData?.assumingMemoryBound(to: Float.self) { oR = r; oStride = 1 }
    else { oL = scratch; oR = scratch + 1; oStride = 2; monoOut = true }

    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    var iL = UnsafePointer(zeros), iR = UnsafePointer(zeros), iStride = 1, inFrames = frames
    if ins.count > 0, let last = ins[ins.count - 1].mData?.assumingMemoryBound(to: Float.self) {
        let b = ins[ins.count - 1], ch = Int(max(1, b.mNumberChannels))
        if ch >= 2 { iL = UnsafePointer(last); iR = UnsafePointer(last + 1); iStride = ch; inFrames = Int(b.mDataByteSize) / (4 * ch) }
        else if ins.count >= 2, let l = ins[ins.count - 2].mData?.assumingMemoryBound(to: Float.self) {
            iL = UnsafePointer(l); iR = UnsafePointer(last); inFrames = Int(b.mDataByteSize) / 4
        } else { iL = UnsafePointer(last); iR = UnsafePointer(last); inFrames = Int(b.mDataByteSize) / 4 }
    }
    let n = min(frames, inFrames)
    let t0 = mach_absolute_time()
    if dsp.lastHost != 0 {
        let gap = ticksToSec(t0 - dsp.lastHost), budget = Double(frames) / dsp.sr
        if gap > budget * 1.6 { dsp.late += 1 }
    }
    dsp.lastHost = t0; dsp.calls += 1
    if n < frames { dsp.short += 1 }
    dsp.process(n, iL, iR, iStride, oL, oR, oStride)
    dsp.worst = max(dsp.worst, ticksToSec(mach_absolute_time() - t0) / (Double(max(1, frames)) / dsp.sr))
    if monoOut { for k in 0..<n { ob[k] = (scratch[2 * k] + scratch[2 * k + 1]) * 0.5 } }
}

// MARK: - App model

final class AppModel: ObservableObject {
    @Published var s: Settings { didSet { engine.settings = s; save() } }
    @Published var on = false
    @Published var bypass = false { didSet { engine.bypass = bypass } }
    @Published var status = "Off. Your Mac sounds normal."
    @Published var problem = false
    let engine = LiveEngine()
    var onState: ((Bool) -> Void)?
    private let t0 = Date()

    init() {
        if let d = UserDefaults.standard.data(forKey: "settings"), let v = try? JSONDecoder().decode(Settings.self, from: d) { s = v }
        else { s = Settings() }
        engine.settings = s
    }
    private func save() { if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "settings") } }

    func toggle() { on ? turnOff() : turnOn() }
    func turnOn() {
        do {
            try engine.start(); on = true; problem = false
            status = "On. Everything your Mac plays goes through Spinaural, out to \(engine.outputName)."
        } catch {
            on = false; problem = true; status = error.localizedDescription
        }
        onState?(on)
    }
    func turnOff() {
        engine.stop(); on = false; problem = false
        status = "Off. Your Mac sounds normal."
        onState?(on)
    }
    func restartIfOn() { if on { turnOn() } }
    func time() -> Double { engine.dsp?.t ?? Date().timeIntervalSince(t0) }
}

// MARK: - Look: a 1970s stereo-demonstration record sleeve

extension Color {
    static let paper = Color(red: 0.937, green: 0.898, blue: 0.812)
    static let card = Color(red: 0.965, green: 0.933, blue: 0.863)
    static let ink = Color(red: 0.114, green: 0.102, blue: 0.086)
    static let ink2 = Color(red: 0.365, green: 0.329, blue: 0.275)
    static let ink3 = Color(red: 0.549, green: 0.510, blue: 0.435)
    static let sig = Color(red: 0.824, green: 0.275, blue: 0.165)
    static let blu = Color(red: 0.173, green: 0.353, blue: 0.533)
}

struct Cap: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundColor(.ink2) }
}

struct Seg<T: Hashable>: View {
    let title: String
    let options: [(String, T)]
    @Binding var value: T
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Cap(text: title)
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    let on = value == options[i].1
                    Button { value = options[i].1 } label: {
                        Text(options[i].0).font(.system(size: 11.5, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(on ? Color.ink : Color.clear).foregroundColor(on ? .paper : .ink)
                            .overlay(alignment: .leading) { if i > 0 { Color.ink.frame(width: 1.5) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.ink, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct Knob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fmt: (Double) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Cap(text: title); Spacer(); Text(fmt(value)).font(.system(size: 11, design: .monospaced)) }
            Slider(value: $value, in: range, step: step).controlSize(.small).tint(.sig)
        }
    }
}

struct OrbitView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        TimelineView(.animation) { _ in
            let t = m.time(), s = m.s
            VStack(spacing: 6) {
                Canvas { gc, size in draw(gc, size, t, s) }.frame(height: 210)
                meters
            }
        }
    }

    var meters: some View {
        let l = CGFloat(m.engine.dsp?.meterL ?? 0), r = CGFloat(m.engine.dsp?.meterR ?? 0)
        func w(_ v: CGFloat) -> CGFloat { max(0, min(1, (20 * log10(v + 1e-6) + 48) / 48)) }
        return VStack(spacing: 4) {
            ForEach([("L", w(l)), ("R", w(r))], id: \.0) { item in
                HStack(spacing: 8) {
                    Text(item.0).font(.system(size: 10, design: .monospaced)).foregroundColor(.ink2)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).stroke(Color.ink, lineWidth: 1.2)
                            Rectangle().fill(item.1 > 0.93 ? Color.sig : Color.ink).frame(width: g.size.width * item.1)
                        }
                    }.frame(height: 8)
                }
            }
        }
    }

    func draw(_ gc: GraphicsContext, _ size: CGSize, _ t: Double, _ s: Settings) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let sc = (min(size.width, size.height) / 2 - 14) / 4.4
        func P(_ p: Pos) -> CGPoint { CGPoint(x: c.x + p.x * sc, y: c.y + p.z * sc) }
        for r in 1...4 {
            let rr = Double(r) * sc
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                      with: .color(.ink.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: r % 2 == 1 ? [2, 5] : []))
        }
        var axes = Path(); axes.move(to: CGPoint(x: c.x, y: 4)); axes.addLine(to: CGPoint(x: c.x, y: size.height - 4))
        axes.move(to: CGPoint(x: c.x - 4.4 * sc, y: c.y)); axes.addLine(to: CGPoint(x: c.x + 4.4 * sc, y: c.y))
        gc.stroke(axes, with: .color(.ink.opacity(0.15)), lineWidth: 1)
        let lab = { (txt: String, at: CGPoint) in gc.draw(Text(txt).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(.ink3), at: at) }
        lab("FRONT", CGPoint(x: c.x, y: 8)); lab("BACK", CGPoint(x: c.x, y: size.height - 6))
        lab("L", CGPoint(x: c.x - 4.4 * sc - 8, y: c.y - 8)); lab("R", CGPoint(x: c.x + 4.4 * sc + 8, y: c.y - 8))

        let split = s.layers == 16
        let sur = s.layers == 360
        let voices: [((Double, Settings) -> Pos, Color)] = sur ? [] : split ? [(pos, .sig), (posB, .blu)] : [(pos, .sig)]
        let span: Double = [s.lap, s.lap * 4, s.lap, s.lap * 2.5][s.pattern.rawValue]
        for (fn, col) in voices {
            var path = Path()
            for i in 0...200 { let p = P(fn(t + span * Double(i) / 200, s)); i == 0 ? path.move(to: p) : path.addLine(to: p) }
            gc.stroke(path, with: .color(split ? col.opacity(0.5) : .ink2.opacity(0.55)), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
        }
        // head with headphones
        let hr = max(13, 0.42 * sc)
        let ear = { (dx: Double) in Path(ellipseIn: CGRect(x: c.x + dx - hr * 0.2, y: c.y - hr * 0.34, width: hr * 0.4, height: hr * 0.68)) }
        for e in [ear(-hr * 1.02), ear(hr * 1.02)] { gc.fill(e, with: .color(.card)); gc.stroke(e, with: .color(.ink), lineWidth: 2) }
        var nose = Path(); nose.move(to: CGPoint(x: c.x - hr * 0.22, y: c.y - hr * 0.94)); nose.addLine(to: CGPoint(x: c.x, y: c.y - hr * 1.32)); nose.addLine(to: CGPoint(x: c.x + hr * 0.22, y: c.y - hr * 0.94))
        gc.fill(nose, with: .color(.card)); gc.stroke(nose, with: .color(.ink), lineWidth: 2)
        let head = Path(ellipseIn: CGRect(x: c.x - hr, y: c.y - hr, width: 2 * hr, height: 2 * hr))
        gc.fill(head, with: .color(.card)); gc.stroke(head, with: .color(.ink), lineWidth: 2)
        var band = Path(); band.addArc(center: c, radius: hr * 0.62, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
        gc.stroke(band, with: .color(.ink), lineWidth: 3.5)

        if m.bypass {
            gc.draw(Text("ORIGINAL STEREO").font(.system(size: 11, weight: .semibold)).foregroundColor(.ink2), at: CGPoint(x: c.x, y: c.y + hr + 24))
            return
        }
        for (fn, col) in voices {
            for i in 0..<36 {
                var seg = Path()
                seg.move(to: P(fn(t - 1.3 * Double(i + 1) / 36, s))); seg.addLine(to: P(fn(t - 1.3 * Double(i) / 36, s)))
                let k = 1 - Double(i) / 36
                gc.stroke(seg, with: .color(col.opacity(k * 0.8)), style: StrokeStyle(lineWidth: 4.5 * k + 1, lineCap: .round))
            }
            let now = fn(t, s), p = P(now), rad = 8 + now.y * 3.5
            var sight = Path(); sight.move(to: c); sight.addLine(to: p)
            gc.stroke(sight, with: .color(col), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            let dot = Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad))
            gc.fill(dot, with: .color(col)); gc.stroke(dot, with: .color(.ink), lineWidth: 1.8)
            gc.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.paper))
        }
        if sur {
            for i in 0..<SPEAKERS.count {
                let sp = SPEAKERS[i], p = P(spkPos(i, t, s)), rad = 3.5 + Double(sp.gain) * 7
                var line = Path(); line.move(to: c); line.addLine(to: p)
                gc.stroke(line, with: .color(.sig.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                let dot = Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad))
                gc.fill(dot, with: .color(.sig.opacity(sp.el > 0 ? 0.45 : 0.4 + Double(sp.gain) * 0.6)))
                gc.stroke(dot, with: .color(.ink), lineWidth: 1.5)
            }
            gc.draw(Text("STAGE IN FRONT").font(.system(size: 9, design: .monospaced)).foregroundColor(.ink2), at: CGPoint(x: 4, y: size.height - 22), anchor: .leading)
            gc.draw(Text("ROOM ALL AROUND").font(.system(size: 9, design: .monospaced)).foregroundColor(.ink2), at: CGPoint(x: 4, y: size.height - 9), anchor: .leading)
        }
        if split {
            gc.fill(Path(ellipseIn: CGRect(x: 4, y: size.height - 30, width: 9, height: 9)), with: .color(.sig))
            gc.draw(Text("MIDS").font(.system(size: 9, design: .monospaced)).foregroundColor(.ink2), at: CGPoint(x: 18, y: size.height - 25.5), anchor: .leading)
            gc.fill(Path(ellipseIn: CGRect(x: 4, y: size.height - 15, width: 9, height: 9)), with: .color(.blu))
            gc.draw(Text("HIGHS").font(.system(size: 9, design: .monospaced)).foregroundColor(.ink2), at: CGPoint(x: 18, y: size.height - 10.5), anchor: .leading)
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: AppModel
    var flat = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.ink).frame(height: 2.5)
            if flat { controls } else { ScrollView { controls } }
            Rectangle().fill(Color.ink).frame(height: 1.5)
            footer
        }
        .frame(width: 380, height: flat ? nil : 660)
        .background(Color.paper)
        .foregroundColor(.ink)
        .environment(\.colorScheme, .light)
    }

    var controls: some View {
                VStack(alignment: .leading, spacing: 14) {
                    OrbitView(m: m)
                    presets
                    Seg(title: "Mode", options: [("8D", 8), ("16D", 16), ("360° · be there", 360)], value: $m.s.layers)
                    Text(MODE_HINTS[m.s.layers] ?? "").font(.system(size: 11)).foregroundColor(.ink3).padding(.top, -8)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 14) {
                        Seg(title: "Path", options: Pattern.allCases.map { ($0.label, $0) }, value: $m.s.pattern)
                        Text(m.s.pattern.hint).font(.system(size: 11)).foregroundColor(.ink3).padding(.top, -8)
                        Seg(title: "Direction", options: [("Clockwise", 1.0), ("Counter-clockwise", -1.0)], value: $m.s.dir)
                        Knob(title: "Lap time", value: $m.s.lap, range: 2...30, step: 0.5) { String(format: "%.1f s per lap", $0) }
                    }
                    .disabled(m.s.layers == 360).opacity(m.s.layers == 360 ? 0.35 : 1)
                    Knob(title: m.s.layers == 360 ? "Distance to the stage" : "Distance", value: $m.s.dist, range: 1...4, step: 0.1) { String(format: "%.1f m away", $0) }
                    Knob(title: "Rise and fall", value: $m.s.height, range: 0...100, step: 1) { "\(Int($0))%" }
                        .disabled(m.s.layers == 360).opacity(m.s.layers == 360 ? 0.35 : 1)
                    Seg(title: "Room", options: Room.allCases.map { ($0.label, $0) }, value: $m.s.room)
                    Knob(title: "Echo", value: $m.s.echo, range: 0...100, step: 1) { $0 == 0 ? "Dry" : "\(Int($0))%" }
                    Toggle(isOn: $m.s.bass) { Text("Keep the bass in the middle").font(.system(size: 12, weight: .medium)) }
                        .toggleStyle(.checkbox).tint(.sig)
                    Knob(title: "Bass boost", value: $m.s.boost, range: 0...12, step: 0.5) { $0 == 0 ? "Off" : String(format: "+%g dB", $0) }
                }
                .padding(16)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SPN-8D · LIVE FROM YOUR MAC").font(.system(size: 9.5, design: .monospaced)).foregroundColor(.ink2)
                    (Text("Spin").font(.system(size: 32, weight: .heavy, design: .serif))
                     + Text("aural").font(.system(size: 32, weight: .medium, design: .serif)).italic().foregroundColor(.sig))
                }
                Spacer()
                Button(action: m.toggle) {
                    Text(m.on ? "STOP" : "SPIN MY MAC").font(.system(size: 12, weight: .bold)).tracking(1)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(m.on ? Color.ink : Color.sig).foregroundColor(.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }.buttonStyle(.plain)
            }
            Text(m.status).font(.system(size: 11.5)).foregroundColor(m.problem ? .sig : .ink2).fixedSize(horizontal: false, vertical: true)
            if m.on || m.problem { silenceHint }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    var silenceHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if m.problem || (m.engine.dsp?.inLevel ?? 1) < 0.00001 {
                HStack(spacing: 6) {
                    Text("Hearing nothing? Play something, or let Spinaural record system audio.").font(.system(size: 11)).foregroundColor(.ink3)
                    Button("Open settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }.buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }

    var presets: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Cap(text: "Presets"); Spacer()
                Text(PRESETS.first { m.s.matches($0.s) }?.name ?? "Custom").font(.system(size: 11, design: .monospaced)) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 3) {
                ForEach(PRESETS, id: \.no) { p in
                    let on = m.s.matches(p.s)
                    Button {
                        var n = p.s; n.boost = m.s.boost; m.s = n
                    } label: {
                        HStack(alignment: .top, spacing: 5) {
                            Text(p.no).font(.system(size: 9.5, design: .monospaced)).foregroundColor(on ? .sig : .ink3).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 12.5, weight: .bold, design: .serif))
                                Text(p.desc).font(.system(size: 9.5)).foregroundColor(on ? .paper.opacity(0.75) : .ink3).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(5)
                        .background(on ? Color.ink : Color.clear).foregroundColor(on ? .paper : .ink)
                        .clipShape(RoundedRectangle(cornerRadius: 2)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 10) {
            Seg(title: "", options: [("8D", false), ("Original", true)], value: $m.bypass).frame(width: 150)
            Spacer()
            Button("Quit") { m.turnOff(); NSApp.terminate(nil) }.buttonStyle(.link).foregroundColor(.ink2)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Menu bar app

func menuIcon(_ on: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
        ring.lineWidth = 1.4
        if !on { ring.setLineDash([2, 2], count: 2, phase: 0) }
        NSColor.black.setStroke(); ring.stroke()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 6.5, y: 6.5, width: 5, height: 5)).fill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: 11.5, width: 5, height: 5)).fill()
        return true
    }
    img.isTemplate = true
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let pop = NSPopover()
    let model = AppModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuIcon(false)
        item.button?.toolTip = "Spinaural"
        item.button?.target = self
        item.button?.action = #selector(togglePop)
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 380, height: 660)
        pop.contentViewController = NSHostingController(rootView: ContentView(m: model))
        model.onState = { [weak self] on in self?.item.button?.image = menuIcon(on) }

        // Follow the user when they switch outputs (e.g. plug in headphones)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.model.restartIfOn() }
        }
        if ProcessInfo.processInfo.environment["SPINAURAL_LIVETEST"] != nil { liveTest() }
        else { DispatchQueue.main.async { self.togglePop() } }
    }

    func applicationWillTerminate(_ n: Notification) { model.engine.stop() }

    @objc func togglePop() {
        if pop.isShown { pop.performClose(nil) }
        else if let b = item.button { pop.show(relativeTo: b.bounds, of: b, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }

    // SPINAURAL_LIVETEST=<seconds> SPINAURAL_LOG=<file>: start, log levels each second, quit.
    func liveTest() {
        let env = ProcessInfo.processInfo.environment
        let secs = Int(env["SPINAURAL_LIVETEST"] ?? "") ?? 8
        let logPath = env["SPINAURAL_LOG"] ?? "/tmp/spinaural-live.log"
        var lines: [String] = []
        model.turnOn()
        lines.append("start on=\(model.on) status=\(model.status)")
        var k = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            k += 1
            if let d = self.model.engine.dsp {
                let db = { (v: Float) in String(format: "%.1f", 20 * log10(v + 1e-9)) }
                lines.append("t=\(String(format: "%.1f", d.t)) sr=\(Int(d.sr)) in=\(db(d.inLevel)) outL=\(db(d.meterL)) outR=\(db(d.meterR)) calls=\(d.calls) late=\(d.late) short=\(d.short) worstLoad=\(String(format: "%.0f%%", d.worst * 100))")
            } else { lines.append("no dsp") }
            if k >= secs {
                timer.invalidate(); self.model.turnOff()
                try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Offline self-test (no audio devices needed)

func selfTest() {
    let sr = 48000.0, secs = 16, n = Int(sr) * secs
    var seed: UInt32 = 12345
    func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
    let inL = UnsafeMutablePointer<Float>.allocate(capacity: n), inR = UnsafeMutablePointer<Float>.allocate(capacity: n)
    var pink: Float = 0
    for i in 0..<n {
        pink = pink * 0.97 + rnd() * 0.03
        let kick = Float(sin(TAU * 55 * Double(i) / sr)) * (i % 24000 < 3000 ? 0.6 : 0)
        inL[i] = rnd() * 0.12 + pink * 0.6 + kick; inR[i] = rnd() * 0.12 + pink * 0.6 + kick
    }
    let outL = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n)
    func run(_ name: String, _ s: Settings) {
        let d = DSP(sr: sr); d.update(s)
        var i = 0
        let st = Date()
        while i < n { let c = min(512, n - i); d.process(c, inL + i, inR + i, 1, outL + 2 * i, outL + 2 * i + 1, 2); i += c }
        print("  cpu: \(String(format: "%.1f", Date().timeIntervalSince(st) / Double(secs) * 100))% of real time")
        func band(_ hp: Double, _ lp: Double?) -> String {
            var fL = [BQ(highpass: true, hp, sr), BQ(highpass: true, hp, sr)], fR = fL
            var gL = lp.map { [BQ(highpass: false, $0, sr), BQ(highpass: false, $0, sr)] } ?? [], gR = gL
            var rows: [String] = []
            var eL: Double = 0, eR: Double = 0
            for k in 0..<n {
                var l = fL[1].run(fL[0].run(outL[2 * k])), r = fR[1].run(fR[0].run(outL[2 * k + 1]))
                if !gL.isEmpty { l = gL[1].run(gL[0].run(l)); r = gR[1].run(gR[0].run(r)) }
                eL += Double(l * l); eR += Double(r * r)
                if (k + 1) % Int(sr) == 0 { rows.append(String(format: "%.0f", 10 * log10(eL / max(eR, 1e-12)))); eL = 0; eR = 0 }
            }
            return rows.joined(separator: " ")
        }
        var peak: Float = 0, nan = false
        for k in 0..<(2 * n) { peak = max(peak, abs(outL[k])); if outL[k].isNaN { nan = true } }
        print("\(name): peak=\(String(format: "%.2f", peak)) nan=\(nan)")
        print("  mids  L-R dB/s: \(band(400, 2000))")
        print("  highs L-R dB/s: \(band(5000, nil))")
    }
    run("Classic 8D", PRESETS[0].s)
    run("16D Classic", PRESETS[8].s)
    run("360 Front Row", PRESETS[12].s)
    var boosted = PRESETS[0].s; boosted.boost = 12
    run("Classic 8D +12dB bass", boosted)
}

// MARK: - main

if ProcessInfo.processInfo.environment["SPINAURAL_SELFTEST"] != nil { selfTest(); exit(0) }
// SPINAURAL_SHOT=<png>: render the panel to an image (16D preset) and quit
if let shot = ProcessInfo.processInfo.environment["SPINAURAL_SHOT"] {
  MainActor.assumeIsolated {
    let m = AppModel(); var st = PRESETS[Int(ProcessInfo.processInfo.environment["SPINAURAL_SHOT_PRESET"] ?? "8") ?? 8].s; st.boost = 4; m.s = st
    let r = ImageRenderer(content: ContentView(m: m, flat: true)); r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: shot)) }
  }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
