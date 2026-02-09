# Changelog

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
