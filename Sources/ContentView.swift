import SwiftUI

struct ContentView: View {
    @EnvironmentObject var haptics: HapticManager
    @EnvironmentObject var torch: TorchManager

    @AppStorage("warningAccepted") private var warningAccepted = false

    var body: some View {
        TabView {
            HapticsTab()
                .tabItem { Label("Haptics", systemImage: "iphone.radiowaves.left.and.right") }
            TorchTab()
                .tabItem { Label("Flash", systemImage: "flashlight.on.fill") }
            ComboTab()
                .tabItem { Label("Combo", systemImage: "bolt.fill") }
        }
        .alert("Flashing light warning", isPresented: .constant(!warningAccepted)) {
            Button("I understand") { warningAccepted = true }
        } message: {
            Text("The strobe can flash at rates that may trigger seizures in people with photosensitive epilepsy. Don't point it at anyone's face, and don't use it around anyone who might be affected.")
        }
    }
}

// MARK: - Haptics

struct HapticsTab: View {
    @EnvironmentObject var haptics: HapticManager

    @State private var mode: HapticMode = .continuous
    @State private var intensity: Double = 1.0
    @State private var sharpness: Double = 1.0
    @State private var rate: Double = 10

    var body: some View {
        NavigationStack {
            Form {
                if !haptics.supported {
                    Section {
                        Text("This device doesn't report Core Haptics support. Only Legacy buzz will work.")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Max power") {
                    Toggle(isOn: Binding(get: { haptics.maxPowerOn },
                                         set: { haptics.setMaxPower($0) })) {
                        Label("MAX POWER", systemImage: "waveform.path.ecg")
                            .font(.headline)
                    }
                    Text("Continuous, intensity 100%, sharpness 100%, stays on until you switch it off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Custom") {
                    Picker("Mode", selection: $mode) {
                        ForEach(HapticMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading) {
                        Text("Intensity  \(Int(intensity * 100))%")
                        Slider(value: $intensity, in: 0.05...1)
                    }
                    VStack(alignment: .leading) {
                        Text("Sharpness  \(Int(sharpness * 100))%")
                        Slider(value: $sharpness, in: 0...1)
                    }
                    if mode == .pulse || mode == .legacy {
                        VStack(alignment: .leading) {
                            Text("Rate  \(Int(rate)) per second")
                            Slider(value: $rate, in: 1...100, step: 1)
                        }
                    }

                    Button {
                        if haptics.running && !haptics.maxPowerOn {
                            haptics.stop()
                        } else {
                            haptics.start(mode: mode,
                                          intensity: Float(intensity),
                                          sharpness: Float(sharpness),
                                          rate: rate)
                        }
                    } label: {
                        Text(haptics.running && !haptics.maxPowerOn ? "Stop" : "Start")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Single tap") {
                        haptics.tap(intensity: Float(intensity), sharpness: Float(sharpness))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("BuzzLab")
            .onChange(of: intensity) { _, _ in restartIfRunning() }
            .onChange(of: sharpness) { _, _ in restartIfRunning() }
            .onChange(of: rate) { _, _ in restartIfRunning() }
            .onChange(of: mode) { _, _ in restartIfRunning() }
        }
    }

    private func restartIfRunning() {
        guard haptics.running, !haptics.maxPowerOn else { return }
        haptics.start(mode: mode,
                      intensity: Float(intensity),
                      sharpness: Float(sharpness),
                      rate: rate)
    }
}

// MARK: - Torch

struct TorchTab: View {
    @EnvironmentObject var torch: TorchManager

    @State private var steadyLevel: Double = 1.0
    @State private var sliderPos: Double = 0.4   // 0...1, mapped logarithmically to 1...60 Hz
    @State private var unthrottled = false
    @State private var strobeLevel: Double = 1.0

    private var hz: Double { Self.hz(from: sliderPos) }

    static func hz(from pos: Double) -> Double {
        // 1 Hz to 60 Hz, log scale for fine control at the slow end
        pow(60, pos)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !torch.available {
                    Section {
                        Text("No torch found on this device.")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Steady light") {
                    VStack(alignment: .leading) {
                        Text("Brightness  \(Int(steadyLevel * 100))%")
                        Slider(value: $steadyLevel, in: 0.01...1)
                    }
                    Toggle("Torch on", isOn: Binding(
                        get: { torch.steadyOn },
                        set: { torch.setSteady(on: $0, level: Float(steadyLevel)) }
                    ))
                }

                Section("Strobe") {
                    Toggle("Unthrottled (max hardware speed)", isOn: $unthrottled)

                    VStack(alignment: .leading) {
                        Text(unthrottled ? "Speed  MAX"
                                         : "Speed  \(String(format: "%.1f", hz)) flashes/sec")
                        Slider(value: $sliderPos, in: 0...1)
                            .disabled(unthrottled)
                    }
                    VStack(alignment: .leading) {
                        Text("Strobe brightness  \(Int(strobeLevel * 100))%")
                        Slider(value: $strobeLevel, in: 0.05...1)
                    }

                    if torch.strobing {
                        Text("Measured: \(String(format: "%.0f", torch.measuredToggleHz)) flashes/sec")
                            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }

                    Button {
                        if torch.strobing {
                            torch.stopAll()
                            UIApplication.shared.isIdleTimerDisabled = false
                        } else {
                            UIApplication.shared.isIdleTimerDisabled = true
                            torch.startStrobe(hz: hz, unthrottled: unthrottled, level: Float(strobeLevel))
                        }
                    } label: {
                        Text(torch.strobing ? "Stop" : "Start strobe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(torch.strobing ? .red : .accentColor)

                    Button("SOS") {
                        if torch.strobing { torch.stopAll() }
                        else { torch.playSOS(level: Float(strobeLevel)) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Flashlight")
            .onChange(of: sliderPos) { _, _ in pushStrobeUpdate() }
            .onChange(of: unthrottled) { _, _ in pushStrobeUpdate() }
            .onChange(of: strobeLevel) { _, _ in pushStrobeUpdate() }
            .onChange(of: steadyLevel) { _, new in
                if torch.steadyOn { torch.setSteady(on: true, level: Float(new)) }
            }
        }
    }

    private func pushStrobeUpdate() {
        if torch.strobing {
            torch.updateStrobe(hz: hz, unthrottled: unthrottled, level: Float(strobeLevel))
        }
    }
}

// MARK: - Combo

struct ComboTab: View {
    @EnvironmentObject var haptics: HapticManager
    @EnvironmentObject var torch: TorchManager

    @State private var rate: Double = 8
    @State private var active = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Flash + buzz in sync") {
                    VStack(alignment: .leading) {
                        Text("Rate  \(Int(rate)) per second")
                        Slider(value: $rate, in: 1...30, step: 1)
                    }
                    Button {
                        if active {
                            haptics.stop()
                            torch.stopAll()
                            UIApplication.shared.isIdleTimerDisabled = false
                            active = false
                        } else {
                            UIApplication.shared.isIdleTimerDisabled = true
                            haptics.start(mode: .pulse, intensity: 1, sharpness: 1, rate: rate)
                            torch.startStrobe(hz: rate, unthrottled: false, level: 1)
                            active = true
                        }
                    } label: {
                        Text(active ? "Stop" : "Start")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(active ? .red : .accentColor)
                    Text("The haptic pulses and the torch run on separate clocks at the same rate, so they stay close but can drift slightly.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Combo")
            .onChange(of: rate) { _, new in
                guard active else { return }
                haptics.start(mode: .pulse, intensity: 1, sharpness: 1, rate: new)
                torch.updateStrobe(hz: new, unthrottled: false, level: 1)
            }
        }
    }
}
