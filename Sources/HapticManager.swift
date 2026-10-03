import CoreHaptics
import AudioToolbox
import Foundation

enum HapticMode: String, CaseIterable, Identifiable {
    case continuous = "Continuous"
    case pulse = "Pulse"
    case heartbeat = "Heartbeat"
    case ramp = "Ramp"
    case legacy = "Legacy buzz"

    var id: String { rawValue }
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

    private func buildPattern(mode: HapticMode,
                              intensity: Float,
                              sharpness: Float,
                              rate: Double) throws -> (CHHapticPattern, TimeInterval) {
        switch mode {
        case .continuous, .legacy:
            // 30 s is the longest a single continuous event can be; the player loops it.
            let ev = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: params(intensity, sharpness),
                                   relativeTime: 0,
                                   duration: 30)
            return (try CHHapticPattern(events: [ev], parameters: []), 30)

        case .pulse:
            let hz = max(rate, 1)
            let period = 1.0 / hz
            let count = max(1, Int(ceil(1.0 / period)))
            var events: [CHHapticEvent] = []
            for i in 0..<count {
                events.append(CHHapticEvent(eventType: .hapticTransient,
                                            parameters: params(intensity, sharpness),
                                            relativeTime: Double(i) * period))
            }
            return (try CHHapticPattern(events: events, parameters: []), Double(count) * period)

        case .heartbeat:
            let a = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: params(intensity, sharpness),
                                  relativeTime: 0)
            let b = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: params(intensity * 0.7, max(sharpness * 0.6, 0.1)),
                                  relativeTime: 0.18)
            return (try CHHapticPattern(events: [a, b], parameters: []), 0.9)

        case .ramp:
            let ev = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: params(1, sharpness),
                                   relativeTime: 0,
                                   duration: 2)
            let curve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    .init(relativeTime: 0, value: 0.0),
                    .init(relativeTime: 2, value: intensity)
                ],
                relativeTime: 0
            )
            return (try CHHapticPattern(events: [ev], parameterCurves: [curve]), 2)
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
