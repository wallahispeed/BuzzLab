import CoreHaptics
import AudioToolbox
import Foundation

enum HapticMode: String, CaseIterable, Identifiable {
    case continuous = "Constant"
    case pulse = "Pulse"
    case chop = "Buzz chop"
    case heartbeat = "Heartbeat"
    case triple = "Triple tap"
    case rolling = "Rolling"
    case rampUp = "Ramp up"
    case rampDown = "Ramp down"
    case wave = "Wave"
    case sos = "SOS"
    case random = "Random"
    case legacy = "Legacy buzz"

    var id: String { rawValue }

    /// Constant ignores speed; every other pattern repeats at the chosen speed.
    var usesSpeed: Bool { self != .continuous }
}

/// Full control over the Taptic Engine via Core Haptics.
final class HapticManager: ObservableObject {
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    @Published private(set) var running = false
    @Published private(set) var maxPowerOn = false

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var legacyTimer: Timer?

    // Last requested settings, used to restore after an engine reset.
    private var lastMode: HapticMode = .continuous
    private var lastIntensity: Float = 1
    private var lastSharpness: Float = 1
    private var lastRate: Double = 10

    init() {
        startEngine()
    }

    private func startEngine() {
        guard supported else { return }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = false
            e.playsHapticsOnly = true
            e.resetHandler = { [weak self] in
                guard let self else { return }
                try? self.engine?.start()
                if self.running {
                    self.start(mode: self.lastMode,
                               intensity: self.lastIntensity,
                               sharpness: self.lastSharpness,
                               rate: self.lastRate)
                }
            }
            e.stoppedHandler = { _ in }
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
    }

    // MARK: - Max power toggle

    /// Absolute maximum: intensity 1.0, sharpness 1.0, continuous, looped until switched off.
    func setMaxPower(_ on: Bool) {
        if on {
            maxPowerOn = true
            start(mode: .continuous, intensity: 1, sharpness: 1, rate: 10)
        } else {
            maxPowerOn = false
            stop()
        }
    }

    // MARK: - Playback

    /// rate = pattern cycles per second.
    func start(mode: HapticMode, intensity: Float, sharpness: Float, rate: Double) {
        stopPlayerOnly()
        lastMode = mode
        lastIntensity = intensity
        lastSharpness = sharpness
        lastRate = rate

        if mode == .legacy {
            startLegacy(rate: rate)
            running = true
            return
        }

        guard supported, let engine else { return }

        do {
            try? engine.start()
            let (pattern, loopLength) = try buildPattern(mode: mode,
                                                         intensity: intensity,
                                                         sharpness: sharpness,
                                                         rate: rate)
            let p = try engine.makeAdvancedPlayer(with: pattern)
            p.loopEnabled = true
            p.loopEnd = loopLength
            try p.start(atTime: CHHapticTimeImmediate)
            player = p
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        stopPlayerOnly()
        maxPowerOn = false
        running = false
    }

    private func stopPlayerOnly() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        legacyTimer?.invalidate()
        legacyTimer = nil
    }

    /// One single sharp tap.
    func tap(intensity: Float, sharpness: Float) {
        guard supported, let engine else { return }
        do {
            try? engine.start()
            let ev = CHHapticEvent(eventType: .hapticTransient,
                                   parameters: params(intensity, sharpness),
                                   relativeTime: 0)
            let pattern = try CHHapticPattern(events: [ev], parameters: [])
            let p = try engine.makePlayer(with: pattern)
            try p.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    // MARK: - Pattern building

    private func params(_ intensity: Float, _ sharpness: Float) -> [CHHapticEventParameter] {
        [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ]
    }

    /// One haptic event inside a cycle. dur == nil means a transient tap.
    private struct Ev {
        var t: Double
        var dur: Double?
        var i: Float
        var s: Float
    }

    private func buildPattern(mode: HapticMode,
                              intensity: Float,
                              sharpness: Float,
                              rate: Double) throws -> (CHHapticPattern, TimeInterval) {
        if mode == .continuous || mode == .legacy {
            // 30 s is the longest a single continuous event can be; the player loops it.
            let ev = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: params(intensity, sharpness),
                                   relativeTime: 0,
                                   duration: 30)
            return (try CHHapticPattern(events: [ev], parameters: []), 30)
        }

        // Every other pattern is one cycle repeated. Speed sets how long a cycle lasts.
        let hz = min(max(rate, 0.5), 400)
        let period = 1.0 / hz
        let first = cycle(mode, period, intensity, sharpness)
        let perCycle = max(first.count, 1)
        // Aim for about one second per loop, but cap the number of events.
        let wanted = max(1, Int(hz.rounded()))
        let cycles = max(1, min(wanted, 800 / perCycle))

        var events: [CHHapticEvent] = []
        for c in 0..<cycles {
            let base = Double(c) * period
            let list = (c == 0) ? first : cycle(mode, period, intensity, sharpness)
            for e in list {
                let i = min(max(e.i, 0), 1)
                let s = min(max(e.s, 0), 1)
                if let d = e.dur {
                    events.append(CHHapticEvent(eventType: .hapticContinuous,
                                                parameters: params(i, s),
                                                relativeTime: base + e.t,
                                                duration: max(d, 0.002)))
                } else {
                    events.append(CHHapticEvent(eventType: .hapticTransient,
                                                parameters: params(i, s),
                                                relativeTime: base + e.t))
                }
            }
        }
        return (try CHHapticPattern(events: events, parameters: []), Double(cycles) * period)
    }

    /// One cycle of a pattern, lasting T seconds.
    private func cycle(_ mode: HapticMode, _ T: Double, _ I: Float, _ S: Float) -> [Ev] {
        let steps = max(2, min(8, Int(T / 0.01)))
        switch mode {
        case .pulse:
            return [Ev(t: 0, dur: nil, i: I, s: S)]

        case .chop:
            return [Ev(t: 0, dur: T * 0.5, i: I, s: S)]

        case .heartbeat:
            return [Ev(t: 0, dur: nil, i: I, s: S),
                    Ev(t: T * 0.25, dur: nil, i: I * 0.7, s: max(S * 0.6, 0.1))]

        case .triple:
            return [Ev(t: 0, dur: nil, i: I, s: S),
                    Ev(t: T * 0.1, dur: nil, i: I, s: S),
                    Ev(t: T * 0.2, dur: nil, i: I, s: S)]

        case .rolling:
            return [Ev(t: 0, dur: nil, i: I, s: S),
                    Ev(t: T * 0.5, dur: nil, i: I * 0.6, s: S * 0.2)]

        case .rampUp:
            return (0..<steps).map { k in
                Ev(t: T * Double(k) / Double(steps),
                   dur: T / Double(steps),
                   i: I * Float(k + 1) / Float(steps),
                   s: S)
            }

        case .rampDown:
            return (0..<steps).map { k in
                Ev(t: T * Double(k) / Double(steps),
                   dur: T / Double(steps),
                   i: I * Float(steps - k) / Float(steps),
                   s: S)
            }

        case .wave:
            let n = max(4, steps)
            return (0..<n).map { k in
                let level = 0.55 + 0.45 * sin(2 * Double.pi * Double(k) / Double(n))
                return Ev(t: T * Double(k) / Double(n),
                          dur: T / Double(n),
                          i: I * Float(level),
                          s: S)
            }

        case .sos:
            // Morse S O S spread over one cycle (34 time units).
            let u = T / 34
            let marks: [(Double, Double)] = [(0, 1), (2, 1), (4, 1),
                                             (8, 3), (12, 3), (16, 3),
                                             (22, 1), (24, 1), (26, 1)]
            return marks.map { Ev(t: $0.0 * u, dur: $0.1 * u, i: I, s: S) }

        case .random:
            return (0..<4).map { _ in
                Ev(t: T * Double.random(in: 0..<1),
                   dur: nil,
                   i: I * Float.random(in: 0.3...1),
                   s: Float.random(in: 0...1))
            }

        case .continuous, .legacy:
            return []
        }
    }

    // MARK: - Legacy system vibration (fixed strength, works on any iPhone)

    private func startLegacy(rate: Double) {
        let interval = max(0.45, 1.0 / max(rate, 0.1))
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        legacyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}
