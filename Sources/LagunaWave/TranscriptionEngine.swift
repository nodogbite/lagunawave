import Foundation
import FluidAudio

actor TranscriptionEngine {
    private var manager: AsrManager?
    private var loadedVersion: AsrModelVersion?
    private var loadingTask: Task<Void, Error>?

    func isReady() -> Bool {
        return manager != nil
    }

    private func selectedVersion() -> AsrModelVersion {
        // Preferences is @MainActor, but we only read a UserDefaults string
        let versionString = UserDefaults.standard.string(forKey: "asrModelVersion") ?? "v2"
        return versionString == "v3" ? .v3 : .v2
    }

    func downloadAll() async throws {
        Log.shared.write("TranscriptionEngine: downloading v2 model")
        try await AsrModels.download(version: .v2)
        Log.shared.write("TranscriptionEngine: downloading v3 model")
        try await AsrModels.download(version: .v3)
        Log.shared.write("TranscriptionEngine: both models downloaded")
    }

    func prepare() async throws {
        let version = selectedVersion()
        if manager != nil, loadedVersion == version {
            return
        }
        // Different version selected — tear down current
        if manager != nil, loadedVersion != version {
            manager = nil
            loadedVersion = nil
            loadingTask = nil
        }
        if let task = loadingTask {
            try await task.value
            return
        }

        let task = Task {
            let start = Date()
            Log.shared.write("TranscriptionEngine: loading model \(version == .v2 ? "v2" : "v3")")
            let models = try await AsrModels.downloadAndLoad(version: version)
            let mgr = AsrManager(config: .default)
            try await mgr.initialize(models: models)
            manager = mgr
            loadedVersion = version
            let elapsed = Date().timeIntervalSince(start)
            Log.shared.write("TranscriptionEngine: model ready (\(String(format: "%.2f", elapsed))s)")
        }
        loadingTask = task
        do {
            try await task.value
        } catch {
            loadingTask = nil
            throw error
        }
        loadingTask = nil
    }

    func reloadModel() async throws {
        manager = nil
        loadedVersion = nil
        loadingTask = nil
        try await prepare()
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await prepare()
        guard let manager = manager else { return "" }
        Log.shared.write("TranscriptionEngine: transcribing \(samples.count) samples")
        let result = try await manager.transcribe(samples, source: .microphone)
        return result.text
    }
}
