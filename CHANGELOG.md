# Changelog

## 0.2.6 - 2026-02-10
- Remove AVAudioEngine configuration change observer — the root cause of push-to-talk crashes on systems with virtual audio devices (e.g. Zoom).
- The observer was attempting to recover mid-recording device switches, an edge case not worth the instability it introduced.

## 0.2.5 - 2026-02-10
- Fix crash when Zoom virtual audio device triggers AVAudioEngine configuration change during recording.
- Explicitly stop engine before rebuilding after a config change to avoid `installTap` crash on system-stopped engine.
- Add `wantRunning` guard so a delayed config-change restart does not fire after the user has already stopped recording.

## 0.2.4 - 2026-02-10
- Fix crash on audio device configuration change during recording (e.g. Bluetooth/USB device negotiation).
- Play feedback sound before starting audio engine to avoid triggering a config change on sensitive hardware.
- Defensive recovery for AVAudioEngine configuration changes with detailed logging.

## 0.2.3 - 2026-02-10
- Added detailed logging around hotkey press, overlay show, and audio engine startup to diagnose push-to-talk crashes.
- Guard against degenerate audio format (0 Hz / 0 channels) during engine start that could cause a crash.

## 0.2.2 - 2026-02-10
- Fix crash when recording a hotkey that conflicts with an already-registered hotkey. Global hotkeys are now paused while the recorder is active.
- Duplicate hotkey detection: assigning the same key combo to both push-to-talk and toggle dictation now shows an error and reverts.

## 0.2.1 - 2026-02-10
- VDI targets now always use Simulate Keypresses regardless of the user's typing method setting (paste and Unicode injection do not work through VDI clients).

## 0.2.0 - 2026-02-09
- Faster typing speed presets: Fast 10ms, Natural 20ms, Relaxed 40ms (down from 15/35/65ms).
- Reduced sentence boundary pause from 150ms to 100ms.

## 0.1.9 - 2026-02-09
- Smarter VDI focus click: detect full-screen vs windowed mode to avoid clicking the macOS title bar.
- VDI click position adjusted to 65% across the window to better target the session area.
- Removed premature GitHub Releases download section from README.

## 0.1.6 - 2026-02-09
- Optional auto-Enter after typing: sends Return key after a short pause when dictation finishes (off by default).
- Menu bar quick toggles for AI text cleanup and auto-Enter.
- Escape-to-cancel: press Escape during simulated typing to stop mid-stream.
- Enhanced cleanup model option (Qwen3 30B MoE, ~18 GB) for higher-quality text correction.
- Overlay download progress with percentage when switching cleanup models.
- One-shot examples in cleanup LLM prompt to improve punctuation and capitalization preservation.
- Check accessibility permission before recording starts, with guided System Settings prompt.
- Typing moved to background thread to keep the main run loop responsive.

## 0.1.5 - 2026-02-08
- Show original and cleaned text in transcription history (toggle between versions).
- LLM text cleanup enabled by default.
- Download and load cleanup LLM at startup (removed manual download button).
- Improved startup with descriptive progress messages and parallel model downloads.
- Fix push-to-talk race condition on rapid press/release cycles.
- Removed redundant metallib signing and `--deep` codesign flag.
- Handle audio device changes during recording (headphones, AirPods, default input switching).
- Fix overlay dismiss/present race where the panel could vanish during a new recording.
- Log errors on transcription history encode/decode failure instead of silently discarding.

## 0.1.4 - 2026-02-08
- Microphone selection submenu in the menu bar for quick switching.
- `scripts/setup.sh` interactive bootstrap script for new contributors.
- Build script requires Metal Toolchain upfront (clearer error on missing prerequisites).
- Resilient Metal shader compilation (non-fatal; MLX falls back to JIT).

## 0.1.3 - 2026-02-08
- Tabbed settings layout with restore defaults.
- Optional AI text cleanup using on-device LLM (Qwen3).
- Speech model selection (Parakeet TDT v2 / v3).
- Push-to-talk trailing buffer to avoid clipping final words.
- VDI title-bar click for focus restore.
- Click-to-retype from transcription history.
- Updated README with model and post-processing documentation.

## 0.1.2 - 2026-02-07
- Initial public release.
- Push-to-talk and toggle dictation with configurable global hotkeys.
- On-device speech recognition using Parakeet TDT (FluidAudio + CoreML).
- Floating overlay HUD with waveform animation and contextual hotkey hints.
- Three typing methods: simulated typing, virtual keypresses, and clipboard paste.
- Adjustable typing speed (Instant / Fast / Natural / Relaxed).
- Microphone selection.
- VDI/remote desktop detection with automatic keypress mode switching.
- Transcription history (last 50 entries).
- Audio and haptic feedback toggles.
- Build, run, install, and notarize scripts.
- Signed and notarized for Gatekeeper-clean distribution.
