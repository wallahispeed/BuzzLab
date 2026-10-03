# BuzzLab

iPhone app (iOS 17+) with full control over the Taptic Engine and the LED torch.

## Features

**Haptics**
- MAX POWER toggle: continuous haptic at 100% intensity and sharpness, on until switched off
- Modes: Continuous, Pulse (1 to 100 per second), Heartbeat, Ramp, Legacy buzz
- Live intensity and sharpness sliders, plus a single-tap button

**Flashlight**
- Steady torch with brightness slider
- Strobe with a speed slider (1 to 60 flashes/sec, log scale)
- Unthrottled mode: toggles as fast as the torch API returns, with a live measured rate
- Strobe brightness slider, SOS pattern

**Combo**
- Torch and haptic pulses at the same rate

## Getting an IPA

Run the "Build unsigned IPA" workflow in the Actions tab, download the `BuzzLab-ipa` artifact, and sideload `BuzzLab.ipa` with Sideloadly or AltStore (they sign it with your Apple ID).
A free Apple ID gives 7-day installs; a paid developer account gives a year.

On a Mac: `brew install xcodegen`, `xcodegen generate`, open `BuzzLab.xcodeproj`, set your Team under Signing & Capabilities, and run on your iPhone.

## Hardware notes

- Haptics only work on iPhone 8 and later; the iPad and Simulator have no Taptic Engine.
- A single continuous haptic event lasts at most 30 s, so the app loops it. The player keeps looping while the app is open.
- Intensity 100% is the strongest the Taptic Engine will play. iOS does not expose a stronger setting.
- The torch strobe rate is limited by the LED driver and the AVFoundation call latency. The "Measured" line shows what your phone really achieves.
- iOS shuts down haptics and the torch when the app goes to the background, so the app stops them automatically.
- Strobing at these rates can trigger seizures in photosensitive people. The app shows a warning on first launch.
