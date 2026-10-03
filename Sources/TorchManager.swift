import AVFoundation
import Foundation

/// Full control over the LED torch: steady brightness, strobe at a chosen rate,
/// an unthrottled "as fast as the hardware allows" mode, and SOS.
final class TorchManager: ObservableObject {
    private let device: AVCaptureDevice? = AVCaptureDevice.default(for: .video)

    var available: Bool { device?.hasTorch == true }

    @Published private(set) var strobing = false
    @Published private(set) var steadyOn = false
    @Published private(set) var measuredToggleHz: Double = 0

    private let stateLock = NSLock()
    private var _hz: Double = 10
    private var _unthrottled = false
    private var _level: Float = 1.0
    private var _running = false
    private var worker: Thread?

    // MARK: - Steady light

    func setSteady(on: Bool, level: Float) {
        stopStrobe()
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on {
                let clamped = min(max(level, 0.01), AVCaptureDevice.maxAvailableTorchLevel)
                try device.setTorchModeOn(level: clamped)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.steadyOn = on }
        } catch {}
    }

    // MARK: - Strobe

    /// Safe to call repeatedly while strobing to change speed or brightness live.
    func updateStrobe(hz: Double, unthrottled: Bool, level: Float) {
        stateLock.lock()
        _hz = max(hz, 0.1)
        _unthrottled = unthrottled
        _level = min(max(level, 0.01), 1.0)
        stateLock.unlock()
    }

    func startStrobe(hz: Double, unthrottled: Bool, level: Float) {
        guard available, !isRunning else {
            updateStrobe(hz: hz, unthrottled: unthrottled, level: level)
            return
        }
        updateStrobe(hz: hz, unthrottled: unthrottled, level: level)
        setRunning(true)
        DispatchQueue.main.async { self.strobing = true; self.steadyOn = false }

        let t = Thread { [weak self] in self?.strobeLoop() }
        t.qualityOfService = .userInteractive
        t.name = "torch-strobe"
        worker = t
        t.start()
    }

    func stopStrobe() {
        setRunning(false)
        worker = nil
        DispatchQueue.main.async { self.strobing = false; self.measuredToggleHz = 0 }
    }

    func stopAll() {
        stopStrobe()
        guard let device, device.hasTorch else { return }
        if (try? device.lockForConfiguration()) != nil {
            device.torchMode = .off
            device.unlockForConfiguration()
        }
        DispatchQueue.main.async { self.steadyOn = false }
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _running
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock(); _running = value; stateLock.unlock()
    }

    private func snapshot() -> (hz: Double, unthrottled: Bool, level: Float, running: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (_hz, _unthrottled, _level, _running)
    }

    private func strobeLoop() {
        guard let device else { return }
        do { try device.lockForConfiguration() } catch { setRunning(false); return }

        var isOn = false
        var toggles = 0
        var windowStart = DispatchTime.now().uptimeNanoseconds
        var nextToggle = windowStart

        while true {
            let s = snapshot()
            if !s.running { break }

            isOn.toggle()
            if isOn {
                try? device.setTorchModeOn(level: s.level)
            } else {
                device.torchMode = .off
            }
            toggles += 1

            if !s.unthrottled {
                // Two toggles per cycle (on + off), so the half-period is 1 / (2 * hz).
                let halfPeriodNs = UInt64(1_000_000_000.0 / (2.0 * s.hz))
                nextToggle &+= halfPeriodNs
                let now = DispatchTime.now().uptimeNanoseconds
                if nextToggle > now {
                    let wait = nextToggle - now
                    if wait > 2_000_000 {
                        Thread.sleep(forTimeInterval: Double(wait - 1_000_000) / 1_000_000_000.0)
                    }
                    // Spin the last bit for accuracy.
                    while DispatchTime.now().uptimeNanoseconds < nextToggle { }
                } else {
                    // Fell behind (hardware slower than requested); resync.
                    nextToggle = now
                }
            }
            // Unthrottled: no sleep, toggle as fast as the torch API returns.

            let now = DispatchTime.now().uptimeNanoseconds
            if now - windowStart >= 500_000_000 {
                let seconds = Double(now - windowStart) / 1_000_000_000.0
                let cyclesPerSec = Double(toggles) / 2.0 / seconds
                DispatchQueue.main.async { self.measuredToggleHz = cyclesPerSec }
                toggles = 0
                windowStart = now
            }
        }

        device.torchMode = .off
        device.unlockForConfiguration()
    }

    // MARK: - SOS

    func playSOS(level: Float) {
        guard available, !isRunning else { return }
        setRunning(true)
        DispatchQueue.main.async { self.strobing = true }

        let unit = 0.2
        // (on duration in units, gap after in units)
        let dot = (1.0, 1.0), dash = (3.0, 1.0)
        let letterGap = 2.0 // extra gap after each letter
        let sequence: [(Double, Double)] = [dot, dot, dot, (0, letterGap),
                                            dash, dash, dash, (0, letterGap),
                                            dot, dot, dot, (0, 6)]

        let t = Thread { [weak self] in
            guard let self, let device = self.device else { return }
            do { try device.lockForConfiguration() } catch { self.setRunning(false); return }
            outer: while self.isRunning {
                for (on, gap) in sequence {
                    if !self.isRunning { break outer }
                    if on > 0 {
                        try? device.setTorchModeOn(level: min(max(level, 0.01), 1.0))
                        Thread.sleep(forTimeInterval: on * unit)
                        device.torchMode = .off
                    }
                    Thread.sleep(forTimeInterval: gap * unit)
                }
            }
            device.torchMode = .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.strobing = false }
        }
        t.qualityOfService = .userInitiated
        worker = t
        t.start()
    }
}
