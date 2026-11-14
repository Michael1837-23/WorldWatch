import Foundation
import NaturalLanguage

// Hot-story engine: groups headlines from different outlets that report the same event, then scores heat.
// Method and parameters come from docs/evaluation/热点聚类评测.md (single-pass story centroids over
// IDF-weighted Chinese bigrams + English words); Tools/cluster-eval holds the reference implementation.

let storyWindow: TimeInterval = 72 * 3600
let storyIndexLimit = 2000
/// Followed-topic headlines (topic searches, 新浪 7×24, alias hits) have their own allowance on top of the general cap,
/// so a busy news day cannot push them out of the 72-hour window.
let storyIndexFollowLimit = 4000
let storyThreshold = 0.28
let storyAnchorBonus = 0.10
let storyAgePenalty = 0.10
/// Without a shared rare country or name, wording alone must be much closer: generic phrases
/// ("rising costs", "in talks to buy") otherwise chain unrelated stories across outlets.
let storyUnanchoredThreshold = 0.40

// MARK: - Outlets

/// Feeds of one newsroom count once; aggregator items count as their publisher. Disaster feeds have no outlet.
func storyOutlet(_ event: WorldEvent) -> String? {
    if event.disaster { return nil }
    if let publisher = event.publisher?.trimmingCharacters(in: .whitespaces), !publisher.isEmpty {
        let name = publisher.lowercased()
        let known: [(String, [String])] = [
            ("bbc", ["bbc"]), ("guardian", ["guardian", "卫报"]), ("cns", ["中国新闻网", "中新网", "chinanews"]),
            ("nyt", ["new york times", "纽约时报"]), ("aljazeera", ["al jazeera", "半岛"]), ("dw", ["deutsche welle", "德国之声"]),
            ("france24", ["france 24", "france24"]), ("npr", ["npr"]), ("cnbc", ["cnbc"]), ("techcrunch", ["techcrunch"]),
            ("variety", ["variety"]), ("cna", ["中央社", "中央通讯社", "中央通訊社"]), ("un", ["un news", "联合国新闻"]), ("defense", ["defense news"])
        ]
        if name == "dw" { return "dw" }
        return known.first { $0.1.contains(where: name.contains) }?.0 ?? "pub:" + name
    }
    for prefix in ["bbc", "guardian", "cns"] where event.sourceID.hasPrefix(prefix) { return prefix }
    return event.sourceID
}

private let outletNames = ["bbc": "BBC", "guardian": "卫报", "cns": "中新网", "nyt": "纽约时报", "aljazeera": "半岛电视台", "dw": "德国之声",
                           "france24": "法国24台", "npr": "NPR", "cnbc": "CNBC", "techcrunch": "TechCrunch", "variety": "Variety",
                           "cna": "中央社", "un": "联合国新闻", "defense": "Defense News"]

func outletDisplayName(_ key: String, sample: WorldEvent) -> String {
    outletNames[key] ?? sample.publisher ?? sample.sourceName
}

func isChineseSource(_ sourceID: String) -> Bool {
    sourceID == "bbc-zh" || sourceID.hasPrefix("cns-") || NewsSource.find(sourceID)?.language == "zh"
}

// MARK: - Features (ported from Tools/cluster-eval/main.swift; keep in sync with the evaluation)

let storyCountryAliases: [String: [String]] = [
    "US": ["US", "U.S.", "USA", "America", "American", "Americans", "Washington", "Pentagon", "White House", "美方", "白宫", "白宮", "五角大楼", "华盛顿"],
    "GB": ["UK", "Britain", "British", "London", "英方", "伦敦", "倫敦"],
    "RU": ["Russia", "Russian", "Russians", "Moscow", "Kremlin", "俄方", "莫斯科", "克里姆林宫"],
    "UA": ["Ukraine", "Ukrainian", "Ukrainians", "Kyiv", "Kharkiv", "Odesa", "Zaporizhzhia", "乌方", "基辅", "哈尔科夫", "敖德萨"],
    "IL": ["Israel", "Israeli", "Israelis", "Jerusalem", "Tel Aviv", "以方", "耶路撒冷", "特拉维夫"],
    "IR": ["Iran", "Iranian", "Iranians", "Tehran", "德黑兰"],
    "PS": ["Gaza", "West Bank", "Palestinian", "Palestinians", "Palestine", "巴勒斯坦", "加沙", "约旦河西岸"],
    "CN": ["China", "Chinese", "Beijing", "中方", "北京"],
    "HK": ["Hong Kong", "香港"], "MO": ["Macau", "Macao", "澳门"],
    "TW": ["Taiwan", "Taiwanese", "Taipei", "台北", "臺灣"],
    "JP": ["Japan", "Japanese", "Tokyo", "日方", "东京", "東京"],
    "KR": ["South Korea", "South Korean", "Seoul", "韩方", "首尔"], "KP": ["North Korea", "North Korean", "Pyongyang", "朝鲜", "平壤"],
    "IN": ["India", "Indian", "New Delhi", "Delhi", "新德里"], "PK": ["Pakistan", "Pakistani", "Islamabad"],
    "FR": ["France", "French", "Paris", "巴黎"], "DE": ["Germany", "German", "Berlin", "柏林"],
    "SY": ["Syria", "Syrian", "Damascus", "大马士革"], "LB": ["Lebanon", "Lebanese", "Beirut", "贝鲁特"],
    "SA": ["Saudi", "Saudi Arabia", "Riyadh", "沙特"], "TR": ["Turkey", "Turkish", "Türkiye", "Ankara", "安卡拉"],
    "VE": ["Venezuela", "Venezuelan", "Caracas", "加拉加斯"], "MX": ["Mexico", "Mexican", "墨西哥城"],
    "CA": ["Canada", "Canadian", "Canadians", "Ottawa", "渥太华"], "AU": ["Australia", "Australian", "Sydney", "Melbourne", "悉尼", "墨尔本"],
    "BR": ["Brazil", "Brazilian"], "PY": ["Paraguay", "Paraguayan", "Asuncion", "Asunción", "亚松森"],
    "EG": ["Egypt", "Egyptian", "Cairo", "开罗"], "SD": ["Sudan", "Sudanese", "Khartoum", "Darfur", "El Fasher", "喀土穆", "达尔富尔"],
    "AF": ["Afghanistan", "Afghan", "Kabul", "喀布尔"], "IQ": ["Iraq", "Iraqi", "Baghdad", "巴格达"],
    "YE": ["Yemen", "Yemeni", "Houthi", "Houthis", "胡塞"], "MM": ["Myanmar", "Burma", "缅甸"],
    "CD": ["DR Congo", "DRC", "Congo", "刚果（金）", "刚果民主共和国"], "NG": ["Nigeria", "Nigerian"],
    "ZA": ["South Africa", "South African"], "PH": ["Philippines", "Philippine", "Filipino", "Manila", "马尼拉"],
    "ID": ["Indonesia", "Indonesian", "Jakarta", "雅加达"], "VN": ["Vietnam", "Vietnamese", "Hanoi", "河内"],
    "TH": ["Thailand", "Thai", "Bangkok", "曼谷"], "IT": ["Italy", "Italian", "Rome", "罗马"], "ES": ["Spain", "Spanish", "Madrid", "马德里"],
    "PL": ["Poland", "Polish", "Warsaw", "华沙"], "NL": ["Netherlands", "Dutch"], "CU": ["Cuba", "Cuban", "Havana", "哈瓦那"],
    "EU": ["EU", "European Union", "Brussels", "欧盟", "布鲁塞尔"]
]

struct StoryGazetteer: @unchecked Sendable {
    static let shared = StoryGazetteer()
    private var ascii: [(code: String, regex: NSRegularExpression)] = []
    private var cjk: [(code: String, names: [String])] = []
    private init() {
        var names: [String: Set<String>] = [:]
        let en = Locale(identifier: "en"), hans = Locale(identifier: "zh-Hans"), hant = Locale(identifier: "zh-Hant")
        for region in Locale.Region.isoRegions where region.identifier.count == 2 && region.identifier.allSatisfy(\.isLetter) {
            let code = region.identifier
            for locale in [en, hans, hant] {
                guard var name = locale.localizedString(forRegionCode: code) else { continue }
                if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]).trimmingCharacters(in: .whitespaces) }
                if name.count >= 2 { names[code, default: []].insert(name) }
            }
        }
        for (code, aliases) in storyCountryAliases { names[code, default: []].formUnion(aliases) }
        for code in names.keys.sorted() {
            let set = names[code]!
            let asciiNames = set.filter { $0.allSatisfy(\.isASCII) }
            let cjkNames = set.filter { !$0.allSatisfy(\.isASCII) }.sorted()
            if !asciiNames.isEmpty {
                let patterns = asciiNames.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.map { name -> String in
                    let escaped = NSRegularExpression.escapedPattern(for: name)
                    // Short all-caps names (US, UK, EU, DRC) match case-sensitively; "us" is a pronoun.
                    if name.count <= 4, name == name.uppercased() { return "(?<![A-Za-z])" + escaped + "(?![A-Za-z])" }
                    return "(?i:(?<![A-Za-z])" + escaped + "(?![A-Za-z]))"
                }
                if let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|")) { ascii.append((code, regex)) }
            }
            if !cjkNames.isEmpty { cjk.append((code, cjkNames)) }
        }
    }
    func countries(in text: String) -> Set<String> {
        var found = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for (code, regex) in ascii where regex.firstMatch(in: text, range: range) != nil { found.insert(code) }
        for (code, names) in cjk where names.contains(where: text.contains) { found.insert(code) }
        // 印度 is a substring of 印度尼西亚.
        if found.contains("ID"), !text.contains("India"), text.contains("印度尼西亚"), !text.replacingOccurrences(of: "印度尼西亚", with: "").contains("印度") { found.remove("IN") }
        return found
    }
}

private let storyStopwords: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "with", "at", "by", "from", "as", "is", "are", "was", "were", "be", "been", "it", "its", "after", "over", "into", "about", "amid", "says", "said", "say", "new", "will", "has", "have", "had", "not", "but", "this", "that", "his", "her", "their", "they", "he", "she", "who", "what", "how", "why", "more", "than", "up", "out", "can", "could", "would", "should", "may", "us"]

/// Column tags and format boilerplate say nothing about the event ("学习贯彻…丨", "（第九届进博会）", "– as it happened").
private let storyBoilerplate: [NSRegularExpression] = [
    #"^[^丨｜|]{2,24}[丨｜|]"#, #"^（[^）]{2,20}）"#, #"^【[^】]{2,20}】"#, #"^(通讯|快讯|独家|视频|直播)[：:]"#,
    #"(?i)\s*[-–—]\s*(as it happened|live|the latest)$"#, #"(?i)^(watch|live|explainer|analysis|opinion)\s*:\s*"#,
    #"(?i)\s*[-–—|]\s*stateside with .*$"#, #"(?i)\breview\s*[-–—]"#
].map { try! NSRegularExpression(pattern: $0) }

func stripStoryBoilerplate(_ title: String) -> String {
    var text = title
    for regex in storyBoilerplate { text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") }
    return text.trimmingCharacters(in: .whitespaces)
}

func storyBigrams(_ text: String) -> Set<String> {
    let chars = Array(text.lowercased())
    var grams = Set<String>()
    func usable(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    for i in 0..<max(chars.count - 1, 0) where usable(chars[i]) && usable(chars[i + 1]) {
        if chars[i].isASCII && chars[i + 1].isASCII && chars[i].isLetter { continue }
        if chars[i].isNumber && chars[i + 1].isNumber { continue }   // "2027", "200年" are not event-specific
        grams.insert(String(chars[i...i + 1]))
    }
    return grams
}

func storyWords(_ text: String) -> Set<String> {
    var words = Set<String>()
    let lower = text.lowercased()
    lower.enumerateSubstrings(in: lower.startIndex..<lower.endIndex, options: .byWords) { word, _, _, _ in
        guard var word, word.count >= 3, !storyStopwords.contains(word), !word.allSatisfy(\.isNumber) else { return }
        if word.hasSuffix("'s") || word.hasSuffix("’s") { word.removeLast(2) }
        if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
        words.insert(word)
    }
    return words
}

func storyNames(_ text: String, _ language: NLLanguage) -> Set<String> {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
    var names = Set<String>()
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
        if let tag, [.personalName, .organizationName, .placeName].contains(tag) {
            var name = String(text[range]).lowercased()
            if name.hasSuffix("'s") || name.hasSuffix("’s") { name.removeLast(2) }
            if name.count >= 2 { names.insert(name) }
        }
        return true
    }
    return names
}

struct StoryFeatures: Sendable {
    var grams: Set<String> = []
    var words: Set<String> = []
    var countries: Set<String> = []
    var names: Set<String> = []
    var personNames: Set<String> = []   // personal names found in the Chinese text, for the "飙升" line
}

/// One headline in the 72-hour index. `english` is Apple's back-translation of a Chinese-language title.
struct StoryEntry: Codable, Sendable {
    var event: WorldEvent
    var observedAt: Date
    var english: String? = nil
    var chineseText: String? { event.translatedTitle ?? (isChineseSource(event.sourceID) ? event.title : nil) }
    var englishText: String? { isChineseSource(event.sourceID) ? english : event.title }
}

func storyFeatures(_ entry: StoryEntry) -> StoryFeatures {
    var f = StoryFeatures()
    let zh = entry.chineseText ?? entry.event.title
    f.countries = StoryGazetteer.shared.countries(in: entry.event.title).union(StoryGazetteer.shared.countries(in: zh))
    f.names = storyNames(zh, .simplifiedChinese)
    f.personNames = personNames(zh)
    f.grams = storyBigrams(stripStoryBoilerplate(zh))
    if let english = entry.englishText {
        f.names.formUnion(storyNames(english, .english))
        f.words = storyWords(stripStoryBoilerplate(english))
    }
    return f
}

private func personNames(_ text: String) -> Set<String> {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
    var names = Set<String>()
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
        if tag == .personalName, text[range].count >= 2 { names.insert(String(text[range])) }
        return true
    }
    return names
}

/// Features are cached per id and text, so re-clustering every refresh only tags new or re-translated headlines.
final class StoryFeatureCache: @unchecked Sendable {
    private var cache: [String: (key: String, features: StoryFeatures)] = [:]
    private let lock = NSLock()
    func features(_ entry: StoryEntry) -> StoryFeatures {
        let key = (entry.chineseText ?? "") + "\u{1}" + (entry.englishText ?? "") + "\u{1}" + entry.event.title
        lock.lock(); let hit = cache[entry.event.id]; lock.unlock()
        if let hit, hit.key == key { return hit.features }
        let features = storyFeatures(entry)
        lock.lock(); cache[entry.event.id] = (key, features); lock.unlock()
        return features
    }
    func retain(_ ids: Set<String>) {
        lock.lock(); cache = cache.filter { ids.contains($0.key) }; lock.unlock()
    }
}

// MARK: - Clustering

struct NewsStory: Codable, Sendable, Equatable {
    var id: String
    var memberIDs: [String]
    var outlets: [String]          // display names, ordered by first report
    var heat: Double
    var leadID: String
    var latestID: String
    var firstDate: Date?
    var lastDate: Date?
    var firstObserved: Date
    var breakingUntil: Date?
}

struct StoryResult: Sendable {
    var stories: [NewsStory] = []           // every story, multi-outlet first by heat
    var storyOf: [String: Int] = [:]        // event id -> index into stories
    var surging: [String] = []              // up to five rising country / person names
    var events: [String: WorldEvent] = [:]  // every indexed headline, for member lists and story leads
    var terms: [String: Set<String>] = [:]  // headline id -> its bigrams ("z…") and English words ("e…"), for joining rows
    func story(for eventID: String) -> NewsStory? { storyOf[eventID].map { stories[$0] } }
}

/// A headline's clustering features as one set: Chinese bigrams prefixed "z", English words (the original, or the
/// back-translation of a Chinese title) prefixed "e".
func storyTerms(_ features: StoryFeatures) -> Set<String> {
    Set(features.grams.map { "z" + $0 }).union(features.words.map { "e" + $0 })
}

private func storyNormalizedTitle(_ title: String) -> String {
    title.lowercased().replacingOccurrences(of: "｜", with: "|").replacingOccurrences(of: "丨", with: "|")
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

private func idf<T: Hashable>(_ sets: [Set<T>]) -> [T: Double] {
    var df: [T: Int] = [:]
    for set in sets { for token in set { df[token, default: 0] += 1 } }
    let n = Double(sets.count)
    return df.mapValues { log(n / Double($0)) }
}

private func dateOnlySource(_ sourceID: String) -> Bool { NewsSource.find(sourceID)?.dateOnly ?? false }

/// Groups the index into stories. Pure and deterministic: same entries and `now` give the same result.
func buildStories(_ entries: [StoryEntry], now: Date = Date(), cache: StoryFeatureCache? = nil) -> StoryResult {
    let items = entries.filter { !$0.event.disaster }.sorted { $0.event.id < $1.event.id }
    var result = StoryResult()
    for entry in entries { result.events[entry.event.id] = entry.event }
    guard !items.isEmpty else { return result }
    // Identical titles or links are one unit (the app already shows them once).
    var unitOf = [Int](repeating: -1, count: items.count)
    var units: [[Int]] = []
    var byTitle: [String: Int] = [:], byURL: [String: Int] = [:]
    for (i, entry) in items.enumerated() {
        let title = storyNormalizedTitle(entry.event.title), url = canonicalNewsURL(entry.event.url)
        if let u = byTitle[title] ?? byURL[url] { unitOf[i] = u; units[u].append(i) }
        else { unitOf[i] = units.count; units.append([i]) }
        byTitle[title] = byTitle[title] ?? unitOf[i]; byURL[url] = byURL[url] ?? unitOf[i]
    }
    // IDF counts every headline (duplicates included), as the evaluation did.
    let itemFeatures = items.map { cache?.features($0) ?? storyFeatures($0) }
    for (i, entry) in items.enumerated() { result.terms[entry.event.id] = storyTerms(itemFeatures[i]) }
    let features = units.map { itemFeatures[$0[0]] }
    let gramIDF = idf(itemFeatures.map(\.grams)), wordIDF = idf(itemFeatures.map(\.words))
    let countryIDF = idf(itemFeatures.map(\.countries)), nameIDF = idf(itemFeatures.map(\.names))
    let vectors: [[String: Double]] = features.map { f in
        var v: [String: Double] = [:]
        for g in f.grams { v["z" + g] = gramIDF[g] ?? 0 }
        for w in f.words { v["e" + w] = wordIDF[w] ?? 0 }
        let norm = sqrt(v.keys.sorted().reduce(0) { $0 + v[$1]! * v[$1]! })
        return norm > 0 ? v.mapValues { $0 / norm } : v
    }
    func unitDate(_ u: Int) -> Date? { units[u].compactMap { items[$0].event.date }.min() }
    let order = units.indices.sorted {
        let a = unitDate($0) ?? .distantFuture, b = unitDate($1) ?? .distantFuture
        return a != b ? a < b : items[units[$0][0]].event.id < items[units[$1][0]].event.id
    }
    struct Cluster { var centroid: [String: Double] = [:]; var normSq = 0.0; var countries = Set<String>(); var names = Set<String>(); var last = Date.distantPast; var units: [Int] = [] }
    var clusters: [Cluster] = []
    var postings: [String: [Int]] = [:]
    for u in order {
        let v = vectors[u], keys = v.keys.sorted()
        let date = unitDate(u) ?? now
        let countries = features[u].countries.filter { (countryIDF[$0] ?? 0) >= 2.0 }
        let names = features[u].names.filter { (nameIDF[$0] ?? 0) >= 2.5 }
        var candidates = Set<Int>()
        for k in keys { candidates.formUnion(postings[k] ?? []) }
        var best = -1, bestScore = -Double.infinity, bestDot = 0.0
        for c in candidates.sorted() {
            let cluster = clusters[c]
            guard cluster.normSq > 0 else { continue }
            var dot = 0.0
            for k in keys { if let y = cluster.centroid[k] { dot += v[k]! * y } }
            var score = dot / sqrt(cluster.normSq)
            let anchored = !countries.isDisjoint(with: cluster.countries) || !names.isDisjoint(with: cluster.names)
            if anchored { score += storyAnchorBonus }
            if date.timeIntervalSince(cluster.last) > 36 * 3600 { score -= storyAgePenalty }
            if !anchored, score < storyUnanchoredThreshold { continue }
            if score > bestScore { bestScore = score; best = c; bestDot = dot }
        }
        let target: Int
        if best >= 0, bestScore >= storyThreshold { target = best }
        else { target = clusters.count; clusters.append(Cluster()); bestDot = 0 }
        var cluster = clusters[target]
        let selfSq = keys.reduce(0) { $0 + v[$1]! * v[$1]! }
        cluster.normSq += 2 * bestDot + selfSq
        for k in keys {
            if cluster.centroid[k] == nil { postings[k, default: []].append(target) }
            cluster.centroid[k, default: 0] += v[k]!
        }
        cluster.countries.formUnion(countries); cluster.names.formUnion(names)
        cluster.last = max(cluster.last, date); cluster.units.append(u)
        clusters[target] = cluster
    }
    // Stories: outlets, heat, breaking, lead.
    var stories: [NewsStory] = []
    for cluster in clusters {
        let members = cluster.units.flatMap { units[$0] }.map { items[$0] }
        var firstByOutlet: [String: (date: Date?, event: WorldEvent)] = [:]
        for entry in members {
            guard let outlet = storyOutlet(entry.event) else { continue }
            let date = dateOnlySource(entry.event.sourceID) ? nil : entry.event.date
            if let known = firstByOutlet[outlet], (known.date ?? .distantFuture) <= (date ?? .distantFuture) { continue }
            firstByOutlet[outlet] = (date, entry.event)
        }
        let outletOrder = firstByOutlet.sorted { ($0.value.date ?? .distantFuture, $0.key) < ($1.value.date ?? .distantFuture, $1.key) }
        let timed = members.filter { !dateOnlySource($0.event.sourceID) }.compactMap(\.event.date)
        let last = timed.max(), first = timed.min()
        let recent = outletOrder.filter { ($0.value.date ?? .distantPast) > now.addingTimeInterval(-2 * 3600) }.count
        let decay = last.map { pow(0.5, max(0, now.timeIntervalSince($0)) / 3600 / 6) } ?? 0
        var breaking: Date? = nil
        let firstTimes = outletOrder.compactMap(\.value.date)
        if firstTimes.count >= 3, firstTimes[2].timeIntervalSince(firstTimes[0]) <= 3600, now.timeIntervalSince(firstTimes[0]) <= 6 * 3600 {
            breaking = firstTimes[2].addingTimeInterval(3 * 3600)
        }
        // Lead: the member closest to the centroid; a Chinese-language member within 0.05 is preferred.
        let norm = sqrt(cluster.normSq)
        func closeness(_ u: Int) -> Double {
            guard norm > 0 else { return 0 }
            return vectors[u].keys.sorted().reduce(0) { $0 + vectors[u][$1]! * (cluster.centroid[$1] ?? 0) } / norm
        }
        let ranked = cluster.units.map { ($0, closeness($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : items[units[$0.0][0]].event.id < items[units[$1.0][0]].event.id }
        var lead = ranked[0].0
        if let chinese = ranked.first(where: { isChineseSource(items[units[$0.0][0]].event.sourceID) }), chinese.1 >= ranked[0].1 - 0.05 { lead = chinese.0 }
        let latest = members.max { ($0.event.date ?? .distantPast, $1.event.id) < ($1.event.date ?? .distantPast, $0.event.id) }!
        let earliest = members.min { ($0.event.date ?? .distantFuture, $0.event.id) < ($1.event.date ?? .distantFuture, $1.event.id) }!
        stories.append(NewsStory(id: earliest.event.id, memberIDs: members.map(\.event.id).sorted(),
                                 outlets: outletOrder.map { outletDisplayName($0.key, sample: $0.value.event) },
                                 heat: Double(outletOrder.count) * decay + Double(recent), leadID: items[units[lead][0]].event.id,
                                 latestID: latest.event.id, firstDate: first, lastDate: last,
                                 firstObserved: members.map(\.observedAt).min()!, breakingUntil: breaking))
    }
    stories.sort { a, b in
        let ta = a.outlets.count >= 3 ? 2 : a.outlets.count >= 2 ? 1 : 0, tb = b.outlets.count >= 3 ? 2 : b.outlets.count >= 2 ? 1 : 0
        if ta != tb { return ta > tb }
        if a.heat != b.heat { return a.heat > b.heat }
        if a.lastDate != b.lastDate { return (a.lastDate ?? .distantPast) > (b.lastDate ?? .distantPast) }
        return a.id < b.id
    }
    for (index, story) in stories.enumerated() { for id in story.memberIDs { result.storyOf[id] = index } }
    result.stories = stories
    result.surging = surgingNames(items, unitOf: unitOf, features: features, now: now)
    return result
}

/// Country and person names whose outlet count in the last 6 hours is at least 3 and 3× the prior average.
private func surgingNames(_ items: [StoryEntry], unitOf: [Int], features: [StoryFeatures], now: Date) -> [String] {
    var recent: [String: Set<String>] = [:], earlier: [String: Set<String>] = [:]
    for (i, entry) in items.enumerated() {
        guard let date = entry.event.date, let outlet = storyOutlet(entry.event), !dateOnlySource(entry.event.sourceID) else { continue }
        let age = now.timeIntervalSince(date)
        guard age >= 0, age <= storyWindow else { continue }
        let f = features[unitOf[i]]
        let keys = f.countries.map { "c:" + $0 } + f.personNames.map { "p:" + $0 }
        for key in keys {
            if age <= 6 * 3600 { recent[key, default: []].insert(outlet) } else { earlier[key, default: []].insert(outlet + "@" + String(Int(age / (6 * 3600)))) }
        }
    }
    let zh = Locale(identifier: "zh-Hans")
    let rising = recent.compactMap { key, outlets -> (String, Double, Int)? in
        guard outlets.count >= 3 else { return nil }
        let baseline = max(0.5, Double(earlier[key]?.count ?? 0) / 11)
        let ratio = Double(outlets.count) / baseline
        guard ratio >= 3 else { return nil }
        let name = key.hasPrefix("c:") ? (zh.localizedString(forRegionCode: String(key.dropFirst(2))) ?? String(key.dropFirst(2))) : String(key.dropFirst(2))
        return (name, ratio, outlets.count)
    }
    var seen = Set<String>()
    return rising.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0).filter { seen.insert($0).inserted }.prefix(5).map { $0 }
}

// MARK: - Index maintenance

/// Adds or refreshes headlines; keeps first-seen times, drops anything older than 72 hours and caps the size.
/// `followed` marks headlines that count against the separate followed-topic allowance.
func updatedStoryIndex(_ index: [String: StoryEntry], with events: [WorldEvent], now: Date = Date(), followed: (WorldEvent) -> Bool = { _ in false }) -> [String: StoryEntry] {
    var result = index
    for event in events where !event.disaster {
        if var known = result[event.id] {
            // Keep a translation the index already has when a feed re-delivers the untranslated headline.
            let translated = known.event.translatedTitle
            known.event = event
            if known.event.translatedTitle == nil, known.event.title == event.title { known.event.translatedTitle = translated }
            result[event.id] = known
        } else { result[event.id] = StoryEntry(event: event, observedAt: now) }
    }
    result = result.filter { now.timeIntervalSince($0.value.event.date ?? $0.value.observedAt) <= storyWindow }
    guard result.count > storyIndexLimit else { return result }
    func newestFirst(_ a: StoryEntry, _ b: StoryEntry) -> Bool { (a.event.date ?? a.observedAt, a.event.id) > (b.event.date ?? b.observedAt, b.event.id) }
    let split = Dictionary(grouping: result.values) { followed($0.event) }
    let keep = (split[false] ?? []).sorted(by: newestFirst).prefix(storyIndexLimit) + (split[true] ?? []).sorted(by: newestFirst).prefix(storyIndexFollowLimit)
    return Dictionary(uniqueKeysWithValues: keep.map { ($0.event.id, $0) })
}

// MARK: - Decoration and lists

/// Copies story facts onto headlines so lists and widgets can collapse and badge them without the index.
func decoratedEvents(_ events: [WorldEvent], with result: StoryResult?, now: Date = Date()) -> [WorldEvent] {
    events.map { event in
        var item = event
        if event.disaster {
            let strong = (event.magnitude ?? 0) >= 7 || event.severity == "红色预警"
            if strong, let date = event.date, now.timeIntervalSince(date) <= 6 * 3600 { item.breakingUntil = date.addingTimeInterval(6 * 3600) }
            return item
        }
        guard let story = result?.story(for: event.id) else { return item }
        item.storyID = story.id
        item.storyOutlets = story.outlets.count >= 2 ? story.outlets : nil
        item.storyHeat = story.outlets.count >= 2 ? story.heat : nil
        item.storyLead = story.leadID == event.id ? true : nil
        item.storyFirstDate = story.outlets.count >= 2 ? story.firstDate : nil
        item.breakingUntil = story.breakingUntil
        return item
    }
}

/// Lead headlines of the hottest multi-outlet stories, for lists that would otherwise have lost them to the 100-item cap.
func storyLeadEvents(_ result: StoryResult?, enabledIDs: Set<String>, limit: Int = 40, now: Date = Date()) -> [WorldEvent] {
    guard let result else { return [] }
    let leads = result.stories.filter { $0.outlets.count >= 2 }.compactMap { result.events[$0.leadID] }.filter { enabledIDs.contains($0.sourceID) }
    return decoratedEvents(Array(leads.prefix(limit)), with: result, now: now)
}

/// Keeps the first row of each story (callers pass newest-first lists, so the newest member stays).
func collapsedStories(_ events: [WorldEvent]) -> [WorldEvent] {
    var seen = Set<String>()
    return events.filter { event in
        guard let story = event.storyID else { return true }
        return seen.insert(story).inserted
    }
}

/// 热点: stories with ≥3 outlets, then 2 outlets (by heat), then single-outlet news newest first.
func hotEvents(_ events: [WorldEvent], now: Date = Date(), filter: NewsFilter = NewsFilter()) -> [WorldEvent] {
    let unique = uniqueNewsEvents(applyNewsFilter(events, filter: filter), mergeTopics: false, now: now)
    var groups: [String: [WorldEvent]] = [:]
    for event in unique { if let story = event.storyID, (event.storyOutlets?.count ?? 0) >= 2 { groups[story, default: []].append(event) } }
    let rows = groups.values.map { members in members.first { $0.storyLead == true } ?? members[0] }.sorted { a, b in
        let ta = (a.storyOutlets?.count ?? 0) >= 3, tb = (b.storyOutlets?.count ?? 0) >= 3
        if ta != tb { return ta }
        if a.storyHeat != b.storyHeat { return (a.storyHeat ?? 0) > (b.storyHeat ?? 0) }
        return a.storyID! < b.storyID!
    }
    let singles = collapsedStories(unique.filter { $0.storyID.flatMap { groups[$0] } == nil })
    return rows + singles
}

/// Hot mode needs fresh story facts from the app; otherwise it behaves like latest.
func effectiveDisplayMode(_ snapshot: NewsSnapshot, now: Date = Date()) -> NewsDisplayMode {
    guard snapshot.mode == .hot else { return snapshot.mode }
    let fresh = snapshot.updatedAt.map { now.timeIntervalSince($0) <= 2 * 3600 } ?? false
    let events = snapshot.sourceFeeds?.values.flatMap(\.events) ?? snapshot.rotationEvents ?? snapshot.events
    return fresh && events.contains { $0.storyOutlets != nil } ? .hot : .latest
}

/// Source line for a story row: "BBC、半岛电视台等 5 家" or the plain source name.
func storySourceLine(_ event: WorldEvent, expanded: Bool) -> String {
    guard let outlets = event.storyOutlets, outlets.count >= 2 else { return event.sourceName }
    if !expanded { return "\(event.sourceName) · \(outlets.count) 家" }
    return outlets.count == 2 ? "\(outlets[0])、\(outlets[1])" : "\(outlets[0])、\(outlets[1])等 \(outlets.count) 家"
}

func isBreaking(_ event: WorldEvent, now: Date = Date()) -> Bool { (event.breakingUntil ?? .distantPast) > now }
