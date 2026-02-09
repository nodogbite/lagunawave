import Foundation

struct TranscriptionRecord: Codable {
    let id: UUID
    let text: String          // The text that was typed (cleaned if cleanup was on)
    let originalText: String? // Raw transcription before cleanup (nil if cleanup was off)
    let date: Date

    init(text: String, originalText: String? = nil, date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.originalText = originalText
        self.date = date
    }
}

@MainActor
final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    private let defaults = UserDefaults.standard
    private let key = "transcriptionHistory"
    private let maxItems = 50

    private(set) var records: [TranscriptionRecord] = []

    private init() {
        load()
    }

    func append(_ text: String, originalText: String? = nil) {
        let record = TranscriptionRecord(text: text, originalText: originalText)
        records.insert(record, at: 0)
        if records.count > maxItems {
            records = Array(records.prefix(maxItems))
        }
        save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }

    func delete(at index: Int) {
        guard records.indices.contains(index) else { return }
        records.remove(at: index)
        save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
        } catch {
            Log.general("TranscriptionHistory: failed to decode history: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: key)
        } catch {
            Log.general("TranscriptionHistory: failed to encode history: \(error.localizedDescription)")
        }
    }
}
