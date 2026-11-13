import Foundation

// 关注追踪（2.10–2.12）: followed topics, outlet tiers, fact labels, the big-event gate, alerts and topic history.
// Pure functions shared by the app, the widgets and Tests/TopicCheck.swift. Plan and measurements: docs/路线图.md.

// MARK: - Topics

struct FollowTopic: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    /// Any alias is enough: Chinese terms match as substrings (simplified/traditional folded), English as whole words.
    var aliases: [String]
    /// Issue topics also match when every group has a hit, e.g. 台湾 together with one of 大陆、解放军、北京.
    var pairs: [[String]] = []
    /// Google News search queries that fill in coverage for this topic.
    var queryZH: String = ""
    var queryEN: String = ""
    /// Index and share-price moves are hidden unless asked for.
    var showTicks = false
    var alerts = true

    init(id: String, name: String, aliases: [String], pairs: [[String]] = [], queryZH: String = "", queryEN: String = "", showTicks: Bool = false, alerts: Bool = true) {
        self.id = id; self.name = name; self.aliases = aliases; self.pairs = pairs
        self.queryZH = queryZH; self.queryEN = queryEN; self.showTicks = showTicks; self.alerts = alerts
        if self.queryZH.isEmpty || self.queryEN.isEmpty { fillQueries() }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? [name]
        pairs = try c.decodeIfPresent([[String]].self, forKey: .pairs) ?? []
        queryZH = try c.decodeIfPresent(String.self, forKey: .queryZH) ?? ""
        queryEN = try c.decodeIfPresent(String.self, forKey: .queryEN) ?? ""
        showTicks = try c.decodeIfPresent(Bool.self, forKey: .showTicks) ?? false
        alerts = try c.decodeIfPresent(Bool.self, forKey: .alerts) ?? true
        if queryZH.isEmpty || queryEN.isEmpty { fillQueries() }
    }

    /// Search queries derived from the aliases: Chinese terms for the Chinese edition, English ones for the English edition.
    mutating func fillQueries() {
        let terms = ([name] + aliases).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0.lowercased()).inserted }
        let ascii = unique.filter { $0.allSatisfy(\.isASCII) }, cjk = unique.filter { !$0.allSatisfy(\.isASCII) }
        func joined(_ words: [String]) -> String { words.prefix(4).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " OR ") }
        queryZH = joined(cjk.isEmpty ? ascii : cjk)
        queryEN = joined(ascii.isEmpty ? cjk : ascii)
    }

    static let presets: [FollowTopic] = [
        FollowTopic(id: "musk", name: "马斯克", aliases: ["马斯克", "Elon Musk", "Musk"], queryZH: "马斯克", queryEN: "\"Elon Musk\""),
        FollowTopic(id: "trump", name: "特朗普", aliases: ["特朗普", "川普", "Trump"], queryZH: "特朗普", queryEN: "Trump"),
        FollowTopic(id: "nvidia", name: "英伟达", aliases: ["英伟达", "辉达", "黄仁勋", "Nvidia", "Jensen Huang"], queryZH: "英伟达 OR 黄仁勋", queryEN: "Nvidia OR \"Jensen Huang\""),
        FollowTopic(id: "spacex", name: "SpaceX", aliases: ["SpaceX", "星舰", "星链", "猎鹰9", "Starship", "Starlink", "Falcon 9"], queryZH: "SpaceX OR 星舰 OR 星链", queryEN: "SpaceX OR Starship OR Starlink"),
        FollowTopic(id: "us-china", name: "中美关系", aliases: ["中美", "美中", "Sino-US", "Sino-U.S.", "US-China", "U.S.-China", "China-US", "China-U.S."],
                    pairs: [["中国", "中方", "北京", "习近平", "China", "Chinese", "Beijing", "Xi Jinping"],
                            ["美国", "美方", "华盛顿", "白宫", "特朗普", "川普", "United States", "Washington", "White House", "Trump", "US", "U.S."]],
                    queryZH: "中美", queryEN: "\"US-China\" OR \"China-US\" OR \"Sino-US\""),
        FollowTopic(id: "ukraine", name: "俄乌战争", aliases: ["乌克兰", "俄乌", "基辅", "泽连斯基", "顿巴斯", "扎波罗热", "哈尔科夫", "克里米亚",
                                                       "Ukraine", "Ukrainian", "Kyiv", "Kiev", "Zelensky", "Zelenskyy", "Donbas", "Zaporizhzhia", "Kharkiv", "Crimea"],
                    queryZH: "乌克兰 OR 俄乌", queryEN: "Ukraine"),
        FollowTopic(id: "taiwan", name: "台海两岸", aliases: ["两岸", "台海", "台湾海峡", "国台办", "赖清德", "台独", "Taiwan Strait", "cross-strait", "Lai Ching-te"],
                    pairs: [["台湾", "Taiwan", "Taiwanese"], ["大陆", "解放军", "北京", "中国", "中共", "PLA", "Beijing", "China", "Chinese"]],
                    queryZH: "台海 OR 两岸 OR 国台办", queryEN: "Taiwan China OR \"Taiwan Strait\"")
    ]
    static let limit = 20

    static func read(from defaults: UserDefaults) -> [FollowTopic] {
        guard let data = defaults.data(forKey: "followTopics"), let topics = try? JSONDecoder().decode([FollowTopic].self, from: data) else { return presets }
        return topics
    }
    static var selected: [FollowTopic] {
        get { read(from: WorldPreferences.shared) }
        set { if let data = try? JSONEncoder().encode(Array(newValue.prefix(limit))) { WorldPreferences.shared.set(data, forKey: "followTopics") } }
    }
}

/// Text form used for matching: traditional folded to simplified, lower-cased; "北京时间" is a clock, not Beijing.
func topicMatchText(_ text: String) -> String {
    let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    return simplified.lowercased().replacingOccurrences(of: "北京时间", with: " ")
}

struct TopicMatcher: @unchecked Sendable {
    private struct Terms {
        var cjk: [String] = []
        var exact: [NSRegularExpression] = []    // short all-caps ASCII (US, U.S., PLA): case-sensitive, "us" is a pronoun
        var folded: [NSRegularExpression] = []
        init(_ words: [String]) {
            for word in words.map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
                guard word.allSatisfy(\.isASCII) else { cjk.append(topicMatchText(word).trimmingCharacters(in: .whitespaces)); continue }
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9])"
                let letters = word.filter(\.isLetter)
                if word.count <= 5, !letters.isEmpty, letters == letters.uppercased() {
                    if let regex = try? NSRegularExpression(pattern: pattern) { exact.append(regex) }
                } else if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) { folded.append(regex) }
            }
            cjk = cjk.filter { !$0.isEmpty }
        }
        var isEmpty: Bool { cjk.isEmpty && exact.isEmpty && folded.isEmpty }
        func hit(original: String, folded text: String) -> Bool {
            if cjk.contains(where: text.contains) { return true }
            let o = NSRange(original.startIndex..., in: original), f = NSRange(text.startIndex..., in: text)
            return exact.contains { $0.firstMatch(in: original, range: o) != nil } || folded.contains { $0.firstMatch(in: text, range: f) != nil }
        }
    }
    private let compiled: [(id: String, any: Terms, pairs: [Terms])]
    let topics: [FollowTopic]
    init(_ topics: [FollowTopic]) {
        self.topics = topics
        compiled = topics.map { ($0.id, Terms($0.aliases), $0.pairs.map(Terms.init).filter { !$0.isEmpty }) }
    }
    var isEmpty: Bool { topics.isEmpty }
    /// Ids of the topics any of the texts mention, in topic order.
    func topicIDs(_ texts: [String]) -> [String] {
        guard !compiled.isEmpty else { return [] }
        let pairs = texts.map { ($0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0, topicMatchText($0)) }
        return compiled.filter { topic in
            pairs.contains { original, folded in
                topic.any.hit(original: original, folded: folded) || (!topic.pairs.isEmpty && topic.pairs.allSatisfy { $0.hit(original: original, folded: folded) })
            }
        }.map(\.id)
    }
    func topicIDs(_ event: WorldEvent) -> [String] { topicIDs([event.title, event.translatedTitle].compactMap { $0 }) }
}

/// "马斯克" or "马斯克、SpaceX" for a row's tag; unknown ids (a deleted topic) are skipped.
func topicLabel(_ ids: [String]?, topics: [FollowTopic], limit: Int = 2) -> String? {
    let names = (ids ?? []).compactMap { id in topics.first { $0.id == id }?.name }
    guard !names.isEmpty else { return nil }
    return names.prefix(limit).joined(separator: "、") + (names.count > limit ? "等" : "")
}

// MARK: - Extra sources: topic searches and 新浪 7×24

extension NewsSource {
    static let sina = NewsSource(id: "sina-7x24", name: "新浪财经 7×24", url: URL(string: "https://zhibo.sina.com.cn/api/zhibo/feed?page=1&page_size=60&zhibo_id=152&tag_id=0&dire=f&dpc=1")!,
                                 detail: "编辑快讯 · 只收关注对象的非行情快讯", disaster: false, category: .finance, language: "zh")
    /// Two Google News searches per topic (Chinese and English editions), past day only.
    static func topicSources(_ topics: [FollowTopic]) -> [NewsSource] {
        topics.flatMap { topic -> [NewsSource] in
            [("zh", topic.queryZH, "hl=zh-CN&gl=CN&ceid=CN:zh-Hans"), ("en", topic.queryEN, "hl=en-US&gl=US&ceid=US:en")].compactMap { language, query, edition in
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let encoded = (trimmed + " when:1d").addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                      let url = URL(string: "https://news.google.com/rss/search?q=\(encoded)&\(edition)") else { return nil }
                return NewsSource(id: "topic-\(topic.id)-\(language)", name: "关注搜索·\(topic.name)", url: url, detail: language == "zh" ? "Google 新闻中文搜索" : "Google News 英文搜索",
                                  disaster: false, language: language, aggregator: true)
            }
        }
    }
    /// Lookup that also knows the extra sources, which are not in `all` (the widget must not fetch them).
    static func find(_ id: String) -> NewsSource? {
        if let source = all.first(where: { $0.id == id }) { return source }
        if id == sina.id { return sina }
        if id.hasPrefix("topic-") {
            let language = id.hasSuffix("-zh") ? "zh" : "en"
            return NewsSource(id: id, name: "关注搜索", url: URL(string: "https://news.google.com/")!, detail: "", disaster: false, language: language, aggregator: true)
        }
        return nil
    }
    var isExtra: Bool { id == NewsSource.sina.id || id.hasPrefix("topic-") }
}

private let sinaDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private struct SinaFeed: Decodable {
    struct Result: Decodable { let data: DataBlock }
    struct DataBlock: Decodable { let feed: Feed }
    struct Feed: Decodable { let list: [Item] }
    struct Item: Decodable { let id: FlexibleID; let rich_text: String?; let create_time: String?; let docurl: String? }
    struct FlexibleID: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let text = try? c.decode(String.self) { value = text } else { value = String(try c.decode(Int.self)) }
        }
    }
    let result: Result
}

/// 新浪 7×24 flashes: "【标题】正文" keeps the bracketed headline, otherwise the text is the headline (capped).
func parseSinaFeed(_ data: Data, now: Date = Date()) throws -> [WorldEvent] {
    let feed = try JSONDecoder().decode(SinaFeed.self, from: data)
    return feed.result.data.feed.list.compactMap { item in
        var text = cleanTitle(item.rich_text ?? "")
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("【"), let close = text.firstIndex(of: "】"), text.distance(from: text.startIndex, to: close) > 2 {
            text = String(text[text.index(after: text.startIndex)..<close])
        }
        if text.count > 90 { text = String(text.prefix(88)) + "…" }
        let url = item.docurl.flatMap(safeURL) ?? URL(string: "https://finance.sina.com.cn/7x24/")!
        let date = plausiblePublishDate(item.create_time.flatMap { sinaDateFormatter.date(from: $0) }, now: now)
        return WorldEvent(id: "sina-7x24:" + item.id.value, sourceID: NewsSource.sina.id, title: text, url: url, date: date, timeKind: "发布",
                          disaster: false, severity: nil, translatedTitle: text, publisher: "新浪财经")
    }
}

// MARK: - Outlet tiers and fact labels

enum OutletTier: Int, Comparable, Sendable {
    case primary = 1, ordinary = 2, low = 3
    static func < (a: OutletTier, b: OutletTier) -> Bool { a.rawValue < b.rawValue }
}

// Wire services, major newsrooms, official sources and established Chinese outlets.
private let primaryOutletNames = [
    "reuters", "路透", "associated press", "ap news", "美联社", "afp", "法新社", "agence france", "bloomberg", "彭博",
    "new york times", "nytimes", "纽约时报", "wall street journal", "wsj", "华尔街日报", "financial times", "金融时报", "washington post", "华盛顿邮报",
    "bbc", "guardian", "卫报", "cnbc", "npr", "cnn", "politico", "axios", "economist", "经济学人", "nikkei", "日经", "kyodo", "共同社", "yonhap", "韩联社",
    "al jazeera", "半岛", "deutsche welle", "德国之声", "dw.com", "france 24", "rfi", "法广", "sky news", "abc news", "cbs news", "nbc news",
    "los angeles times", "usa today", "the times", "the telegraph", "the information", "semafor", "voice of america", "美国之音", "techcrunch", "the verge",
    "新华", "人民日报", "人民网", "央视", "cctv", "中国新闻网", "中新网", "中国日报", "财联社", "第一财经", "新京报", "澎湃", "财新", "21财经", "21世纪经济",
    "经济观察", "界面", "每日经济新闻", "证券时报", "上观", "解放日报", "南方都市报", "中央社", "中央通讯社", "联合早报", "南华早报", "scmp", "south china morning post",
    "外交部", "国务院", "国台办", "国防部", "gov.cn", "新浪财经", "united nations", "联合国"
]
// Market chatter, stock-picking sites and self-media platforms: dropped from aggregator feeds.
private let lowOutletNames = [
    "benzinga", "motley fool", "fool.com", "24/7 wall", "tradingview", "investing.com", "英为财情", "seeking alpha", "zacks", "moomoo", "富途", "老虎证券",
    "雪球", "搜狐", "sohu", "百家号", "网易号", "头条号", "东方财富", "股吧", "insider monkey", "marketbeat", "gurufocus", "tipranks", "stocktwits",
    "social news xyz", "coincentral", "ad hoc news", "finimize", "simply wall", "trefis", "nasdaq.com", "investorplace", "gobankingrates"
]

func outletTier(publisher: String?, sourceID: String) -> OutletTier {
    guard let publisher = publisher?.trimmingCharacters(in: .whitespaces), !publisher.isEmpty else {
        // Direct feeds were each checked by hand when added.
        return .primary
    }
    let name = topicMatchText(publisher)
    if lowOutletNames.contains(where: name.contains) { return .low }
    if name == "dw" || primaryOutletNames.contains(where: name.contains) { return .primary }
    return .ordinary
}

func outletTier(_ event: WorldEvent) -> OutletTier { outletTier(publisher: event.publisher, sourceID: event.sourceID) }

private let tickPattern = try! NSRegularExpression(pattern: #"(?:涨|跌|升|降|涨幅|跌幅|反弹|回落|拉升|下挫|走高|走低)\s*(?:超|逾|近|约|达)?\s*\d+(?:\.\d+)?\s*%|高开|低开|股指|收高|收低|跳水|现报|盘前|盘后|盘中|收涨|收跌|收盘|开盘|日内|涨停|跌停|市值(?:蒸发|增加|突破|跌破|超过)|股价|评级|目标价|\b(?:shares?|stocks?|futures|nasdaq|s&p)\b[^.]{0,40}\b(?:rise|rises|rose|fall|falls|fell|jump|jumps|jumped|slide|slides|slid|drop|drops|dropped|surge|surges|surged|tumble|tumbles|tumbled|climb|climbs|climbed|sink|sinks|sank|gain|gains|gained|rally|rallies|rallied|plunge|plunges|plunged|soar|soars|soared|slump|slumps|slumped)\b|\bprice target\b|\b(?:buy|sell|hold|overweight|underweight) rating\b|\bstock (?:price|forecast|prediction)\b|\bshould you buy\b|\bpremarket\b|\bafter[- ]hours\b"#, options: .caseInsensitive)

/// Index and share-price moves, ratings and price targets: market noise rather than news about the topic.
func isMarketTick(_ event: WorldEvent) -> Bool {
    [event.title, event.translatedTitle].compactMap { $0 }.contains { tickPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
}

private let rumorPattern = try! NSRegularExpression(pattern: #"或将|或于|或在|传出|传闻|市场消息|市场传闻|据悉|消息人士|知情人士|据报道|报道称|据称|网传|\breportedly\b|\bsources? (?:say|said|says)\b|\bpeople familiar\b|\bsaid to\b|\bin talks\b|\bweighs?\b|\bconsidering\b|\bcould announce\b|\bmay announce\b|\brumou?rs?\b|[:：]\s*report$|\breport says\b"#, options: .caseInsensitive)

/// Unconfirmed wording: talks, sources, "或将". Shown with a 「据报道」 label until two primary outlets carry the story.
func isRumorHeadline(_ event: WorldEvent) -> Bool {
    [event.title, event.translatedTitle].compactMap { $0 }.contains { rumorPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
}

private let softNewsPattern = try! NSRegularExpression(pattern: #"农博会|花博会|博览会|展销|巡展|作品展|文化节|艺术节|音乐节|联谊|研学|夏令营|冬令营|网友共创|共创视频|见面会|宣讲|侧记|随笔|综述|述评|社评|网评|时评|快评|锐评|评论员|新闻会客厅|学习贯彻|主题教育|党性|交流活动|座谈会|推介会|年会|周报|周刊|速览|早知道|晨报|晚报|午报|深一度|能否|会否|何去何从|意味着什么|怎么看|^[^丨｜|]{0,8}(?:观察|评论|视点|聚焦|调查|解码|读懂)[丨｜|]"#)

// Analysis and features in English: listicles, explainers, two-sentence feature headlines ("… knew. Now some wonder …").
private let featurePattern = try! NSRegularExpression(pattern: #"\b(?:names to watch|what to (?:know|watch|expect)|things to know|here'?s (?:what|why|how)|the rise and fall|what (?:we|you) know|explained|analysis|opinion|takeaways|lessons from|comes back to bite|a (?:tougher|bigger) test)\b|^\d+ (?:names|things|ways|reasons|takeaways|questions|charts|people)\b"#, options: .caseInsensitive)
private let twoSentencePattern = try! NSRegularExpression(pattern: #"[a-z]{2,}[.!?]\s+[A-Z][a-z]"#)
private let chineseRoundupPattern = try! NSRegularExpression(pattern: #"梳理|盘点|回顾|复盘|一文|细数|全解析|时间线"#)

/// Fairs, exchanges, study tours, theory pieces, commentary columns, roundups and features:
/// true stories, but small stuff or analysis for the followed view.
func isSoftNews(_ event: WorldEvent) -> Bool {
    if [event.title, event.translatedTitle].compactMap({ $0 }).contains(where: { softNewsPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil || chineseRoundupPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) { return true }
    let title = event.title
    let range = NSRange(title.startIndex..., in: title)
    return !containsHan(title) && (featurePattern.firstMatch(in: title, range: range) != nil || twoSentencePattern.firstMatch(in: title, range: range) != nil)
}

func containsHan(_ text: String) -> Bool { text.unicodeScalars.contains { (0x3400...0x9fff).contains(Int($0.value)) } }

// MARK: - Big events

enum MajorLevel: String, CaseIterable, Codable, Sendable {
    case loose = "宽松", standard = "标准", strict = "严格"
    static var selected: MajorLevel {
        get { MajorLevel(rawValue: WorldPreferences.shared.string(forKey: "majorLevel") ?? "") ?? .standard }
        set { WorldPreferences.shared.set(newValue.rawValue, forKey: "majorLevel") }
    }
    /// Outlets needed when Chinese and foreign media both report it, foreign media only, and Chinese media only.
    /// Chinese portals republish each other, so a Chinese-only story needs the most outlets.
    var thresholds: (cross: Int, foreign: Int, chinese: Int) {
        switch self {
        case .loose: return (4, 7, 10)
        case .standard: return (6, 10, 14)
        case .strict: return (8, 14, 18)
        }
    }
    var detail: String {
        let t = thresholds
        return "中外媒体都报道且 \(t.cross) 家以上；只有外媒 \(t.foreign) 家以上；只有中文媒体 \(t.chinese) 家以上" + (self == .strict ? "" : "；或 1 小时内 3 家相继报道的突发（4 家以上、其中两家一档，不含只有中文媒体的）") + "；都须至少一家通讯社、主流媒体或官方来源"
    }
}

/// The gate for events outside the followed list. Outlet counts are independent newsrooms within one story;
/// at least one must be primary, and two for the breaking route (local TV sites syndicate each other within minutes).
func isMajorStory(outlets: Int, chinese: Bool, foreign: Bool, breaking: Bool, primary: Int, level: MajorLevel) -> Bool {
    guard primary >= 1 else { return false }
    let t = level.thresholds
    if chinese && foreign { if outlets >= t.cross { return true } }
    else if foreign { if outlets >= t.foreign { return true } }
    else if outlets >= t.chinese { return true }
    return level != .strict && breaking && foreign && outlets >= 4 && primary >= 2
}

func isStrongDisaster(_ event: WorldEvent) -> Bool { event.disaster && ((event.magnitude ?? 0) >= 7 || event.severity == "红色预警") }

// MARK: - The followed view

struct FollowAnalysis: Sendable {
    /// 关注对象 and 大事 rows, newest first by first report. Each row is one story's display headline.
    var rows: [WorldEvent] = []
    /// Topic id → that topic's rows, newest first.
    var byTopic: [String: [WorldEvent]] = [:]
    var majors: [WorldEvent] { rows.filter { $0.major == true } }
}

let followRetention: TimeInterval = 72 * 3600
let majorRetention: TimeInterval = 24 * 3600

/// Turns stories into the followed view.
/// - Topic stories need at least one primary outlet or two outlets, and a factual (non-commentary) headline;
///   a single-outlet story also needs an action verb or rumor wording. Market ticks are hidden unless the topic asks for them.
/// - Other stories appear only when they pass the big-event gate within 24 hours.
/// - The display headline prefers a primary outlet, then the cluster lead, then a Chinese title, then the first report.
func followAnalysis(_ result: StoryResult, topics: [FollowTopic], level: MajorLevel = .standard, disasters: [WorldEvent] = [],
                    filter: NewsFilter = NewsFilter(), now: Date = Date()) -> FollowAnalysis {
    let matcher = TopicMatcher(topics)
    let topicByID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
    var rows: [WorldEvent] = []
    for story in result.stories {
        let members = story.memberIDs.compactMap { result.events[$0] }.filter { !$0.disaster }
        guard !members.isEmpty else { continue }
        let first = story.firstDate ?? members.compactMap(\.date).min() ?? story.firstObserved
        let age = now.timeIntervalSince(first)
        guard age <= followRetention else { continue }
        let factual = members.filter { !isNonEventHeadline($0) && !isSoftNews($0) }
        let multi = story.outlets.count >= 2
        // One outlet alone must report an action, or carry unconfirmed wording that earns the 「据报道」 label.
        let reports = multi ? factual : factual.filter { isEventHeadline($0) || isRumorHeadline($0) }
        guard !reports.isEmpty else { continue }
        let news = reports.filter { !isMarketTick($0) }
        let tickOnly = news.isEmpty
        // A topic belongs to the story when two outlets mention it, or at least half of them do:
        // one stray headline in a large cluster should not tag the whole story.
        var support: [String: Set<String>] = [:]
        var memberTopics: [String: [String]] = [:]
        for member in members {
            let ids = matcher.topicIDs(member)
            memberTopics[member.id] = ids
            for id in ids { support[id, default: []].insert(storyOutlet(member) ?? member.sourceID) }
        }
        let outletCount = max(1, story.outlets.count)
        let topicIDs = topics.map(\.id).filter { id in
            guard let outlets = support[id], outlets.count >= 2 || Double(outlets.count) * 2 >= Double(outletCount) else { return false }
            return !tickOnly || topicByID[id]?.showTicks == true
        }
        let primary = Set(members.filter { outletTier($0) == .primary }.compactMap(storyOutlet))
        let chinese = members.contains { containsHan($0.title) }, foreign = members.contains { !containsHan($0.title) }
        let breaking = (story.breakingUntil ?? .distantPast) > now
        let major = !tickOnly && age <= majorRetention && isMajorStory(outlets: story.outlets.count, chinese: chinese, foreign: foreign, breaking: breaking, primary: primary.count, level: level)
        let topical = !topicIDs.isEmpty && (!primary.isEmpty || multi)
        guard topical || major else { continue }
        let candidates = tickOnly ? reports : news
        let display = candidates.min { a, b in
            if topical {
                let ma = !(memberTopics[a.id] ?? []).isEmpty, mb = !(memberTopics[b.id] ?? []).isEmpty
                if ma != mb { return ma }
            }
            let ta = outletTier(a), tb = outletTier(b)
            if ta != tb { return ta < tb }
            if (a.id == story.leadID) != (b.id == story.leadID) { return a.id == story.leadID }
            let ca = a.translatedTitle != nil || containsHan(a.title), cb = b.translatedTitle != nil || containsHan(b.title)
            if ca != cb { return ca }
            let da = a.date ?? .distantFuture, db = b.date ?? .distantFuture
            return da != db ? da < db : a.id < b.id
        }!
        var row = display
        row.storyID = story.id
        row.storyOutlets = multi ? story.outlets : nil
        row.storyHeat = multi ? story.heat : nil
        row.storyLead = true
        row.storyFirstDate = first
        row.breakingUntil = story.breakingUntil
        row.followTopics = topicIDs.isEmpty ? nil : (topical ? topicIDs : nil)
        row.major = major ? true : nil
        row.primaryOutlets = primary.count
        row.factNote = isRumorHeadline(display) && primary.count < 2 ? "据报道" : nil
        if filter.mode == .personal, newsFilterBlocks(row, filter: filter) { continue }
        rows.append(row)
    }
    for event in disasters where isStrongDisaster(event) {
        guard let date = event.date, now.timeIntervalSince(date) <= majorRetention, now.timeIntervalSince(date) >= -3600 else { continue }
        var row = event
        row.major = true
        row.storyFirstDate = date
        rows.append(row)
    }
    rows.sort { a, b in
        let da = a.storyFirstDate ?? a.date ?? .distantPast, db = b.storyFirstDate ?? b.date ?? .distantPast
        return da != db ? da > db : a.id < b.id
    }
    var byTopic: [String: [WorldEvent]] = [:]
    for row in rows { for id in row.followTopics ?? [] { byTopic[id, default: []].append(row) } }
    return FollowAnalysis(rows: rows, byTopic: byTopic)
}

/// Widget fallback when the app has not published a followed list for two hours: keyword matching over the
/// retained headlines, factual headlines only, plus strong disasters. No outlet counts without the story index.
func followedFallback(_ events: [WorldEvent], topics: [FollowTopic], now: Date = Date()) -> [WorldEvent] {
    let matcher = TopicMatcher(topics)
    let rows = mergedEvents(events, now: now).compactMap { event -> WorldEvent? in
        if isStrongDisaster(event) {
            guard let date = event.date, now.timeIntervalSince(date) <= majorRetention else { return nil }
            var row = event; row.major = true; return row
        }
        guard !event.disaster, isEventHeadline(event), !isSoftNews(event), !isMarketTick(event) else { return nil }
        let ids = matcher.topicIDs(event)
        guard !ids.isEmpty else { return event.major == true ? event : nil }
        var row = event; row.followTopics = ids; return row
    }
    return Array(collapsedStories(rows).prefix(40))
}

/// Followed rows for a widget entry: the app's list while fresh, otherwise the keyword fallback.
func followedPool(_ snapshot: NewsSnapshot, now: Date = Date(), topics: [FollowTopic] = FollowTopic.selected) -> [WorldEvent] {
    let fresh = snapshot.updatedAt.map { now.timeIntervalSince($0) <= 2 * 3600 } ?? false
    if fresh, let rows = snapshot.followedEvents { return rows }
    let all = snapshot.sourceFeeds?.values.flatMap(\.events) ?? snapshot.rotationEvents ?? snapshot.events
    return followedFallback(all, topics: topics, now: now)
}

// MARK: - Alerts (2.11)

struct AlertSettings: Codable, Equatable, Sendable {
    var major = true
    var topics = true
    var quiet = true
    var quietStart = 23
    var quietEnd = 7
    static var selected: AlertSettings {
        get {
            guard let data = WorldPreferences.shared.data(forKey: "alertSettings"), let value = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return AlertSettings() }
            return value
        }
        set { if let data = try? JSONEncoder().encode(newValue) { WorldPreferences.shared.set(data, forKey: "alertSettings") } }
    }
    func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard quiet, quietStart != quietEnd else { return false }
        let hour = calendar.component(.hour, from: date)
        return quietStart < quietEnd ? (hour >= quietStart && hour < quietEnd) : (hour >= quietStart || hour < quietEnd)
    }
}

struct AlertLedger: Codable, Equatable, Sendable {
    var sent: [String: Date] = [:]
    var seeded = false
    var delivered: [Date] = []
    var byTopic: [String: [Date]] = [:]
    /// Story key → when it first passed the big-event gate (see `promotedRows`).
    var majorSince: [String: Date] = [:]
    init(sent: [String: Date] = [:], seeded: Bool = false, delivered: [Date] = [], byTopic: [String: [Date]] = [:], majorSince: [String: Date] = [:]) {
        self.sent = sent; self.seeded = seeded; self.delivered = delivered; self.byTopic = byTopic; self.majorSince = majorSince
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decodeIfPresent([String: Date].self, forKey: .sent) ?? [:]
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        delivered = try c.decodeIfPresent([Date].self, forKey: .delivered) ?? []
        byTopic = try c.decodeIfPresent([String: [Date]].self, forKey: .byTopic) ?? [:]
        majorSince = try c.decodeIfPresent([String: Date].self, forKey: .majorSince) ?? [:]
    }
}

/// The time a row is ordered and judged fresh by: when it became a big event, else its first report.
func attentionDate(_ row: WorldEvent) -> Date { row.promotedAt ?? row.storyFirstDate ?? row.date ?? .distantPast }

private let promotionSeeded = "_seeded"

/// Stamps big events with the time they first passed the gate and reorders the list by it, so a story that grows
/// into a big event hours after its first report still rises to the top. The first run stamps existing big events
/// with their first-report time, so an upgrade does not lift them all at once. Stamps are kept for two days.
func promotedRows(_ rows: [WorldEvent], since: [String: Date], now: Date = Date()) -> (rows: [WorldEvent], since: [String: Date]) {
    var since = since.filter { $0.key == promotionSeeded || now.timeIntervalSince($0.value) <= 2 * 86400 }
    let seeding = since[promotionSeeded] == nil
    since[promotionSeeded] = now
    let stamped = rows.map { row -> WorldEvent in
        guard row.major == true else { return row }
        let key = alertKey(row), first = row.storyFirstDate ?? row.date ?? now
        if since[key] == nil { since[key] = seeding ? first : max(first, now) }
        var copy = row
        copy.promotedAt = since[key]
        return copy
    }
    let ordered = stamped.sorted { a, b in
        let da = attentionDate(a), db = attentionDate(b)
        return da != db ? da > db : a.id < b.id
    }
    return (ordered, since)
}

let alertFreshness: TimeInterval = 3 * 3600
let alertsPerPass = 3, alertsPerHour = 6, alertsPerDay = 24, alertsPerTopicHour = 2

func alertKey(_ row: WorldEvent) -> String { row.storyID ?? row.id }

/// Which rows deserve a notification: big events, and followed-topic stories confirmed by two outlets including
/// a primary one. Each story at most once, only while under three hours old, never during quiet hours, within
/// per-pass, hourly, daily and per-topic caps. The first run only records what is already there.
func alertDecision(rows: [WorldEvent], topics: [FollowTopic], settings: AlertSettings, ledger: AlertLedger, now: Date = Date(), calendar: Calendar = .current) -> (send: [WorldEvent], ledger: AlertLedger) {
    var ledger = ledger
    ledger.sent = ledger.sent.filter { now.timeIntervalSince($0.value) <= 4 * 86400 }
    ledger.delivered = ledger.delivered.filter { now.timeIntervalSince($0) <= 86400 }
    ledger.byTopic = ledger.byTopic.mapValues { $0.filter { now.timeIntervalSince($0) <= 3600 } }.filter { !$0.value.isEmpty }
    let alerting = Set(topics.filter(\.alerts).map(\.id))
    func alertTopics(_ row: WorldEvent) -> [String] { (row.followTopics ?? []).filter(alerting.contains) }
    func eligible(_ row: WorldEvent) -> Bool {
        if row.major == true && settings.major { return true }
        guard settings.topics, !alertTopics(row).isEmpty else { return false }
        return (row.storyOutlets?.count ?? 1) >= 2 && (row.primaryOutlets ?? 0) >= 1
    }
    let candidates = rows.filter { eligible($0) && ledger.sent[alertKey($0)] == nil }
    if !ledger.seeded {
        for row in candidates { ledger.sent[alertKey(row)] = now }
        ledger.seeded = true
        return ([], ledger)
    }
    guard !settings.isQuiet(now, calendar: calendar) else { return ([], ledger) }
    let fresh = candidates.filter { now.timeIntervalSince(attentionDate($0)) <= alertFreshness }.sorted { a, b in
        if (a.major == true) != (b.major == true) { return a.major == true }
        let oa = a.storyOutlets?.count ?? 1, ob = b.storyOutlets?.count ?? 1
        if oa != ob { return oa > ob }
        return attentionDate(a) > attentionDate(b)
    }
    var send: [WorldEvent] = []
    for row in fresh {
        guard send.count < alertsPerPass, ledger.delivered.count < alertsPerDay,
              ledger.delivered.filter({ now.timeIntervalSince($0) <= 3600 }).count < alertsPerHour else { break }
        let ids = row.major == true ? [] : alertTopics(row)
        if ids.contains(where: { (ledger.byTopic[$0]?.count ?? 0) >= alertsPerTopicHour }) { continue }
        send.append(row)
        ledger.sent[alertKey(row)] = now
        ledger.delivered.append(now)
        for id in ids { ledger.byTopic[id, default: []].append(now) }
    }
    return (send, ledger)
}

/// Notification text: title is 「大事」 or the topic names, body the headline with its outlet count.
func alertContent(_ row: WorldEvent, topics: [FollowTopic]) -> (title: String, body: String) {
    let label = row.major == true ? (topicLabel(row.followTopics, topics: topics).map { "大事 · " + $0 } ?? "大事") : (topicLabel(row.followTopics, topics: topics) ?? "关注")
    let count = row.storyOutlets.map { " · \($0.count) 家媒体" } ?? (row.severity.map { " · " + $0 } ?? "")
    return (label, (row.factNote.map { "【\($0)】" } ?? "") + row.displayTitle + count)
}

// MARK: - Topic history (2.12)

/// A followed story kept after it leaves the 72-hour index, so a topic page reaches back two weeks.
struct TopicHistoryItem: Codable, Sendable {
    var event: WorldEvent
    var topics: [String]
    var firstDate: Date
    var outlets: Int
}

let topicHistoryRetention: TimeInterval = 14 * 86400
let topicHistoryPerTopic = 300

func mergedTopicHistory(_ history: [TopicHistoryItem], rows: [WorldEvent], now: Date = Date()) -> [TopicHistoryItem] {
    var byKey: [String: TopicHistoryItem] = [:]
    for item in history { byKey[alertKey(item.event)] = item }
    for row in rows {
        guard let topics = row.followTopics, !topics.isEmpty else { continue }
        var compact = row
        compact.storyOutlets = nil; compact.storyHeat = nil
        byKey[alertKey(row)] = TopicHistoryItem(event: compact, topics: topics, firstDate: row.storyFirstDate ?? row.date ?? now, outlets: row.storyOutlets?.count ?? 1)
    }
    var counts: [String: Int] = [:]
    return byKey.values.filter { now.timeIntervalSince($0.firstDate) <= topicHistoryRetention }
        .sorted { $0.firstDate != $1.firstDate ? $0.firstDate > $1.firstDate : $0.event.id < $1.event.id }
        .filter { item in
            let keep = item.topics.contains { (counts[$0] ?? 0) < topicHistoryPerTopic }
            if keep { for id in item.topics { counts[id, default: 0] += 1 } }
            return keep
        }
}

/// A topic page: live rows first-hand, then older history that the live index no longer holds.
func topicTimeline(_ topicID: String, live: [WorldEvent], history: [TopicHistoryItem]) -> [WorldEvent] {
    let rows = live.filter { $0.followTopics?.contains(topicID) == true }
    var keys = Set(rows.map(alertKey)), titles = Set(rows.map { topicMatchText($0.displayTitle) }), urls = Set(rows.map { canonicalNewsURL($0.url) })
    var older: [WorldEvent] = []
    for item in history where item.topics.contains(topicID) {
        let key = alertKey(item.event), title = topicMatchText(item.event.displayTitle), url = canonicalNewsURL(item.event.url)
        guard !keys.contains(key), !titles.contains(title), !urls.contains(url) else { continue }
        keys.insert(key); titles.insert(title); urls.insert(url)
        var row = item.event
        row.storyFirstDate = item.firstDate
        row.historyOutlets = item.outlets
        older.append(row)
    }
    return (rows + older).sorted { ($0.storyFirstDate ?? $0.date ?? .distantPast) > ($1.storyFirstDate ?? $1.date ?? .distantPast) }
}

/// Day headings for a topic page: 今天、昨天、11月12日.
func dayLabel(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
    return date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_CN")).month(.defaultDigits).day().weekday(.abbreviated))
}

// MARK: - Event page (2.12)

struct EventSides: Sendable {
    var chinese: [WorldEvent] = []
    var foreign: [WorldEvent] = []
    var primaryOutlets = 0
}

/// Members split into Chinese-language and foreign media, each in report order, one headline per outlet.
func eventSides(_ members: [WorldEvent]) -> EventSides {
    var sides = EventSides()
    var seen = Set<String>(), primary = Set<String>()
    for member in members.sorted(by: { ($0.date ?? .distantFuture, $0.id) < ($1.date ?? .distantFuture, $1.id) }) {
        let outlet = storyOutlet(member) ?? member.sourceID
        if outletTier(member) == .primary { primary.insert(outlet) }
        guard seen.insert(outlet).inserted else { continue }
        if containsHan(member.title) { sides.chinese.append(member) } else { sides.foreign.append(member) }
    }
    sides.primaryOutlets = primary.count
    return sides
}
