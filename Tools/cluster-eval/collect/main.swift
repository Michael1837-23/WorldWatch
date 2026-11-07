import Foundation
import Translation

// Collects every headline the app's news sources currently publish (no 100-item cap, 3-day window),
// translates English titles to Chinese and back-translates Chinese titles to English with Apple's
// on-device Translation, and writes a corpus for Tools/cluster-eval. Built with the app's Sources/.

struct CorpusItem: Codable {
    let id: String
    let source: String
    let outlet: String
    let lang: String
    let title: String
    var zh: String?
    var en: String?
    let date: Date?
    let url: String
}

/// Feeds of one newsroom count as one outlet (BBC World and BBC Business are not independent coverage).
func outlet(of source: String) -> String {
    for prefix in ["bbc", "guardian", "cns"] where source.hasPrefix(prefix) { return prefix }
    return source
}

func translateAll(_ texts: [(id: Int, text: String)], from source: String, to target: String) async -> [Int: String] {
    let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
    let status = await LanguageAvailability().status(from: from, to: to)
    print("Apple translation \(source) → \(target): \(status)")
    guard status == .installed else { return [:] }
    let session = TranslationSession(installedSource: from, target: to)
    var result: [Int: String] = [:]
    for start in stride(from: 0, to: texts.count, by: 20) {
        let batch = texts[start..<min(start + 20, texts.count)]
        do {
            let responses = try await session.translations(from: batch.map { .init(sourceText: $0.text, clientIdentifier: String($0.id)) })
            for response in responses {
                if let id = response.clientIdentifier.flatMap(Int.init) { result[id] = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        } catch { print("translation batch \(start) failed: \(error)") }
    }
    return result
}

@main struct Collect {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { print("usage: collect <out.json>"); return }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var events: [WorldEvent] = []
        await withTaskGroup(of: (String, Result<[WorldEvent], Error>).self) { group in
            for source in NewsSource.all where !source.disaster {
                group.addTask {
                    do { return (source.id, .success(try await fetchSource(source))) } catch { return (source.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let items): print("\(id): \(items.count)"); events += items
                case .failure(let error): print("\(id): ERROR \(error)")
                }
            }
        }
        let merged = mergedEvents(events)
        var items = merged.map { event -> CorpusItem in
            let source = NewsSource.all.first { $0.id == event.sourceID }
            let chinese = event.sourceID == "bbc-zh" || event.sourceID.hasPrefix("cns-") || source?.language == "zh"
            return CorpusItem(id: event.id, source: event.sourceID, outlet: outlet(of: event.sourceID), lang: chinese ? "zh" : "en",
                              title: event.title, zh: chinese ? event.title : nil, en: nil, date: event.date, url: event.url.absoluteString)
        }
        let english = items.indices.filter { items[$0].lang == "en" }.map { ($0, items[$0].title) }
        for (i, text) in await translateAll(english, from: "en", to: "zh-Hans") { items[i].zh = text }
        let chinese = items.indices.filter { items[$0].lang == "zh" }.map { i in
            (i, items[i].title.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? items[i].title)
        }
        for (i, text) in await translateAll(chinese, from: "zh-Hans", to: "en") { items[i].en = text }
        print("items: \(items.count), English without Chinese: \(items.filter { $0.zh == nil }.count), Chinese without English: \(items.filter { $0.lang == "zh" && $0.en == nil }.count)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: output, options: .atomic)
        print("wrote \(output.path)")
    }
}
