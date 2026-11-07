import Foundation
import NaturalLanguage

// Same-event clustering evaluation for 世界动态 (research tool, not part of the app).
// Run through Tools/cluster-eval/cluster-eval.command; see docs/evaluation/热点聚类评测.md.

struct Item: Codable { let id: String; let source: String; let outlet: String; let lang: String; let title: String; let zh: String?; var en: String? = nil; let date: Date?; let url: String }

// MARK: - Country gazetteer (Locale names in en / zh-Hans / zh-Hant plus common aliases)

let manualAliases: [String: [String]] = [
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

struct Gazetteer {
    var ascii: [(code: String, regex: NSRegularExpression)] = []
    var cjk: [(code: String, names: [String])] = []
    init() {
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
        for (code, aliases) in manualAliases { names[code, default: []].formUnion(aliases) }
        for (code, set) in names {
            let asciiNames = set.filter { $0.allSatisfy(\.isASCII) }
            let cjkNames = set.filter { !$0.allSatisfy(\.isASCII) }
            if !asciiNames.isEmpty {
                let patterns = asciiNames.sorted { $0.count > $1.count }.map { name -> String in
                    let escaped = NSRegularExpression.escapedPattern(for: name)
                    // Short all-caps names (US, UK, EU, DRC) must match case-sensitively; "us" is a pronoun.
                    if name.count <= 4, name == name.uppercased() { return "(?<![A-Za-z])" + escaped + "(?![A-Za-z])" }
                    return "(?i:(?<![A-Za-z])" + escaped + "(?![A-Za-z]))"
                }
                if let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|")) { ascii.append((code, regex)) }
            }
            if !cjkNames.isEmpty { cjk.append((code, Array(cjkNames))) }
        }
    }
    func countries(in text: String) -> Set<String> {
        var found = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for (code, regex) in ascii where regex.firstMatch(in: text, range: range) != nil { found.insert(code) }
        for (code, names) in cjk where names.contains(where: text.contains) { found.insert(code) }
        // 印度 is a substring of 印度尼西亚, 苏丹 of 南苏丹.
        if found.contains("ID"), !text.contains("India"), text.contains("印度尼西亚"), !text.replacingOccurrences(of: "印度尼西亚", with: "").contains("印度") { found.remove("IN") }
        return found
    }
}

// MARK: - Features

struct Features {
    var zhVec: [Float]?
    var enSent: [Float]?
    var enCtx: [Float]?
    var countries: Set<String> = []
    var names: Set<String> = []
    var zhGrams: Set<String> = []
    var enWords: Set<String> = []
}

let stopwords: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "with", "at", "by", "from", "as", "is", "are", "was", "were", "be", "been", "it", "its", "after", "over", "into", "about", "amid", "says", "said", "say", "new", "will", "has", "have", "had", "not", "but", "this", "that", "his", "her", "their", "they", "he", "she", "who", "what", "how", "why", "more", "than", "up", "out", "can", "could", "would", "should", "may", "us"]

func meanPooled(_ model: NLContextualEmbedding, _ text: String, _ language: NLLanguage) -> [Float]? {
    guard let result = try? model.embeddingResult(for: text, language: language) else { return nil }
    var sum = [Float](repeating: 0, count: model.dimension); var count: Float = 0
    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
        for i in 0..<vector.count { sum[i] += Float(vector[i]) }
        count += 1
        return true
    }
    guard count > 0 else { return nil }
    let mean = sum.map { $0 / count }
    let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? mean.map { $0 / norm } : nil
}

func normalized(_ vector: [Double]?) -> [Float]? {
    guard let vector else { return nil }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? vector.map { Float($0 / norm) } : nil
}

func dot(_ a: [Float], _ b: [Float]) -> Double {
    var s: Float = 0
    for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
    return Double(s)
}

func namedEntities(_ text: String, _ language: NLLanguage) -> Set<String> {
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

/// Column tags and format boilerplate say nothing about the event ("学习贯彻…丨", "（第九届进博会）", "– as it happened").
let boilerplate: [NSRegularExpression] = [
    #"^[^丨｜|]{2,24}[丨｜|]"#, #"^（[^）]{2,20}）"#, #"^【[^】]{2,20}】"#, #"^(通讯|快讯|独家|视频|直播)[：:]"#,
    #"(?i)\s*[-–—]\s*(as it happened|live|the latest)$"#, #"(?i)^(watch|live|explainer|analysis|opinion)\s*:\s*"#,
    #"(?i)\s*[-–—|]\s*stateside with .*$"#, #"(?i)\breview\s*[-–—]"#
].map { try! NSRegularExpression(pattern: $0) }

func stripBoilerplate(_ title: String) -> String {
    var text = title
    for regex in boilerplate { text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") }
    return text.trimmingCharacters(in: .whitespaces)
}

func chineseBigrams(_ text: String) -> Set<String> {
    let chars = Array(text.lowercased())
    var grams = Set<String>()
    func usable(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    for i in 0..<max(chars.count - 1, 0) where usable(chars[i]) && usable(chars[i + 1]) {
        // Skip pure-ASCII bigrams inside English words that survived translation; keep CJK and digits.
        if chars[i].isASCII && chars[i + 1].isASCII && chars[i].isLetter { continue }
        if chars[i].isNumber && chars[i + 1].isNumber { continue }   // "2027", "200年" etc. are not event-specific
        grams.insert(String(chars[i...i + 1]))
    }
    return grams
}

func englishWords(_ text: String) -> Set<String> {
    var words = Set<String>()
    text.lowercased().enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
        guard var word, word.count >= 3, !stopwords.contains(word), !word.allSatisfy(\.isNumber) else { return }
        if word.hasSuffix("'s") || word.hasSuffix("’s") { word.removeLast(2) }
        if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
        words.insert(word)
    }
    return words
}

func loadItems(_ path: String) throws -> [Item] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func buildFeatures(_ items: [Item]) throws -> [Features] {
    let zhModel = NLContextualEmbedding(language: .simplifiedChinese)!
    let enModel = NLContextualEmbedding(language: .english)!
    try zhModel.load(); try enModel.load()
    let enSentence = NLEmbedding.sentenceEmbedding(for: .english)!
    let gazetteer = Gazetteer()
    return items.map { item in
        var f = Features()
        let zh = item.zh ?? item.title
        f.zhVec = meanPooled(zhModel, zh, .simplifiedChinese)
        f.countries = gazetteer.countries(in: item.title).union(gazetteer.countries(in: zh))
        f.names = namedEntities(zh, .simplifiedChinese)
        f.zhGrams = chineseBigrams(stripBoilerplate(zh))
        // English text: the original for English sources, Apple's back-translation for Chinese ones (if present).
        if let english = item.lang == "en" ? item.title : item.en {
            f.enSent = normalized(enSentence.vector(for: english))
            f.enCtx = meanPooled(enModel, english, .english)
            f.names.formUnion(namedEntities(english, .english))
            f.enWords = englishWords(stripBoilerplate(english))
        }
        return f
    }
}

func idfTable<T: Hashable>(_ sets: [Set<T>]) -> [T: Double] {
    var df: [T: Int] = [:]
    for set in sets { for token in set { df[token, default: 0] += 1 } }
    let n = Double(sets.count)
    return df.mapValues { log(n / Double($0)) }
}

struct PairSignals {
    let i: Int, j: Int
    let zh: Double          // cosine, Chinese contextual (translated titles for English sources)
    let enSent: Double?     // cosine, English sentence embedding (both English)
    let enCtx: Double?      // cosine, English contextual (both English)
    let lexZh: Double       // IDF-weighted Dice over Chinese character bigrams
    let lexEn: Double?      // IDF-weighted Dice over English content words
    let countryIDF: Double  // strongest shared country (max IDF), 0 if none
    let nameIDF: Double     // strongest shared named entity (max IDF), 0 if none
    let gramIDF: Double     // rarest shared Chinese character bigram (max IDF), 0 if none
    let hours: Double?
    var semantic: Double {  // calibrated so ~1.0 is a typical same-event pair in the synthetic probe
        max((zh - 0.62) / 0.23, enSent.map { ($0 - 0.25) / 0.33 } ?? -1)
    }
    var lexical: Double { max(lexZh, lexEn ?? 0) }
    var anchorIDF: Double { max(countryIDF, nameIDF) }
}

func weightedDice<T: Hashable>(_ a: Set<T>, _ b: Set<T>, _ idf: [T: Double]) -> Double {
    let shared = a.intersection(b).reduce(0) { $0 + (idf[$1] ?? 0) }
    let total = a.reduce(0) { $0 + (idf[$1] ?? 0) } + b.reduce(0) { $0 + (idf[$1] ?? 0) }
    return total > 0 ? 2 * shared / total : 0
}

struct Corpus {
    let items: [Item]
    let features: [Features]
    let gramIDF: [String: Double]
    let wordIDF: [String: Double]
    let countryIDF: [String: Double]
    let nameIDF: [String: Double]
    init(_ path: String) throws {
        items = try loadItems(path)
        features = try buildFeatures(items)
        gramIDF = idfTable(features.map(\.zhGrams))
        wordIDF = idfTable(features.map(\.enWords))
        countryIDF = idfTable(features.map(\.countries))
        nameIDF = idfTable(features.map(\.names))
    }
    func signals(_ i: Int, _ j: Int) -> PairSignals {
        let a = features[i], b = features[j]
        let sharedCountries = a.countries.intersection(b.countries)
        let sharedNames = a.names.intersection(b.names).subtracting(["中国", "美国", "china", "us"])
        let hours: Double? = {
            guard let x = items[i].date, let y = items[j].date else { return nil }
            return abs(x.timeIntervalSince(y)) / 3600
        }()
        return PairSignals(
            i: i, j: j,
            zh: (a.zhVec != nil && b.zhVec != nil) ? dot(a.zhVec!, b.zhVec!) : 0,
            enSent: (a.enSent != nil && b.enSent != nil) ? dot(a.enSent!, b.enSent!) : nil,
            enCtx: (a.enCtx != nil && b.enCtx != nil) ? dot(a.enCtx!, b.enCtx!) : nil,
            lexZh: weightedDice(a.zhGrams, b.zhGrams, gramIDF),
            lexEn: (!a.enWords.isEmpty && !b.enWords.isEmpty) ? weightedDice(a.enWords, b.enWords, wordIDF) : nil,
            countryIDF: sharedCountries.map { countryIDF[$0] ?? 0 }.max() ?? 0,
            nameIDF: sharedNames.map { nameIDF[$0] ?? 0 }.max() ?? 0,
            gramIDF: a.zhGrams.intersection(b.zhGrams).map { gramIDF[$0] ?? 0 }.max() ?? 0,
            hours: hours)
    }
}

// MARK: - Candidate pool for labeling

func candidates(corpusPath: String, sheetPath: String, pairsPath: String) throws {
    let corpus = try Corpus(corpusPath)
    let n = corpus.items.count
    print("items: \(n)")
    let topCountries = corpus.countryIDF.sorted { $0.value < $1.value }.prefix(8).map { "\($0.key)=\(String(format: "%.1f", $0.value))" }
    print("most common countries (low IDF): \(topCountries)")
    var all: [PairSignals] = []
    all.reserveCapacity(n * (n - 1) / 2)
    for i in 0..<n { for j in (i + 1)..<n { all.append(corpus.signals(i, j)) } }
    print("pairs: \(all.count)")
    var pool = Set<[Int]>()
    func take(_ list: [PairSignals], _ k: Int, by key: (PairSignals) -> Double) {
        for p in list.sorted(by: { key($0) > key($1) }).prefix(k) { pool.insert([p.i, p.j]) }
    }
    take(all, 120) { $0.zh }
    take(all.filter { $0.enSent != nil }, 80) { $0.enSent! }
    take(all.filter { $0.enCtx != nil }, 50) { $0.enCtx! }
    take(all, 120) { $0.lexical }
    take(all.filter { $0.anchorIDF >= 2.0 }, 100) { $0.semantic + 2 * $0.lexical }
    var generator = SystemRandomNumberGenerator()
    let middle = all.filter { $0.semantic > 0.2 && $0.semantic < 0.7 }
    for _ in 0..<30 { if let p = middle.randomElement(using: &generator) { pool.insert([p.i, p.j]) } }
    for _ in 0..<20 { if let p = all.randomElement(using: &generator) { pool.insert([p.i, p.j]) } }
    let ordered = pool.map { corpus.signals($0[0], $0[1]) }.sorted { ($0.semantic + 2 * $0.lexical) > ($1.semantic + 2 * $1.lexical) }
    print("labeling pool: \(ordered.count)")
    var sheet = ""
    var tsv = "pair\ti\tj\n"
    for (index, p) in ordered.enumerated() {
        let a = corpus.items[p.i], b = corpus.items[p.j]
        let hours = p.hours.map { String(format: "%.0fh", $0) } ?? "?"
        sheet += String(format: "P%03d", index + 1) + " | \(hours) | \(a.source): \(a.title) ‖ \(b.source): \(b.title)\n"
        tsv += String(format: "P%03d", index + 1) + "\t\(a.id)\t\(b.id)\n"
    }
    try sheet.write(toFile: sheetPath, atomically: true, encoding: .utf8)
    try tsv.write(toFile: pairsPath, atomically: true, encoding: .utf8)
}

func normalizedTitle(_ title: String) -> String {
    title.lowercased().replacingOccurrences(of: "｜", with: "|").replacingOccurrences(of: "丨", with: "|")
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

func readPairs(_ path: String) -> [(label: String, a: String, b: String)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").dropFirst().compactMap { line in
        let parts = line.split(separator: "\t").map(String.init)
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }
}

/// Second labeling round: pairs involving a Chinese-language source, which the first pool under-sampled.
func crossPool(corpusPath: String, existingPath: String, sheetPath: String, pairsPath: String) throws {
    let corpus = try Corpus(corpusPath)
    let index = Dictionary(uniqueKeysWithValues: corpus.items.enumerated().map { ($1.id, $0) })
    let existing = Set(readPairs(existingPath).compactMap { p -> [Int]? in
        guard let a = index[p.a], let b = index[p.b] else { return nil }
        return [min(a, b), max(a, b)]
    })
    let n = corpus.items.count
    var cross: [PairSignals] = [], chinese: [PairSignals] = []
    for i in 0..<n { for j in (i + 1)..<n where !existing.contains([i, j]) {
        let a = corpus.items[i], b = corpus.items[j]
        guard a.lang == "zh" || b.lang == "zh", normalizedTitle(a.title) != normalizedTitle(b.title) else { continue }
        let s = corpus.signals(i, j)
        if a.lang != b.lang { cross.append(s) } else { chinese.append(s) }
    } }
    var pool = Set<[Int]>()
    func take(_ list: [PairSignals], _ k: Int, by key: (PairSignals) -> Double) {
        for p in list.sorted(by: { key($0) > key($1) }).prefix(k) { pool.insert([p.i, p.j]) }
    }
    take(cross, 100) { $0.zh }
    take(cross, 60) { $0.lexZh }
    take(cross.filter { $0.anchorIDF >= 2.0 }, 80) { $0.zh + $0.lexZh }
    take(chinese, 50) { $0.zh }
    take(chinese, 40) { $0.lexZh }
    let ordered = pool.map { corpus.signals($0[0], $0[1]) }.sorted { ($0.zh + $0.lexZh) > ($1.zh + $1.lexZh) }
    print("cross-language pairs: \(cross.count), chinese-chinese: \(chinese.count), pool: \(ordered.count)")
    var sheet = "", tsv = "pair\ti\tj\n"
    for (k, p) in ordered.enumerated() {
        let a = corpus.items[p.i], b = corpus.items[p.j]
        let hours = p.hours.map { String(format: "%.0fh", $0) } ?? "?"
        let label = String(format: "Q%03d", k + 1)
        sheet += "\(label) | \(hours) | \(a.source): \(a.title) ‖ \(b.source): \(b.title)\n"
        tsv += "\(label)\t\(a.id)\t\(b.id)\n"
    }
    try sheet.write(toFile: sheetPath, atomically: true, encoding: .utf8)
    try tsv.write(toFile: pairsPath, atomically: true, encoding: .utf8)
}

/// pair-labels.tsv: label (S same event / R related / X identical title / D different), sheet pair id, item ids.
func readPairLabels(_ path: String) -> [(label: String, a: String, b: String)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").dropFirst().compactMap { line in
        let parts = line.split(separator: "\t").map(String.init)
        return parts.count == 4 ? (parts[0], parts[2], parts[3]) : nil
    }
}

/// Turns sheet labels ("S P001 P002 …" lines; unlisted pairs are D) into pair-labels.tsv.
func mergeLabels(pairFiles: [String], labelFiles: [String], out: String) throws {
    let labels = readLabels(labelFiles)
    var rows = ["label\tsheet_pair\titem_a\titem_b"]
    for file in pairFiles { for p in readPairs(file) { rows.append("\(labels[p.label] ?? "D")\t\(p.label)\t\(p.a)\t\(p.b)") } }
    try (rows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(rows.count - 1) labeled pairs to \(out)")
}

struct UnionFind {
    var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }
    mutating func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
    mutating func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
}

/// Pair labels from label files: "S P001 P002 ..." lines; unlisted pairs default to D.
func readLabels(_ paths: [String]) -> [String: String] {
    var labels: [String: String] = [:]
    for path in paths {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ").map(String.init)
            guard let tag = parts.first, ["S", "R", "X"].contains(tag) else { continue }
            for pair in parts.dropFirst() { labels[pair] = tag }
        }
    }
    return labels
}

/// Items with the same normalized title or URL are one article to the app (it already dedupes them).
func duplicateGroups(_ items: [Item]) -> UnionFind {
    var uf = UnionFind(items.count)
    var byTitle: [String: Int] = [:], byURL: [String: Int] = [:]
    for (i, item) in items.enumerated() {
        let t = normalizedTitle(item.title)
        if let j = byTitle[t] { uf.union(i, j) } else { byTitle[t] = i }
        if let j = byURL[item.url] { uf.union(i, j) } else { byURL[item.url] = i }
    }
    return uf
}

func seeds(corpusPath: String, pairLabelsPath: String) throws {
    let items = try loadItems(corpusPath)
    let index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    var uf = duplicateGroups(items)
    for p in readPairLabels(pairLabelsPath) where p.label == "S" {
        if let a = index[p.a], let b = index[p.b] { uf.union(a, b) }
    }
    var groups: [Int: [Int]] = [:]
    for i in items.indices { groups[uf.find(i), default: []].append(i) }
    let multi = groups.values.filter { Set($0.map { normalizedTitle(items[$0].title) }).count >= 2 }.sorted { $0.count > $1.count }
    print("seed clusters with ≥2 distinct titles: \(multi.count)")
    for (k, group) in multi.enumerated() {
        print("\n#\(k + 1) (\(group.count) items, outlets: \(Set(group.map { items[$0].outlet }).sorted().joined(separator: ",")))")
        for i in group.sorted() { print("  \(i) \(items[i].source): \(items[i].title)") }
    }
}

func search(corpusPath: String, pattern: String) throws {
    let items = try loadItems(corpusPath)
    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    for (i, item) in items.enumerated() {
        let text = item.title + " ‖ " + (item.zh ?? "")
        if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            print("\(i) \(item.source): \(item.title)\(item.lang == "en" ? "  〔\(item.zh ?? "")〕" : "")")
        }
    }
}

let arguments = CommandLine.arguments
func arg(_ i: Int) -> String { i < arguments.count ? arguments[i] : "" }
let usage = """
usage: cluster-eval <mode> …
 labeling a fresh corpus:
  candidates <corpus.json> <sheet.txt> <pairs.tsv>                  top pairs by several signals plus random controls
  crosspool  <corpus.json> <pairs.tsv> <sheet2.txt> <pairs2.tsv>     second round: pairs with a Chinese-language source
  labels     <out.tsv> <pairs.tsv,pairs2.tsv> <labels.txt,labels2.txt>  merge sheet labels into pair-labels.tsv
  seeds      <corpus.json> <pair-labels.tsv>                         same-event seed clusters from labeled pairs
  search     <corpus.json> <regex>                                   find event members by keyword
  adjudicate <corpus.json> <gold.txt> <pair-labels.tsv>              merges strong rules make that the gold calls wrong
 evaluation (the .command wrapper fills in the fixture paths):
  diagnose | baseline | compare [i:single|average|online:t] | grid | centroid [t] | hotness [t]
"""
switch arg(1) {
case "candidates": try candidates(corpusPath: arg(2), sheetPath: arg(3), pairsPath: arg(4))
case "crosspool": try crossPool(corpusPath: arg(2), existingPath: arg(3), sheetPath: arg(4), pairsPath: arg(5))
case "labels": try mergeLabels(pairFiles: arg(3).split(separator: ",").map(String.init), labelFiles: arg(4).split(separator: ",").map(String.init), out: arg(2))
case "seeds": try seeds(corpusPath: arg(2), pairLabelsPath: arg(3))
case "search": try search(corpusPath: arg(2), pattern: arg(3))
case "adjudicate": try adjudicate(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4))
case "diagnose": try diagnose(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4))
case "baseline": try baseline(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4))
case "compare": try compare(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4), detail: arguments.count > 5 ? arg(5) : nil)
case "grid": try grid(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4))
case "centroid": try centroidEval(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4), detail: arguments.count > 5 ? Double(arg(5)) : nil)
case "hotness": try hotness(corpusPath: arg(2), goldPath: arg(3), pairLabelsPath: arg(4), detail: arguments.count > 5 ? Double(arg(5)) : nil)
default: print(usage)
}
