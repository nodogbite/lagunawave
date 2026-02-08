# LagunaWave

Local, on-device dictation for macOS that turns speech into simulated keystrokes.

## Download
- Grab the latest notarized build from GitHub Releases: [Latest Release](https://github.com/gharfst/lagunawave/releases/latest)
- Drag `LagunaWave.app` into `/Applications`
- On first run, LagunaWave walks you through **Accessibility** and **Microphone** permissions one at a time, then downloads the speech model

## Quick Start (from source)
1. Check prerequisites: `scripts/setup.sh` (installs Xcode CLI Tools and Metal Toolchain if missing)
2. Build: `scripts/build.sh`
3. Run: `scripts/run.sh`

## Hotkeys (Default)
- Push‑to‑talk: **Control + Option + Space** — hold to speak, release to type
- Toggle dictation: **Control + Option + Shift + Space** — press to start, press again to stop
- **Escape** cancels toggle dictation without transcribing

Both hotkeys are configurable in Settings.

## Settings
- **Microphone selection** — choose which input device to use
- **Hotkey configuration** — push‑to‑talk and toggle dictation hotkeys
- **Typing method** — choose how transcribed text is delivered to the target app:
  - *Simulate Typing* — types characters via Unicode injection. Works in most native macOS apps.
  - *Simulate Keypresses* — types via virtual key codes (US QWERTY). Works in VDI clients and remote desktops (Citrix, VMware Horizon, Microsoft Remote Desktop, etc.).
  - *Paste* — pastes via clipboard (Cmd+V). Fastest option; clipboard is saved and restored automatically.
- **Typing speed** — controls inter-keystroke delay (Instant / Fast / Natural / Relaxed). Applies to Simulate Typing and Simulate Keypresses modes.
- **VDI app keywords** — comma-separated keywords to identify VDI/remote desktop apps (e.g., vmware, citrix, horizon). When a VDI app is focused, LagunaWave automatically switches to Simulate Keypresses. After typing, it clicks the VDI window's title bar to restore keyboard focus, since VDI clients typically lose focus after receiving simulated keystrokes.
- **Feedback** — optional audio and haptic cues on start/stop

## Permissions
- **Microphone:** required for audio capture.
- **Accessibility:** required to inject keystrokes. Enable in **System Settings → Privacy & Security → Accessibility**.

If macOS says the app is “damaged or incomplete,” rebuild to apply an ad‑hoc signature and try again. If it still blocks, run:
`xattr -dr com.apple.quarantine build/LagunaWave.app`

## Speech Recognition Models
LagunaWave ships with two NVIDIA Parakeet TDT models, selectable in **Settings → Models**:

| Model | Languages | Size | Notes |
|-------|-----------|------|-------|
| **Parakeet TDT v2** (default) | English only | ~2.5 GB | Higher accuracy for English-only use |
| **Parakeet TDT v3** | 25 languages | ~2.5 GB | Multilingual support; slightly lower English accuracy |

The selected model is downloaded automatically on first use. Switching models downloads the new one if needed.

## Text Cleanup (Post-Processing)
LagunaWave can optionally run transcribed text through a local LLM to fix common speech-to-text errors before typing it out. The cleanup corrects:
- Punctuation and capitalization
- Filler words (um, uh, like, you know, etc.)
- Common homophones (there/their/they're, your/you're, its/it's, etc.)

All processing happens on-device — no data leaves your Mac.

### Enabling text cleanup
1. Open **Settings → Models**.
2. Check **"Clean up dictated text with AI"**.
3. Choose a cleanup model size:
   - **Standard** (Qwen3 4B, ~2.5 GB) — better accuracy
   - **Lightweight** (Qwen3 1.7B, ~1.3 GB) — faster, smaller download
4. Click **Download Model** and wait for the download to complete.

Once enabled, cleanup runs automatically after each transcription. If the cleanup model isn't downloaded yet, LagunaWave falls back to the raw transcription.

## Signing & Distribution
For a smooth user experience (no Gatekeeper warnings), sign with a **Developer ID Application** certificate and notarize.

1. Create a Developer ID certificate in Xcode: **Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application**.
2. Find your signing identity:
   `security find-identity -p codesigning -v`
3. Build with that identity:
   `CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh`
4. Install into `/Applications` (stable path helps Accessibility permissions stick):
   `scripts/install.sh`

### Notarization (recommended for public releases)
1. Create an app-specific password: <https://appleid.apple.com/>
2. Store credentials in the keychain (recommended):
   `xcrun notarytool store-credentials "lagunawave-notary" --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"`
3. Notarize and staple:
   `CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARYTOOL_PROFILE="lagunawave-notary" scripts/notarize.sh`

The notarized zip will be at `build/LagunaWave.zip`.

## Release Checklist (Best Practice)
1. Bump version: `scripts/bump_version.sh 0.1.2`
2. Build + notarize: `CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARYTOOL_PROFILE="lagunawave-notary" scripts/release.sh`
3. Upload `build/LagunaWave.zip` and `build/LagunaWave.sha256` to GitHub Releases.
4. Update `CHANGELOG.md`.

## Architecture
- `AudioCapture` (AVAudioEngine) collects mic audio and resamples to 16 kHz mono.
- `TranscriptionEngine` (FluidAudio + CoreML) performs local ASR with Parakeet TDT v2 or v3.
- `TextCleanupEngine` (MLXLLM) optionally cleans up transcribed text using an on-device LLM.
- `HotKeyManager` (Carbon) handles global hotkeys.
- `OverlayPanel` renders a non‑activating floating HUD with branding, status, and contextual hotkey hints.
- `TextTyper` delivers text via CGEvent Unicode injection, virtual keycode simulation, or clipboard paste.
- `TranscriptionHistory` persists the last 50 transcriptions for review and retype.

## Roadmap
- Add engine abstraction for multiple local STT backends
- On‑device punctuation & formatting options

## License
MIT

## Model License
Parakeet TDT v3 model weights are provided by NVIDIA under CC BY 4.0. See the model card for details.
