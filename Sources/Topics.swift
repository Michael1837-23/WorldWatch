import Foundation

// 关注追踪（2.10–2.14）: followed topics, outlet tiers, fact labels, the big-event gate, big-event ordering and topic history.
// Pure functions shared by the app, the widgets and Tests/TopicCheck.swift. Plan and measurements: docs/路线图.md.
// The 2.11 notifications were removed in 2.14 at the user's request; the app no longer asks for notification permission.

// MARK: - Topics

struct FollowTopic: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    /// Any alias is enough: Chinese terms match as substrings (simplified/traditional folded), English as whole words.
    var aliases: [String]
    /// Issue topics also match when every group has a hit, e.g. 台湾 together with one of 大陆、解放军、北京.
    var pairs: [[String]] = []
    /// Phrases removed before matching: 苹果日报 is a newspaper, not Apple.
    var excludes: [String] = []
    /// Google News search queries that fill in coverage for this topic.
    var queryZH: String = ""
    var queryEN: String = ""
    /// Index and share-price moves are hidden unless asked for.
    var showTicks = false

    init(id: String, name: String, aliases: [String], pairs: [[String]] = [], excludes: [String] = [], queryZH: String = "", queryEN: String = "", showTicks: Bool = false) {
        self.id = id; self.name = name; self.aliases = aliases; self.pairs = pairs; self.excludes = excludes
        self.queryZH = queryZH; self.queryEN = queryEN; self.showTicks = showTicks
        if self.queryZH.isEmpty || self.queryEN.isEmpty { fillQueries() }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? [name]
        pairs = try c.decodeIfPresent([[String]].self, forKey: .pairs) ?? []
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        queryZH = try c.decodeIfPresent(String.self, forKey: .queryZH) ?? ""
        queryEN = try c.decodeIfPresent(String.self, forKey: .queryEN) ?? ""
        showTicks = try c.decodeIfPresent(Bool.self, forKey: .showTicks) ?? false
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
                    queryZH: "台海 OR 两岸 OR 国台办", queryEN: "Taiwan China OR \"Taiwan Strait\""),
        // 2.14. 以军 is left out: it is also part of 可以军事、以军事手段.
        FollowTopic(id: "mideast", name: "中东局势", aliases: ["以色列", "伊朗", "加沙", "哈马斯", "真主党", "胡塞", "内塔尼亚胡", "哈梅内伊", "德黑兰", "霍尔木兹",
                                                       "黎巴嫩", "叙利亚", "也门", "约旦河西岸", "巴勒斯坦",
                                                       "Israel", "Israeli", "Iran", "Iranian", "Gaza", "Hamas", "Hezbollah", "Houthi", "Houthis", "Netanyahu", "Khamenei",
                                                       "Tehran", "IDF", "Hormuz", "Lebanon", "Lebanese", "Syria", "Syrian", "Yemen", "West Bank", "Palestinian", "Palestinians"],
                    queryZH: "伊朗 OR 以色列 OR 加沙 OR 黎巴嫩", queryEN: "Iran OR Israel OR Gaza OR Lebanon"),
        // 奥特曼 alone is also Ultraman, so it needs company context.
        FollowTopic(id: "openai", name: "OpenAI", aliases: ["OpenAI", "ChatGPT", "Sam Altman", "Altman", "奥尔特曼", "阿尔特曼"],
                    pairs: [["奥特曼"], ["山姆", "萨姆", "CEO", "首席执行官", "GPT", "AGI", "大模型", "微软", "马斯克", "估值", "融资", "IPO"]],
                    queryZH: "OpenAI OR ChatGPT", queryEN: "OpenAI OR \"Sam Altman\""),
        // Claude is also a first name (Claude Monet), so alone it needs AI context.
        FollowTopic(id: "anthropic", name: "Anthropic", aliases: ["Anthropic", "Dario Amodei", "Amodei", "阿莫代"],
                    pairs: [["Claude"], ["AI", "人工智能", "大模型", "模型", "聊天机器人", "chatbot", "Opus", "Sonnet", "编程", "coding", "智能体", "agent", "agents"]],
                    queryZH: "Anthropic OR Claude", queryEN: "Anthropic OR \"Dario Amodei\""),
        // Bare 苹果 is also the fruit and 库克 also the Cook Islands: either needs the other or a company word.
        FollowTopic(id: "apple", name: "苹果", aliases: ["苹果公司", "苹果手机", "Apple", "iPhone", "iPad", "MacBook", "Vision Pro", "App Store", "Tim Cook", "蒂姆·库克"],
                    pairs: [["苹果"], ["库克", "iPhone", "iPad", "Mac", "iOS", "Siri", "CEO", "首席执行官", "AI", "芯片", "手机", "折叠屏", "应用商店", "市值", "股价", "美股",
                                       "财报", "营收", "发布会", "欧盟", "反垄断", "罚款", "关税", "供应链", "富士康", "特朗普", "微软", "谷歌", "英伟达", "三星", "华为"]],
                    excludes: ["苹果日报", "Apple Daily", "Big Apple", "Apple TV", "Apple Music"],
                    queryZH: "苹果公司 OR iPhone OR 库克", queryEN: "Apple OR iPhone OR \"Tim Cook\""),
        // Robotaxi is left out: Waymo, Baidu and Pony.ai run robotaxis too.
        FollowTopic(id: "tesla", name: "特斯拉", aliases: ["特斯拉", "Tesla", "Cybertruck", "Cybercab"], queryZH: "特斯拉", queryEN: "Tesla"),
        FollowTopic(id: "tsmc", name: "台积电", aliases: ["台积电", "TSMC", "魏哲家", "C.C. Wei"], queryZH: "台积电", queryEN: "TSMC")
    ]
    static let limit = 20

    /// Presets added after a list was saved, appended once unless the list already covers them (same id, or a name or alias in common).
    static func adding(_ ids: [String], to list: [FollowTopic]) -> [FollowTopic] {
        var list = list
        for preset in presets where ids.contains(preset.id) && list.count < limit {
            let words = Set(([preset.name] + preset.aliases).map(topicMatchText))
            guard !list.contains(where: { $0.id == preset.id || !words.isDisjoint(with: ([$0.name] + $0.aliases).map(topicMatchText)) }) else { continue }
            list.append(preset)
        }
        return list
    }
    static func read(from defaults: UserDefaults) -> [FollowTopic] {
        guard let data = defaults.data(forKey: "followTopics"), let topics = try? JSONDecoder().decode([FollowTopic].self, from: data) else { return presets }
        return topics
    }
    static var selected: [FollowTopic] {
        get { read(from: WorldPreferences.shared) }
        set { if let data = try? JSONEncoder().encode(Array(newValue.prefix(limit))) { WorldPreferences.shared.set(data, forKey: "followTopics") } }
    }
}

/// Presets that arrived after lists were saved, each batch with the flag that marks a saved list as extended.
let newPresetBatches: [(flag: String, ids: [String])] = [("topicsV213", ["openai", "apple"]), ("topicsV214", ["mideast", "anthropic", "tesla", "tsmc"])]

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
    private let compiled: [(id: String, any: Terms, pairs: [Terms], excludes: [(original: String, folded: String)])]
    let topics: [FollowTopic]
    init(_ topics: [FollowTopic]) {
        self.topics = topics
        compiled = topics.map { topic in
            let excludes = topic.excludes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { ($0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0, topicMatchText($0)) }
            return (topic.id, Terms(topic.aliases), topic.pairs.map(Terms.init).filter { !$0.isEmpty }, excludes)
        }
    }
    var isEmpty: Bool { topics.isEmpty }
    /// Ids of the topics any of the texts mention, in topic order.
    func topicIDs(_ texts: [String]) -> [String] {
        guard !compiled.isEmpty else { return [] }
        let pairs = texts.map { ($0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0, topicMatchText($0)) }
        return compiled.filter { topic in
            pairs.contains { original, folded in
                var original = original, folded = folded
                for phrase in topic.excludes {
                    original = original.replacingOccurrences(of: phrase.original, with: " ", options: .caseInsensitive)
                    folded = folded.replacingOccurrences(of: phrase.folded, with: " ")
                }
                return topic.any.hit(original: original, folded: folded) || (!topic.pairs.isEmpty && topic.pairs.allSatisfy { $0.hit(original: original, folded: folded) })
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
    "social news xyz", "coincentral", "ad hoc news", "finimize", "simply wall", "trefis", "nasdaq.com", "investorplace", "gobankingrates",
    // Gadget tips, deals and fan blogs: real Apple or Nvidia news also reaches the wires, these add how-tos and rumors.
    "9to5mac", "9to5google", "appleinsider", "macrumors", "imore", "cult of mac", "applemagazine", "apple world today", "macdailynews", "idropnews",
    "lifehacker", "man of many", "bgr", "tom's guide", "tom’s guide", "phonearena", "gsmarena", "wccftech", "notebookcheck", "android authority",
    "android central", "slashgear", "pocket-lint", "tvline", "decider", "biggo", "fxleaders"
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

private let tickPattern = try! NSRegularExpression(pattern: #"(?:涨|跌|升|降|涨幅|跌幅|反弹|回落|拉升|下挫|走高|走低)\s*(?:超|逾|近|约|达)?\s*\d+(?:\.\d+)?\s*%|高开|低开|股指|收高|收低|跳水|现报|盘前|盘后|盘中|收涨|收跌|收盘|开盘|日内|涨停|跌停|市值(?:蒸发|增加|突破|跌破|超过)|股价|评级|目标价|三大(?:股)?指数|美股收盘|芯片股|科技股|概念股|半导体股|权重股|单?周(?:涨|跌)幅|(?:全线|集体)(?:上涨|下跌|大涨|大跌|走高|走低)|\b(?:shares?|stocks?|futures|nasdaq|s&p)\b[^.]{0,40}\b(?:rise|rises|rose|fall|falls|fell|jump|jumps|jumped|slide|slides|slid|drop|drops|dropped|surge|surges|surged|tumble|tumbles|tumbled|climb|climbs|climbed|sink|sinks|sank|gain|gains|gained|rally|rallies|rallied|plunge|plunges|plunged|soar|soars|soared|slump|slumps|slumped)\b|\bprice target\b|\bintraday\b|\ball-time highs?\b|\b(?:buy|sell|hold|overweight|underweight) rating\b|\bstock (?:price|forecast|prediction)\b|\bshould you buy\b|\bpremarket\b|\bafter[- ]hours\b"#, options: .caseInsensitive)

/// Index and share-price moves, ratings and price targets: market noise rather than news about the topic.
func isMarketTick(_ event: WorldEvent) -> Bool {
    [event.title, event.translatedTitle].compactMap { $0 }.contains { tickPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
}

private let rumorPattern = try! NSRegularExpression(pattern: #"或将|或于|或在|传出|传闻|市场消息|市场传闻|据悉|消息人士|知情人士|据报道|报道称|据称|网传|爆料|古尔曼|郭明錤|郭明𫓹|\bGurman\b|Ming-Chi Kuo|\breportedly\b|\bsources? (?:say|said|says)\b|\bpeople familiar\b|\bsaid to\b|\bin talks\b|\bweighs?\b|\bconsidering\b|\bcould announce\b|\bmay announce\b|\brumou?rs?\b|[:：]\s*report$|\breport says\b"#, options: .caseInsensitive)

/// Unconfirmed wording: talks, sources, "或将". Shown with a 「据报道」 label until two primary outlets carry the story.
func isRumorHeadline(_ event: WorldEvent) -> Bool {
    [event.title, event.translatedTitle].compactMap { $0 }.contains { rumorPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
}

private let softNewsPattern = try! NSRegularExpression(pattern: #"农博会|花博会|博览会|展销|巡展|作品展|文化节|艺术节|音乐节|联谊|研学|夏令营|冬令营|网友共创|共创视频|见面会|宣讲|侧记|随笔|综述|述评|社评|网评|时评|快评|锐评|评论员|新闻会客厅|学习贯彻|主题教育|党性|交流活动|座谈会|推介会|年会|周报|周刊|速览|早知道|晨报|晚报|午报|深一度|横评|评测|测评|上手|开箱|怎么选|如何选|选购|攻略|教程|小技巧|好物|种草|测试版|以旧换新|划不划算|值不值得?|配置推荐|分析[:：]|影响分析|深度分析|解读|能否|会否|何去何从|意味着什么|怎么看|^[^丨｜|]{0,8}(?:观察|评论|视点|聚焦|调查|解码|读懂)[丨｜|]"#)

// Analysis and features in English: listicles, explainers, two-sentence feature headlines ("… knew. Now some wonder …").
private let featurePattern = try! NSRegularExpression(pattern: #"\b(?:names to watch|what to (?:know|watch|expect)|things to know|here'?s (?:what|why|how|the fix)|the rise and fall|what (?:we|you) know|explained|analysis|opinion|takeaways|lessons from|comes back to bite|a (?:tougher|bigger) test|tips (?:and|&) tricks|hands-on|first look|unboxing|buying guide|stream it or skip it|recap|premiere|trailer|should know|gift guide|gift ideas|holiday gift|gift to beat|black friday|cyber monday|prime day|beta)\b|\bhas an? [\w' -]{1,30} problem\b|^how to\b|\b(?:ios|ipados|macos|tvos|watchos|visionos) \d+\.\d+|^\d+ (?:names|things|ways|reasons|takeaways|questions|charts|people|tips|tricks|features|apps|deals)\b"#, options: .caseInsensitive)
private let twoSentencePattern = try! NSRegularExpression(pattern: #"[a-z]{2,}[.!?]\s+[A-Z][a-z]"#)
// Roundups and newsletters ("A; B; C"), seminars and "交出答卷" style pieces.
private let chineseRoundupPattern = try! NSRegularExpression(pattern: #"梳理|盘点|回顾|复盘|一文|细数|全解析|时间线|研讨会|交流会|恳谈会|答卷|[;；][^;；]+[;；]"#)

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
                    filter: NewsFilter = NewsFilter(), now: Date = Date(), joinRows: Bool = true) -> FollowAnalysis {
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
        // A topic belongs to the story when at least half of the outlets mention it, or two and a quarter of them do:
        // a couple of stray headlines in a large cluster should not tag the whole story.
        var support: [String: Set<String>] = [:]
        var memberTopics: [String: [String]] = [:]
        for member in members {
            let ids = matcher.topicIDs(member)
            memberTopics[member.id] = ids
            for id in ids { support[id, default: []].insert(storyOutlet(member) ?? member.sourceID) }
        }
        let outletCount = max(1, story.outlets.count)
        let topicIDs = topics.map(\.id).filter { id in
            guard let outlets = support[id], Double(outlets.count) * 2 >= Double(outletCount) || (outlets.count >= 2 && outlets.count * 4 >= outletCount) else { return false }
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
    if joinRows { rows = threadedRows(rows, result: result, topics: topics, level: level, now: now) }
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

// MARK: - One row per event (2.14)

/// Clustering keeps a launch's preview, the launch and its outcome apart, and Chinese and foreign wording apart: on
/// 2026-11-14 the Starship flight filled about 40 rows. Rows join when they share a followed topic and their stories'
/// wording is close — the cosine of IDF-weighted story centroids, with the topics' own names and context words left
/// out — at 0.30 within a day, or at 0.18 within six hours for a story from one or two outlets. Rows without a topic
/// (big events) join at 0.30 only. Measurements: docs/acceptance/升级验收记录-2.14.md.
let threadThreshold = 0.30
let threadSmallThreshold = 0.18
let threadWindow: TimeInterval = 24 * 3600
let threadSmallWindow: TimeInterval = 6 * 3600

/// Words a topic is recognised by, as story terms: every row of the topic shares them, so they say nothing about which event.
private func topicTerms(_ topic: FollowTopic) -> Set<String> {
    var terms = Set<String>()
    for word in [topic.name] + topic.aliases + topic.pairs.flatMap({ $0 }) {
        terms.formUnion(storyBigrams(topicMatchText(word)).map { "z" + $0 })
        terms.formUnion(storyWords(word).map { "e" + $0 })
    }
    return terms
}

/// Joins rows about the same event (see `threadThreshold`). Deterministic; disasters pass through unchanged.
func threadedRows(_ rows: [WorldEvent], result: StoryResult, topics: [FollowTopic], level: MajorLevel = .standard, now: Date = Date()) -> [WorldEvent] {
    guard rows.count > 1 else { return rows }
    // Terms come from clustering; a hand-built result (tests) falls back to the same features without name tagging.
    func fallbackTerms(_ event: WorldEvent) -> Set<String> {
        var f = StoryFeatures()
        let chinese = event.translatedTitle ?? (isChineseSource(event.sourceID) ? event.title : nil)
        f.grams = storyBigrams(stripStoryBoilerplate(chinese ?? event.title))
        if !isChineseSource(event.sourceID) { f.words = storyWords(stripStoryBoilerplate(event.title)) }
        return storyTerms(f)
    }
    var termsOf = result.terms
    var df: [String: Int] = [:]
    var count = 0
    for event in result.events.values where !event.disaster {
        if termsOf[event.id] == nil { termsOf[event.id] = fallbackTerms(event) }
        for term in termsOf[event.id]! { df[term, default: 0] += 1 }
        count += 1
    }
    let n = Double(max(count, 1))
    let removed = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, topicTerms($0)) })
    let storyByID = Dictionary(result.stories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func stories(_ row: WorldEvent) -> [NewsStory] {
        ([row.storyID].compactMap { $0 } + (row.threadStoryIDs ?? [])).compactMap { storyByID[$0] ?? result.story(for: $0) }
    }
    func vector(_ row: WorldEvent) -> [String: Double] {
        let drop = (row.followTopics ?? []).reduce(into: Set<String>()) { $0.formUnion(removed[$1] ?? []) }
        let members = stories(row).flatMap(\.memberIDs).compactMap { result.events[$0] }.filter { !$0.disaster }
        var v: [String: Double] = [:]
        for member in members.isEmpty ? [row] : members {
            let kept = (termsOf[member.id] ?? fallbackTerms(member)).subtracting(drop).sorted()
            let weights = kept.map { log(n / Double(max(df[$0] ?? 1, 1))) }
            let norm = sqrt(weights.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            for (term, weight) in zip(kept, weights) { v[term, default: 0] += weight / norm }
        }
        return v
    }
    func outlets(_ row: WorldEvent) -> Int { row.storyOutlets?.count ?? 1 }
    func first(_ row: WorldEvent) -> Date { row.storyFirstDate ?? row.date ?? now }
    struct Thread { var rows: [Int]; var centroid: [String: Double]; var normSq: Double; var topics: Set<String>; var firsts: [Date] }
    // Widest stories first, so each event is seeded by its best-covered story.
    let order = rows.indices.filter { !rows[$0].disaster }.sorted { a, b in
        if outlets(rows[a]) != outlets(rows[b]) { return outlets(rows[a]) > outlets(rows[b]) }
        return first(rows[a]) != first(rows[b]) ? first(rows[a]) < first(rows[b]) : rows[a].id < rows[b].id
    }
    var threads: [Thread] = []
    for i in order {
        let row = rows[i], v = vector(row), keys = v.keys.sorted()
        let selfSq = keys.reduce(0) { $0 + v[$1]! * v[$1]! }
        let rowTopics = Set(row.followTopics ?? [])
        var best = -1, bestScore = 0.0, bestDot = 0.0
        for (t, thread) in threads.enumerated() where selfSq > 0 && thread.normSq > 0 {
            let topical = !rowTopics.isEmpty && !thread.topics.isEmpty
            if topical && rowTopics.isDisjoint(with: thread.topics) { continue }
            let gap = thread.firsts.map { abs($0.timeIntervalSince(first(row))) }.min() ?? .infinity
            guard gap <= threadWindow else { continue }
            var dot = 0.0
            for k in keys { if let y = thread.centroid[k] { dot += v[k]! * y } }
            let score = dot / sqrt(thread.normSq * selfSq)
            let joins = score >= threadThreshold || (topical && outlets(row) <= 2 && gap <= threadSmallWindow && score >= threadSmallThreshold)
            if joins && score > bestScore { best = t; bestScore = score; bestDot = dot }
        }
        if best < 0 {
            threads.append(Thread(rows: [i], centroid: v, normSq: selfSq, topics: rowTopics, firsts: [first(row)]))
            continue
        }
        threads[best].rows.append(i)
        threads[best].normSq += 2 * bestDot + selfSq
        for k in keys { threads[best].centroid[k, default: 0] += v[k]! }
        threads[best].topics.formUnion(rowTopics)
        threads[best].firsts.append(first(row))
    }
    let topicOrder = topics.map(\.id)
    var output = rows.filter(\.disaster)
    for thread in threads {
        let group = thread.rows.map { rows[$0] }
        guard group.count > 1 else { output.append(group[0]); continue }
        // Shown: the latest development that a third of the widest story's outlets (and at least three) covered,
        // so a launch's outcome replaces its preview; the key stays the widest story's.
        let widest = group[0]
        let wide = group.filter { outlets($0) >= max(3, outlets(widest) / 3) }
        let shown = (wide.isEmpty ? [widest] : wide).max { (first($0), $1.id) < (first($1), $0.id) }!
        var row = shown
        let storyList = group.flatMap(stories)
        var seen = Set<String>(), names: [String] = []
        for story in storyList { for name in story.outlets where seen.insert(name).inserted { names.append(name) } }
        let members = storyList.flatMap(\.memberIDs).compactMap { result.events[$0] }.filter { !$0.disaster }
        let primary = Set(members.filter { outletTier($0) == .primary }.compactMap(storyOutlet))
        row.storyID = widest.storyID
        row.threadStoryIDs = group.dropFirst().compactMap(\.storyID) + group.flatMap { $0.threadStoryIDs ?? [] }
        row.storyOutlets = names.count >= 2 ? names : shown.storyOutlets
        row.storyHeat = group.compactMap(\.storyHeat).max()
        row.storyLead = true
        row.breakingUntil = group.compactMap(\.breakingUntil).max()
        let union = Set(group.flatMap { $0.followTopics ?? [] })
        row.followTopics = union.isEmpty ? nil : topicOrder.filter(union.contains)
        row.primaryOutlets = max(primary.count, group.compactMap(\.primaryOutlets).max() ?? 0)
        row.factNote = isRumorHeadline(shown) && (row.primaryOutlets ?? 0) < 2 ? "据报道" : nil
        // Counted together the event may pass the big-event gate that no single story passed.
        let chinese = members.contains { containsHan($0.title) }, foreign = members.contains { !containsHan($0.title) }
        let gate = !group.allSatisfy(isMarketTick) && now.timeIntervalSince(first(shown)) <= majorRetention
            && isMajorStory(outlets: names.count, chinese: chinese, foreign: foreign, breaking: (row.breakingUntil ?? .distantPast) > now, primary: primary.count, level: level)
        row.major = group.contains { $0.major == true } || gate ? true : nil
        output.append(row)
    }
    return output
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

// MARK: - Big-event ordering (2.11)

/// The key a followed row is remembered by: its story id, else the headline id.
func storyKey(_ row: WorldEvent) -> String { row.storyID ?? row.id }

/// The time a row is ordered by: when it became a big event or the first report of what it shows, whichever is later
/// (a joined row shows its latest development).
func attentionDate(_ row: WorldEvent) -> Date { max(row.promotedAt ?? .distantPast, row.storyFirstDate ?? row.date ?? .distantPast) }

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
        let key = storyKey(row), first = row.storyFirstDate ?? row.date ?? now
        // A joined row keeps the stamp of any story folded into it, so a change of key does not lift it again.
        if since[key] == nil { since[key] = (row.threadStoryIDs ?? []).compactMap { since[$0] }.min() ?? (seeding ? first : max(first, now)) }
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

/// Reads the promotion stamps saved by 2.11–2.13 inside the notification ledger (alert-ledger.json).
struct LegacyAlertLedger: Decodable {
    var majorSince: [String: Date]?
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

/// Saved history is the live rows plus what has left the story index. While a headline is still indexed the live
/// view is authoritative: an item saved under a story id that clustering has since changed, or for a story that no
/// longer qualifies, is dropped instead of showing next to its current version.
func mergedTopicHistory(_ history: [TopicHistoryItem], rows: [WorldEvent], indexed: (String) -> Bool = { _ in false }, now: Date = Date()) -> [TopicHistoryItem] {
    var byKey: [String: TopicHistoryItem] = [:]
    for item in history where !indexed(item.event.id) && !indexed(storyKey(item.event)) { byKey[storyKey(item.event)] = item }
    for row in rows {
        guard let topics = row.followTopics, !topics.isEmpty else { continue }
        var compact = row
        compact.storyOutlets = nil; compact.storyHeat = nil; compact.threadStoryIDs = nil
        byKey[storyKey(row)] = TopicHistoryItem(event: compact, topics: topics, firstDate: row.storyFirstDate ?? row.date ?? now, outlets: row.storyOutlets?.count ?? 1)
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
    var keys = Set(rows.flatMap { [storyKey($0)] + ($0.threadStoryIDs ?? []) }), titles = Set(rows.map { topicMatchText($0.displayTitle) }), urls = Set(rows.map { canonicalNewsURL($0.url) })
    var older: [WorldEvent] = []
    for item in history where item.topics.contains(topicID) {
        let key = storyKey(item.event), title = topicMatchText(item.event.displayTitle), url = canonicalNewsURL(item.event.url)
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
