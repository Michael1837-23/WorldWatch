import Foundation
import Translation

enum HeadlineTranslationError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "在线翻译暂不可用，请稍后重试" }
}

struct OnlineHeadlineResult: Sendable {
    let original: String
    let translated: String?
}

func translatePublicHeadline(_ title: String) async throws -> String {
    var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
    components.queryItems = ["client": "gtx", "sl": "en", "tl": "zh-CN", "dt": "t", "q": title].map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 10
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 12
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
          let object = try JSONSerialization.jsonObject(with: data) as? [Any],
          let segments = object.first as? [[Any]] else { throw HeadlineTranslationError.invalidResponse }
    let text = segments.compactMap { $0.first as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != title else { throw HeadlineTranslationError.invalidResponse }
    return text
}

func needsTitleTranslation(_ event: WorldEvent) -> Bool {
    event.sourceID != "bbc-zh" && !event.sourceID.hasPrefix("cns-") && NewsSource.find(event.sourceID)?.language != "zh" && event.translatedTitle == nil && event.title.range(of: "[a-zA-Z]{4}", options: .regularExpression) != nil
}

actor TitleTranslator {
    static let shared = TitleTranslator()
    private var translations: [String: String] = [:]
    private let file: URL
    private let source = Locale.Language(identifier: "en")
    private let target = Locale.Language(identifier: "zh-Hans")
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldWatch/translations.json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([String: String].self, from: data) { translations = cached }
    }
    func available() async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }
    func applyCache(to events: [WorldEvent]) -> [WorldEvent] {
        events.map { event in
            var result = event
            if needsTitleTranslation(event), let translated = translations[event.title] { result.translatedTitle = translated }
            return result
        }
    }
    func translate(_ events: [WorldEvent], session supplied: TranslationSession? = nil) async throws -> [WorldEvent] {
        let cached = applyCache(to: events)
        let pending = cached.filter(needsTitleTranslation)
        guard !pending.isEmpty else { return cached }
        if supplied == nil, !(await available()) {
            // Public headlines only; no screenshot, account information, or personal text is sent.
            for start in stride(from: 0, to: min(pending.count, 100), by: 4) {
                let batch = Array(pending[start..<min(start + 4, pending.count)])
                await withTaskGroup(of: OnlineHeadlineResult.self) { group in
                    for event in batch {
                        group.addTask { OnlineHeadlineResult(original: event.title, translated: try? await translatePublicHeadline(event.title)) }
                    }
                    for await result in group {
                        if let text = result.translated { translations[result.original] = text }
                    }
                }
                try save()
            }
            let translated = applyCache(to: events)
            if translated.contains(where: needsTitleTranslation) { throw HeadlineTranslationError.invalidResponse }
            return translated
        }
        let session = supplied ?? TranslationSession(installedSource: source, target: target)
        // Small batches keep widget work bounded; remaining headlines are translated on later refreshes.
        for batchStart in stride(from: 0, to: min(pending.count, 100), by: 10) {
            let batch = Array(pending[batchStart..<min(batchStart + 10, pending.count)])
            let responses = try await session.translations(from: batch.map { .init(sourceText: $0.title, clientIdentifier: $0.id) })
            for response in responses {
                let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translated.isEmpty { translations[response.sourceText] = translated }
            }
            // Preserve completed work even if a subsequent batch fails.
            try save()
        }
        return applyCache(to: events)
    }
    /// Drops translations for headlines no longer in any cached feed, so the cache file stays bounded.
    func prune(keeping titles: Set<String>, threshold: Int = retainedNewsLimit) {
        guard translations.count > threshold else { return }
        translations = translations.filter { titles.contains($0.key) }
        try? save()
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(translations).write(to: file, options: .atomic)
    }
}
