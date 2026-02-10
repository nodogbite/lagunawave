@preconcurrency import AVFoundation
import AudioToolbox
import QuartzCore

// @unchecked Sendable: all mutable state (samples, isRunning, converter,
// inputDeviceUID, lastLevelUpdate) is accessed only from `queue` or from
// the caller's serial context (start/stop are not called concurrently).
// Cannot use Mutex (requires macOS 15); DispatchQueue is the macOS 14 alternative.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var wantRunning = false
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samples = [Float]()
    private let queue = DispatchQueue(label: "lagunawave.audio.buffer")
    private var inputDeviceUID: String?
    private var lastLevelUpdate: CFTimeInterval = 0
    private var configObserver: Any?
    var onLevel: ((Float) -> Void)?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.recoverFromConfigurationChange() }
        }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setInputDevice(uid: String?) {
        inputDeviceUID = uid
    }

    func start() -> Bool {
        wantRunning = true
        if isRunning {
            Log.audio("AudioCapture start: already running")
            return true
        }
        Log.audio("AudioCapture start: starting engine")
        startEngine()
        Log.audio("AudioCapture start: engine started, isRunning=\(isRunning)")
        return isRunning
    }

    func stop() -> [Float] {
        wantRunning = false
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        let output = queue.sync { samples }
        queue.sync { samples.removeAll(keepingCapacity: true) }
        let duration = Double(output.count) / outputFormat.sampleRate
        Log.audio("AudioCapture stop: samples=\(output.count) duration=\(String(format: "%.2f", duration))s")
        if let onLevel = onLevel {
            DispatchQueue.main.async {
                onLevel(0)
            }
        }
        return output
    }

    private func startEngine() {
        guard !isRunning else { return }
        Log.audio("AudioCapture startEngine: getting input node")
        let input = engine.inputNode
        setAudioUnitDeviceIfNeeded(input)
        let format = input.outputFormat(forBus: 0)
        Log.audio("AudioCapture startEngine: inputRate=\(format.sampleRate) channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.audio("AudioCapture startEngine: degenerate format, aborting")
            return
        }
        converter = AVAudioConverter(from: format, to: outputFormat)
        queue.sync { samples.removeAll(keepingCapacity: true) }

        Log.audio("AudioCapture startEngine: installing tap")
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeTapHandler(format: format))
        do {
            engine.prepare()
            Log.audio("AudioCapture startEngine: engine prepared, starting")
            try engine.start()
            isRunning = true
            Log.audio("AudioCapture startEngine: engine running")
        } catch {
            isRunning = false
            Log.audio("AudioCapture startEngine failed: \(error.localizedDescription)")
        }
    }

    private func recoverFromConfigurationChange() {
        guard isRunning else {
            Log.audio("AudioCapture: config change ignored (not running)")
            return
        }
        Log.audio("AudioCapture: config change detected, stopping and restarting")

        // Full clean stop: remove tap and explicitly stop the engine so it's
        // in a known "user-stopped" state (not the internal "system-stopped"
        // state that causes installTap to crash).
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        // Restart after a short delay to let the audio hardware settle.
        // If stop() is called before this fires (e.g. push-to-talk released),
        // startEngine() will see isRunning == false from our stop above and
        // the subsequent stop() in audio.stop() will be a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard self.wantRunning else {
                Log.audio("AudioCapture: config change restart skipped (stop was called)")
                return
            }
            Log.audio("AudioCapture: config change restart firing")
            self.startEngine()
        }
    }

    private func makeTapHandler(format: AVAudioFormat) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }
            let ratio = self.outputFormat.sampleRate / format.sampleRate
            let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: outFrameCapacity) else { return }

            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            guard let channelData = outBuffer.floatChannelData else { return }
            let frameLength = Int(outBuffer.frameLength)
            let level = self.level(from: outBuffer)
            self.emitLevel(level)

            let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            self.queue.async {
                self.samples.append(contentsOf: chunk)
            }
        }
    }

    private func setAudioUnitDeviceIfNeeded(_ input: AVAudioInputNode) {
        guard let uid = inputDeviceUID else { return }
        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else {
            Log.audio("AudioCapture deviceID not found for uid=\(uid)")
            return
        }
        guard let audioUnit = input.audioUnit else {
            Log.audio("AudioCapture audioUnit unavailable")
            return
        }
        var deviceIDVar = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            Log.audio("AudioCapture using deviceID=\(deviceID)")
        } else {
            Log.audio("AudioCapture set device failed: \(status)")
        }
    }

    private func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        if frameLength == 0 { return 0 }
        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameLength {
            let v = samples[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(frameLength))
        if rms <= 0 { return 0 }
        let db = 20 * log10(rms)
        let normalized = (db + 50) / 50
        return min(1, max(0, normalized))
    }

    private func emitLevel(_ level: Float) {
        guard let onLevel = onLevel else { return }
        let now = CACurrentMediaTime()
        if now - lastLevelUpdate < 0.03 { return }
        lastLevelUpdate = now
        DispatchQueue.main.async {
            onLevel(level)
        }
    }
}
