import Foundation
import Darwin

enum NewsCategory: String, CaseIterable, Sendable {
    case domestic = "国内", world = "国际", politics = "政治", finance = "财经"
    case technology = "科技", entertainment = "文娱", sports = "体育", disaster = "灾害"
}

struct NewsSource: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL
    let detail: String
    let disaster: Bool
    var category: NewsCategory = .world
    var domestic: Bool = false
    var language: String = "en"
    /// The feed stamps every item with the same placeholder clock time (UN News uses 12:00 UTC), so only the date is real.
    var dateOnly = false
    /// Aggregator feeds (Google News) carry the real publisher in `<source>`; it is shown and counted as the outlet.
    var aggregator = false
    static let all: [NewsSource] = [
        .init(id: "bbc-zh", name: "BBC 中文", url: URL(string: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml")!, detail: "中文国际报道", disaster: false),
        .init(id: "bbc", name: "BBC World", url: URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!, detail: "全球国际新闻 · 英文", disaster: false),
        .init(id: "guardian", name: "The Guardian", url: URL(string: "https://www.theguardian.com/world/rss")!, detail: "国际报道 · 英文", disaster: false),
        .init(id: "cns-china", name: "中新网·国内", url: URL(string: "https://www.chinanews.com.cn/rss/china.xml")!, detail: "国内时政与公共事务 · 中文", disaster: false, category: .domestic, domestic: true),
        .init(id: "cns-society", name: "中新网·社会", url: URL(string: "https://www.chinanews.com.cn/rss/society.xml")!, detail: "国内社会与民生 · 中文", disaster: false, category: .domestic, domestic: true),
        .init(id: "cns-world", name: "中新网·国际", url: URL(string: "https://www.chinanews.com.cn/rss/world.xml")!, detail: "国际报道 · 中文", disaster: false),
        .init(id: "cns-finance", name: "中新网·财经", url: URL(string: "https://www.chinanews.com.cn/rss/finance.xml")!, detail: "国内财经与产业 · 中文", disaster: false, category: .finance, domestic: true),
        .init(id: "cns-culture", name: "中新网·文化", url: URL(string: "https://www.chinanews.com.cn/rss/culture.xml")!, detail: "国内文化、影视与演出 · 中文", disaster: false, category: .entertainment, domestic: true),
        .init(id: "bbc-business", name: "BBC·财经", url: URL(string: "https://feeds.bbci.co.uk/news/business/rss.xml")!, detail: "全球商业与金融 · 英文", disaster: false, category: .finance),
        .init(id: "bbc-tech", name: "BBC·科技", url: URL(string: "https://feeds.bbci.co.uk/news/technology/rss.xml")!, detail: "科技与数字产业 · 英文", disaster: false, category: .technology),
        .init(id: "bbc-culture", name: "BBC·文娱", url: URL(string: "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml")!, detail: "影视、音乐与文化 · 英文", disaster: false, category: .entertainment),
        .init(id: "bbc-sport", name: "BBC·体育", url: URL(string: "https://feeds.bbci.co.uk/sport/rss.xml")!, detail: "全球体育赛事 · 英文", disaster: false, category: .sports),
        .init(id: "guardian-business", name: "Guardian·财经", url: URL(string: "https://www.theguardian.com/business/rss")!, detail: "市场、经济与企业 · 英文", disaster: false, category: .finance),
        .init(id: "guardian-tech", name: "Guardian·科技", url: URL(string: "https://www.theguardian.com/technology/rss")!, detail: "科技公司、AI 与平台 · 英文", disaster: false, category: .technology),
        .init(id: "guardian-culture", name: "Guardian·文化", url: URL(string: "https://www.theguardian.com/culture/rss")!, detail: "艺术、影视与文化 · 英文", disaster: false, category: .entertainment),
        .init(id: "cnbc", name: "CNBC", url: URL(string: "https://www.cnbc.com/id/100003114/device/rss/rss.html")!, detail: "国际财经快讯 · 英文", disaster: false, category: .finance),
        .init(id: "techcrunch", name: "TechCrunch", url: URL(string: "https://techcrunch.com/feed/")!, detail: "AI、创业与科技产业 · 英文", disaster: false, category: .technology),
        .init(id: "variety", name: "Variety", url: URL(string: "https://variety.com/feed/")!, detail: "影视娱乐与传媒产业 · 英文", disaster: false, category: .entertainment),
        .init(id: "dw", name: "DW", url: URL(string: "https://rss.dw.com/rdf/rss-en-all")!, detail: "德国之声国际报道 · 英文", disaster: false),
        .init(id: "france24", name: "France 24", url: URL(string: "https://www.france24.com/en/rss")!, detail: "法国国际新闻 · 英文", disaster: false),
        .init(id: "npr", name: "NPR News", url: URL(string: "https://feeds.npr.org/1001/rss.xml")!, detail: "美国公共广播新闻 · 英文", disaster: false),
        .init(id: "cna", name: "中央通讯社", url: URL(string: "https://feeds.feedburner.com/rsscna/intworld")!, detail: "中央社国际新闻 · 中文", disaster: false, language: "zh"),
        .init(id: "nyt", name: "NYT World", url: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/World.xml")!, detail: "纽约时报国际报道 · 英文", disaster: false),
        .init(id: "aljazeera", name: "Al Jazeera", url: URL(string: "https://www.aljazeera.com/xml/rss/all.xml")!, detail: "半岛电视台国际报道 · 英文", disaster: false),
        .init(id: "defense", name: "Defense News", url: URL(string: "https://www.defensenews.com/arc/outboundfeeds/rss/?outputType=xml")!, detail: "国防与军事产业 · 英文", disaster: false, category: .politics),
        .init(id: "gn-zh", name: "Google 新闻·要闻", url: URL(string: "https://news.google.com/rss?hl=zh-CN&gl=CN&ceid=CN:zh-Hans")!, detail: "中文媒体要闻聚合 · 显示原媒体", disaster: false, language: "zh", aggregator: true),
        .init(id: "gn-zh-world", name: "Google 新闻·国际", url: URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGx1YlY4U0JYcG9MVU5PR2dKRFRpZ0FQAQ?hl=zh-CN&gl=CN&ceid=CN:zh-Hans")!, detail: "中文国际新闻聚合 · 显示原媒体", disaster: false, language: "zh", aggregator: true),
        .init(id: "gn-world", name: "Google News World", url: URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGx1YlY4U0JXVnVMVlZUR2dKVlV5Z0FQAQ?hl=en-US&gl=US&ceid=US:en")!, detail: "路透、美联社等英文国际新闻聚合 · 显示原媒体", disaster: false, aggregator: true),
        .init(id: "un", name: "联合国新闻", url: URL(string: "https://news.un.org/feed/subscribe/en/news/all/rss.xml")!, detail: "联合国官方新闻 · 英文", disaster: false, dateOnly: true),
        .init(id: "usgs", name: "USGS", url: URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_week.geojson")!, detail: "近七天显著地震 · 官方数据", disaster: true),
        .init(id: "gdacs", name: "GDACS", url: URL(string: "https://www.gdacs.org/xml/rss.xml")!, detail: "橙色／红色灾害预警", disaster: true)
    ]
}

struct WorldEvent: Identifiable, Codable, Sendable {
    let id: String
    let sourceID: String
    let title: String
    let url: URL
    let date: Date?
    let timeKind: String
    let disaster: Bool
    let severity: String?
    var translatedTitle: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var magnitude: Double? = nil
    var eventType: String? = nil
    var endDate: Date? = nil
    var publisher: String? = nil
    // Story facts copied in by the app (Sources/Stories.swift); absent when the widget fetched on its own.
    var storyID: String? = nil
    var storyOutlets: [String]? = nil
    var storyHeat: Double? = nil
    var storyLead: Bool? = nil
    var storyFirstDate: Date? = nil
    var breakingUntil: Date? = nil
    // Followed-view facts (Sources/Topics.swift), set by the app on the rows it publishes.
    var followTopics: [String]? = nil
    var major: Bool? = nil
    var primaryOutlets: Int? = nil
    var factNote: String? = nil
    var historyOutlets: Int? = nil
    /// When a story first passed the big-event gate; big events are ordered by it so a story that grows into one rises.
    var promotedAt: Date? = nil
    /// Further stories about the same event, folded into this row (2.14); the row's own story is `storyID`.
    var threadStoryIDs: [String]? = nil
    var displayTitle: String { translatedTitle ?? title }
    var sourceName: String { publisher ?? NewsSource.find(sourceID)?.name ?? sourceID }
    var isDomestic: Bool { NewsSource.find(sourceID)?.domestic ?? false }
    var category: NewsCategory {
        if disaster { return .disaster }
        let fallback = NewsSource.find(sourceID)?.category ?? .world
        guard fallback == .world || fallback == .domestic else { return fallback }
        let text = title.lowercased()
        if text.range(of: #"\b(elections?|president|prime minister|parliament|ceasefire|sanctions|military|war|treaty|summit)\b|选举|選舉|大选|大選|总统|總統|国务院|國務院|外交|军事|軍事|停火|制裁|峰会|峰會"#, options: .regularExpression) != nil { return .politics }
        return fallback
    }
    var isNoteworthy: Bool {
        if disaster { return true }
        let title = self.title.lowercased()
        let historical = ["first world war", "second world war", "第一次世界大战", "第二次世界大战", "第一次世界大戰", "第二次世界大戰"]
        if historical.contains(where: title.contains) { return false }
        let chinese = ["战争", "戰爭", "冲突", "衝突", "空袭", "空襲", "导弹", "導彈", "核武", "军事", "軍事", "停火", "政变", "政變", "恐袭", "恐襲", "爆炸", "地震", "海啸", "海嘯", "台风", "颱風", "洪水", "洪灾", "洪災", "山火", "火山", "疫情", "大选", "大選", "选举", "選舉", "总统", "總統", "首相", "总理", "總理", "制裁", "关税", "關稅", "央行", "降息", "加息", "金融危机", "金融危機", "股市暴跌", "违约", "違約", "紧急状态", "緊急狀態", "峰会", "峰會", "条约", "條約"]
        if chinese.contains(where: title.contains) { return true }
        let pattern = #"\b(war|conflict|military|missiles?|nuclear|invasion|airstrikes?|coup|terrorist|terror|shooting|killed|hostages?|ceasefire|peace deal|sanctions|elections?|referendum|president|prime minister|pandemic|outbreak|emergency|earthquake|tsunami|eruption|hurricane|typhoon|cyclone|floods?|wildfires?|interest rates?|recession|sovereign default|bank collapse|stock market crash|tariffs?|summit|treaty)\b"#
        return title.range(of: pattern, options: .regularExpression) != nil
    }
}

enum NewsFilterMode: String, Codable, CaseIterable, Sendable {
    case all, personal
    var title: String { self == .all ? "全部新闻" : "个性新闻" }
}

func normalizedKeyword(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? trimmed).lowercased()
}

func cleanedKeywords(_ words: [String]) -> [String] {
    var seen = Set<String>()
    return words.compactMap { word in
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedKeyword(trimmed)
        return !key.isEmpty && seen.insert(key).inserted ? trimmed : nil
    }.prefix(50).map { $0 }
}

struct NewsFilter: Codable, Equatable, Sendable {
    var mode: NewsFilterMode = .all
    var excludedCategories: Set<String> = []
    var excludedSources: Set<String> = []
    var followed: [String] = []
    var blocked: [String] = []
    var followOnly = false
    var eventOnly: Bool? = nil
    var eventsOnly: Bool { eventOnly ?? false }

    var cleaned: NewsFilter {
        var copy = self
        copy.followed = cleanedKeywords(followed)
        copy.blocked = cleanedKeywords(blocked)
        return copy
    }
    static func read(from defaults: UserDefaults) -> NewsFilter {
        guard let data = defaults.data(forKey: "newsFilter"), let filter = try? JSONDecoder().decode(NewsFilter.self, from: data) else { return NewsFilter() }
        return filter.cleaned
    }
    static var selected: NewsFilter {
        get { read(from: WorldPreferences.shared) }
        set { if let data = try? JSONEncoder().encode(newValue.cleaned) { WorldPreferences.shared.set(data, forKey: "newsFilter") } }
    }
}

// ponytail: headline patterns cannot determine intent perfectly; refine using real false positives.
private let nonEventHeadlinePatterns = [
    #"^\s*(?:opinion|analysis|commentary|interview|profile|explainer|podcast|review)\s*[:：–—-]"#,
    #"\b(?:i|i'm|i've|my|me|we|our)\b.{0,100}\s[-–—]\s"#,
    #"\b(?:review|opinion|commentary)\s*[–—-]|\|\s*[^|]{3,40}$|\bin pictures\s*$|^\s*(?:tv tonight|friday briefing)\s*[:：]"#,
    #"^\s*(?:专访|访谈|人物|人物志|评论|观点|专栏|解读|观察|盘点|揭秘|如何|为何|为什么|什么是|一文读懂)"#,
    #"(?:人物专访|深度访谈|独家专访|破局之道|从来没有像我这样的人)"#,
    #"^\s*[^：:]{1,12}(?:印象|观察)[：:]|^\s*[（(]乡村行|[？?]\s*$"#,
    // Features led by a quotation ('From blue to blue': …, “从薪水到薪水”：…) and why/how after a colon.
    #"^\s*[\"'‘“「][^：:]{1,30}[\"'’”」]\s*[：:]"#,
    #"[：:]\s*(?:why|how|what)\b|[：:]\s*(?:为什么|为何|如何|怎样)"#,
    #"(?:走进|探访|巡游|打卡|之旅|背后的|的故事|慢表达|看见|寻味|漫步)"#,
    #"\b(?:says?|said)\s+(?:she|he|they|i)\s+(?:loved?|likes?|enjoy|felt|feels|wanted|hopes?)\b|说[，,]?\s*(?:她|他)(?:喜欢|热爱|享受|希望)"#,
    // Question-led headlines, podcasts and prescriptions are commentary, not reports.
    #"^\s*(?:can|will|is|are|do|does|should|could|would|has|have)\b[^?]*\?|^\s*(?:listen|watch|live)\s*[:：]|\b(?:must|should)\s+(?:be|not)\b"#,
    #"(?:新路径|新模式|新篇章|新气象|新答卷|的底气|的坚守|见证中国)"#,
    // Newspaper editorials ("The Guardian view on …").
    #"^\s*the [\w ]{1,30} view on\b"#,
    // Anticipation rather than something that already happened.
    #"\b(?:set to|braces? for|fears?|plans? (?:for|to)|to (?:spread|sweep))\b|担心|将(?:蔓延|席卷)|做准备|计划"#
].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
private let explanatoryQuestion = try! NSRegularExpression(pattern: #"(?:^|[.!?]\s+)\s*(?:how|why|what|who|where)\b"#, options: .caseInsensitive)
private let reportedAction = try! NSRegularExpression(pattern: #"\b(?:killed|injured|wounded|attacked|bombed|arrested|strikes|airstrikes|forced to flee)\b"#, options: .caseInsensitive)

// "Something happened": an action or outcome verb. Speech verbs (says, 表示, 称) are deliberately absent,
// so quote-only headlines need another action to count as events.
private let eventActionPattern = try! NSRegularExpression(pattern: #"\b(?:kill(?:s|ed)?|dies|died|dead|injur(?:es|ed)|wound(?:s|ed)|attack(?:s|ed)|bomb(?:s|ed|ing)|strikes?|struck|shoot(?:s|ing)|shot|arrest(?:s|ed)|detain(?:s|ed)|charg(?:es|ed)|convict(?:s|ed)|sentenc(?:es|ed)|jail(?:s|ed)|sues?|sued|crash(?:es|ed)|collid(?:es|ed)|explo(?:des|ded|sion)|erupts?|hits?|floods?|burn(?:s|ed)|collaps(?:es|ed)|evacuat(?:es|ed)|win(?:s)?|won|beat(?:s)?|stuns?|stunned|defeat(?:s|ed)?|upset|clinch(?:es|ed)|elect(?:s|ed)|vot(?:es|ed)|pass(?:es|ed)|approv(?:es|ed)|reject(?:s|ed)|ban(?:s|ned)|sign(?:s|ed)|launch(?:es|ed)|unveil(?:s|ed)|announc(?:es|ed)|releas(?:es|ed)|issu(?:es|ed)|open(?:s|ed)|clos(?:es|ed)|resign(?:s|ed)|fir(?:es|ed)|appoint(?:s|ed)|nam(?:es|ed)|meet(?:s)?|met|visit(?:s|ed)|agree(?:s|d)?|deal|seiz(?:es|ed)|raid(?:s|ed)|invad(?:es|ed)|captur(?:es|ed)|withdraw(?:s|n)?|cut(?:s)?|rais(?:es|ed)|hik(?:es|ed)|surg(?:es|ed)|plung(?:es|ed)|soar(?:s|ed)|tumbl(?:es|ed)|ris(?:es|en)|rose|fall(?:s|en)?|fell|drop(?:s|ped)|jump(?:s|ed)|slump(?:s|ed)|record(?:s|ed)?|acquir(?:es|ed)|buy(?:s)?|bought|sell(?:s)?|sold|merg(?:es|ed)|lay(?:s)? off|halt(?:s|ed)|suspend(?:s|ed)|block(?:s|ed)|recall(?:s|ed)|land(?:s|ed)|held|holds?|kick(?:s|ed) off|ends?|ended|begins?|began|starts?|started|confirm(?:s|ed)|report(?:s|ed)|warn(?:s|ed)|order(?:s|ed)|deploy(?:s|ed)|fin(?:es|ed)|grant(?:s|ed)|award(?:s|ed)|scor(?:es|ed)|qualif(?:ies|ied)|retir(?:es|ed)|fail(?:s|ed)?|gather(?:s|ed)|rall(?:y|ies|ied)|protest(?:s|ed)|defect(?:s|ed)|host(?:s|ed)|derail(?:s|ed)|downgrad(?:es|ed)|upgrad(?:es|ed)|fle(?:e|es|d)|forced|displac(?:es|ed)|blockad(?:es|ed)|chok(?:es|ed) off|guts|ax(?:es|ed)|scrap(?:s|ped)?|delay(?:s|ed)|postpon(?:es|ed)|quits?|exits?|steps? down|stepped down|oust(?:s|ed)|prob(?:es|ed)|investigat(?:es|ed|ing)|summon(?:s|ed)|subpoena(?:s|ed)|testif(?:ies|ied)|dock(?:s|ed)|recover(?:s|ed)|caught|expand(?:s|ed)|shut(?:s)? down|restrict(?:s|ed)|impos(?:es|ed)|lift(?:s|ed)|extend(?:s|ed)|pledg(?:es|ed)|threaten(?:s|ed)|accus(?:es|ed)|deni(?:es|ed)|offer(?:s|ed)|propos(?:es|ed)|invest(?:s|ed)|outage|disrupt(?:s|ed))\b|发生|主办|公映|上映|放映|逃离|首演|首映|首发|开工|竣工|揭牌|挂牌|齐聚|出轨|脱轨|撞上|调降|下调|上调|通报|接受审查|被查|落马|新高|新低|举行|举办|召开|开幕|闭幕|发布|发行|宣布|公布|出台|实施|签署|通过|批准|否决|当选|任命|辞职|会见|会谈|访问|抵达|启动|开通|成立|落地|投产|遇难|死亡|身亡|受伤|袭击|爆炸|坠毁|相撞|起火|失火|地震|洪水|击败|战胜|夺冠|获胜|晋级|逮捕|拘留|起诉|判处|罚款|上涨|下跌|大涨|大跌|暴跌|飙升|收购|裁员|停产|停飞|撤离|撤军|部署|增兵|空袭|发射|试射|宣判|破获|查处|立案|降息|加息|突破|创下|刷新纪录|请辞|卸任|离任|解雇|撤换|调查|传唤|作证|加征|致电|通话|会晤|磋商|谈判|达成|交火|击落|拦截|试飞|回收|入轨|对接|上线|推出|暂停|恢复|延长|取消|证实|披露|曝光|遇袭|遭袭|中断|停电|宕机|故障"#, options: .caseInsensitive)

/// Events-only keeps headlines that report something that happened: an action verb and no feature, opinion
/// or interview marker. Disasters always count. This is a title heuristic, not a semantic classifier.
func isEventHeadline(_ event: WorldEvent) -> Bool {
    if event.disaster { return true }
    if isNonEventHeadline(event) { return false }
    return [event.title, event.translatedTitle].compactMap { $0 }.contains { title in
        eventActionPattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }
}

func isNonEventHeadline(_ event: WorldEvent) -> Bool {
    guard !event.disaster else { return false }
    return [event.title, event.translatedTitle].compactMap { $0 }.contains { title in
        let range = NSRange(title.startIndex..., in: title)
        if nonEventHeadlinePatterns.contains(where: { $0.firstMatch(in: title, range: range) != nil }) { return true }
        return explanatoryQuestion.firstMatch(in: title, range: range) != nil && reportedAction.firstMatch(in: title, range: range) == nil
    }
}

private struct KeywordMatcher {
    let substrings: [String]
    let expressions: [NSRegularExpression]
    init(_ words: [String]) {
        let normalized = cleanedKeywords(words).map(normalizedKeyword)
        substrings = normalized.filter { !$0.unicodeScalars.allSatisfy(\.isASCII) }
        expressions = normalized.filter { $0.unicodeScalars.allSatisfy(\.isASCII) }.compactMap { word in
            try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9_])")
        }
    }
    var isEmpty: Bool { substrings.isEmpty && expressions.isEmpty }
    func matches(_ text: String) -> Bool {
        if substrings.contains(where: text.contains) { return true }
        let range = NSRange(text.startIndex..., in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}

private struct NewsFilterMatcher {
    let filter: NewsFilter
    let followed: KeywordMatcher
    let blocked: KeywordMatcher
    init(_ filter: NewsFilter) {
        self.filter = filter
        followed = KeywordMatcher(filter.followed)
        blocked = KeywordMatcher(filter.blocked)
    }
    func allows(_ event: WorldEvent) -> Bool {
        if filter.mode != .personal { return !filter.eventsOnly || isEventHeadline(event) }
        let titles = followed.isEmpty && blocked.isEmpty ? [] : [event.title, event.translatedTitle].compactMap { $0 }.map(normalizedKeyword)
        if titles.contains(where: blocked.matches) { return false }
        let matchesFollowed = titles.contains(where: followed.matches)
        if filter.eventsOnly && !matchesFollowed && !isEventHeadline(event) { return false }
        if filter.followOnly { return matchesFollowed }
        return matchesFollowed || (!filter.excludedCategories.contains(event.category.rawValue) && !filter.excludedSources.contains(event.sourceID))
    }
}

/// Blocked keywords alone (personal mode), for lists that do their own selection such as the followed view.
func newsFilterBlocks(_ event: WorldEvent, filter: NewsFilter) -> Bool {
    let blocked = KeywordMatcher(filter.blocked)
    guard filter.mode == .personal, !blocked.isEmpty else { return false }
    return [event.title, event.translatedTitle].compactMap { $0 }.map(normalizedKeyword).contains(where: blocked.matches)
}

func newsFilterAllows(_ event: WorldEvent, filter: NewsFilter) -> Bool {
    NewsFilterMatcher(filter).allows(event)
}

func applyNewsFilter(_ events: [WorldEvent], filter: NewsFilter) -> [WorldEvent] {
    guard filter.mode == .personal || filter.eventsOnly else { return events }
    let matcher = NewsFilterMatcher(filter)
    return events.filter(matcher.allows)
}

struct SourceSnapshot: Codable, Sendable {
    var events: [WorldEvent]
    var fetchedAt: Date
}

enum NewsDisplayMode: String, Codable, CaseIterable, Sendable {
    case followed, latest, rotation, hot
    var title: String { self == .followed ? "关注优先" : self == .latest ? "最新优先" : self == .rotation ? "综合轮播" : "热点优先" }
    private static var preferences: UserDefaults {
        let group = Bundle.main.object(forInfoDictionaryKey: "WorldWatchAppGroup") as? String
        return group.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static var selected: NewsDisplayMode {
        get { NewsDisplayMode(rawValue: preferences.string(forKey: "widgetDisplayMode") ?? "") ?? .followed }
        set { preferences.set(newValue.rawValue, forKey: "widgetDisplayMode") }
    }
}

struct NewsSnapshot: Codable, Sendable {
    var date: Date
    var events: [WorldEvent]
    var availableSources: Int
    var note: String?
    var sourceFeeds: [String: SourceSnapshot]? = nil
    var changedAt: Date? = nil
    var lastSuccess: Date? = nil
    var enabledSourceIDs: [String]? = nil
    var checkedAt: Date? = nil
    var rotationEvents: [WorldEvent]? = nil
    var rotationPage: Int? = nil
    var rotationPageCount: Int? = nil
    var displayMode: NewsDisplayMode? = nil
    var updatedAt: Date? = nil
    var conflictSignals: [ConflictSignal]? = nil
    /// The app's followed view (关注对象 + 大事), at most 40 rows; widgets fall back to keyword matching when stale.
    var followedEvents: [WorldEvent]? = nil
    var mode: NewsDisplayMode { displayMode ?? .latest }
    var checkDate: Date { checkedAt ?? date }
    var revisionDate: Date { max(checkDate, updatedAt ?? checkDate) }
}

struct SourceFetchResult: Sendable {
    let id: String
    let events: [WorldEvent]?
    var fetchedAt: Date? = nil
}

let retainedNewsLimit = 100

/// Caps ordinary news at the newest `retainedNewsLimit`. Earthquake and disaster feeds are exempt: their
/// occurrence times are usually older than the news stream, so a shared cap would drop every map marker.
func limitedSourceFeeds(_ feeds: [String: SourceSnapshot]) -> [String: SourceSnapshot] {
    let disasterIDs = Set(NewsSource.all.filter(\.disaster).map(\.id))
    // Lead headlines of multi-outlet stories are exempt too, so the hottest stories survive the cap.
    func isLead(_ event: WorldEvent) -> Bool { event.storyLead == true && (event.storyOutlets?.count ?? 0) >= 2 }
    let leads = feeds.filter { !disasterIDs.contains($0.key) }.flatMap { id, feed in feed.events.filter(isLead).map { (id, $0) } }
    let latest = feeds.filter { !disasterIDs.contains($0.key) }.flatMap { id, feed in feed.events.filter { !isLead($0) }.map { (id, $0) } }.sorted {
        let first = $0.1.date ?? .distantPast, second = $1.1.date ?? .distantPast
        if first != second { return first > second }
        if $0.1.id != $1.1.id { return $0.1.id < $1.1.id }
        return $0.0 < $1.0
    }.prefix(retainedNewsLimit)
    let grouped = Dictionary(grouping: Array(latest) + leads, by: { $0.0 })
    return feeds.mapValues { feed in
        var result = feed
        result.events = []
        return result
    }.merging(feeds.filter { disasterIDs.contains($0.key) }) { _, kept in kept }.merging(grouped.mapValues { items in
        SourceSnapshot(events: items.map { $0.1 }, fetchedAt: feeds[items[0].0]!.fetchedAt)
    }) { _, selected in selected }
}

func digestTopic(_ event: WorldEvent) -> String? {
    let title = event.title.lowercased()
    guard title.range(of: #"\b(elections?|polls|vot(e|es|ing)|turnout|runoff)\b|选举|選舉|大选|大選"#, options: .regularExpression) != nil else { return nil }
    // ponytail: conservative title rules for election coverage, not semantic event identification.
    let locations = ["israel": ["israel", "以色列"], "brazil": ["brazil", "巴西"], "usa": ["united states", "u.s.", "美国", "美國"], "uk": ["british", "united kingdom", "英国", "英國"], "france": ["france", "french", "法国", "法國"], "germany": ["german", "德国", "德國"], "japan": ["japan", "日本"], "taiwan": ["taiwan", "台湾", "台灣"], "india": ["india", "印度"], "russia": ["russia", "俄罗斯", "俄羅斯"]]
    return locations.keys.sorted().first { key in locations[key]!.contains(where: title.contains) }.map { "election:" + $0 }
}

func canonicalNewsURL(_ url: URL) -> String {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    parts.fragment = nil
    parts.queryItems = parts.queryItems?.filter { !($0.name.lowercased().hasPrefix("utm_") || ["cmp", "cmpid", "ocid"].contains($0.name.lowercased())) }
    if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
    return parts.string ?? url.absoluteString
}

func headlineTokens(_ title: String) -> Set<String> {
    let lower = title.lowercased()
    let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
    let han = Array(lower.unicodeScalars.filter { (0x3400...0x9fff).contains(Int($0.value)) })
    var tokens = Set(words.filter { !["the", "and", "for", "with", "from", "that", "this", "after", "over"].contains($0) })
    if han.count > 1 { for i in 0..<(han.count - 1) { tokens.insert(String(han[i]) + String(han[i + 1])) } }
    return tokens
}

func uniqueNewsEvents(_ events: [WorldEvent], perCategory: Int? = nil, mergeTopics: Bool = true, now: Date = Date()) -> [WorldEvent] {
    var topics = Set<String>(), titles = Set<String>(), urls = Set<String>()
    var fingerprintSizes: [Int] = []
    var tokenIndex: [String: [Int]] = [:]
    var categoryCounts: [NewsCategory: Int] = [:]
    return mergedEvents(events, now: now).filter { event in
        if let perCategory, categoryCounts[event.category, default: 0] >= perCategory { return false }
        let normalized = event.title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        guard !titles.contains(normalized), !urls.contains(canonicalNewsURL(event.url)) else { return false }
        if mergeTopics, let topic = digestTopic(event), topics.contains(topic) { return false }
        let tokens = headlineTokens(event.title)
        // ponytail: token index preserves the Jaccard rule; cross-language semantic duplicates may remain.
        if tokens.count >= 4 {
            var common: [Int: Int] = [:]
            for token in tokens {
                for index in tokenIndex[token] ?? [] {
                    let size = fingerprintSizes[index]
                    if Double(min(size, tokens.count)) / Double(max(size, tokens.count)) >= 0.65 {
                        common[index, default: 0] += 1
                    }
                }
            }
            if common.contains(where: { index, count in
                Double(count) / Double(max(1, tokens.count + fingerprintSizes[index] - count)) >= 0.65
            }) { return false }
        }
        titles.insert(normalized); urls.insert(canonicalNewsURL(event.url))
        let index = fingerprintSizes.count
        fingerprintSizes.append(tokens.count)
        for token in tokens { tokenIndex[token, default: []].append(index) }
        categoryCounts[event.category, default: 0] += 1
        if let topic = digestTopic(event) { topics.insert(topic) }
        return true
    }
}

/// Chinanews' four domestic feeds publish dozens of items each during Beijing daytime while Europe and
/// America sleep, so a pure time order fills the latest list with domestic news. This caps their share.
enum DomesticShare: String, CaseIterable, Sendable {
    case less = "少", balanced = "均衡", unlimited = "不限"
    var ratio: Double? { self == .less ? 0.2 : self == .balanced ? 1.0 / 3 : nil }
    private static var preferences: UserDefaults {
        let group = Bundle.main.object(forInfoDictionaryKey: "WorldWatchAppGroup") as? String
        return group.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static var selected: DomesticShare {
        get { DomesticShare(rawValue: preferences.string(forKey: "domesticShare") ?? "") ?? .balanced }
        set { preferences.set(newValue.rawValue, forKey: "domesticShare") }
    }
}

/// Keeps time order but defers domestic items once they exceed the ratio; deferred items follow later, none are dropped.
func balancedByOrigin(_ events: [WorldEvent], ratio: Double?) -> [WorldEvent] {
    guard let ratio else { return events }
    var result: [WorldEvent] = [], deferred: [WorldEvent] = [], domestic = 0
    for event in events {
        if event.isDomestic { deferred.append(event) } else { result.append(event) }
        while let next = deferred.first, Double(domestic + 1) <= (ratio * Double(result.count + 1)).rounded(.up) {
            result.append(next); deferred.removeFirst(); domestic += 1
        }
    }
    return result + deferred
}

func latestEvents(_ events: [WorldEvent], limit: Int = 64, now: Date = Date(), domesticRatio: Double? = DomesticShare.selected.ratio, filter: NewsFilter = NewsFilter()) -> [WorldEvent] {
    Array(balancedByOrigin(collapsedStories(uniqueNewsEvents(applyNewsFilter(events, filter: filter), mergeTopics: false, now: now)), ratio: domesticRatio).prefix(limit))
}

func displayPool(_ events: [WorldEvent], mode: NewsDisplayMode, now: Date = Date(), filter: NewsFilter = NewsFilter()) -> [WorldEvent] {
    switch mode {
    case .latest: return latestEvents(events, now: now, filter: filter)
    case .rotation: return digestPool(events, now: now, filter: filter)
    case .hot: return hotEvents(events, now: now, filter: filter)
    case .followed: return followedFallback(events, topics: FollowTopic.selected, now: now).filter { !newsFilterBlocks($0, filter: filter) }
    }
}

func digestPool(_ events: [WorldEvent], perCategory: Int = 8, now: Date = Date(), filter: NewsFilter = NewsFilter()) -> [WorldEvent] {
    let unique = collapsedStories(uniqueNewsEvents(applyNewsFilter(events, filter: filter), perCategory: perCategory, now: now))
    let grouped = Dictionary(grouping: unique, by: \.category)
    let order: [NewsCategory] = [.domestic, .world, .finance, .technology, .entertainment, .politics, .sports, .disaster]
    var result: [WorldEvent] = []
    for index in 0..<perCategory {
        for category in order {
            if let items = grouped[category], items.count > index { result.append(items[index]) }
        }
    }
    return result
}

func digestEvents(_ events: [WorldEvent], limit: Int = 4, now: Date = Date()) -> [WorldEvent] {
    Array(digestPool(events, now: now).prefix(limit))
}

func rotationEvents(_ pool: [WorldEvent], at date: Date, limit: Int = 4) -> (events: [WorldEvent], page: Int, count: Int) {
    guard !pool.isEmpty, limit > 0 else { return ([], 0, 0) }
    let count = (pool.count + limit - 1) / limit
    let page = Int(date.timeIntervalSince1970 / 60) % count
    return (Array(pool.dropFirst(page * limit).prefix(limit)), page + 1, count)
}

func rotationTimeline(_ snapshot: NewsSnapshot, now: Date = Date(), minutes: Int = 60, pageSize: Int = 4) -> [NewsSnapshot] {
    let pool = mergedEvents(snapshot.rotationEvents ?? snapshot.events, now: now)
    // Keep the category-balanced order; mergedEvents above only supplies retention checks.
    let retained = Set(pool.map(\.id))
    let ordered = (snapshot.rotationEvents ?? snapshot.events).filter { retained.contains($0.id) }
    let start = floor(now.timeIntervalSince1970 / 60) * 60
    return (0..<max(1, minutes)).map { offset in
        var entry = snapshot
        entry.checkedAt = snapshot.checkDate
        entry.date = offset == 0 ? now : Date(timeIntervalSince1970: start + Double(offset * 60))
        let page = rotationEvents(ordered, at: entry.date, limit: pageSize)
        entry.events = page.events; entry.rotationPage = page.page; entry.rotationPageCount = page.count
        entry.rotationEvents = nil
        entry.conflictSignals = nil
        // Timeline entries only need freshness metadata, not another copy of every feed.
        entry.sourceFeeds = snapshot.sourceFeeds?.mapValues { SourceSnapshot(events: [], fetchedAt: $0.fetchedAt) }
        return entry
    }
}

func widgetTimeline(_ snapshot: NewsSnapshot, now: Date = Date(), pageSize: Int = 4, filter: NewsFilter = NewsFilter()) -> [NewsSnapshot] {
    let all = snapshot.sourceFeeds?.values.flatMap(\.events) ?? snapshot.rotationEvents ?? snapshot.events
    let mode = effectiveDisplayMode(snapshot, now: now)
    if mode == .rotation {
        var rotating = snapshot
        rotating.rotationEvents = digestPool(all, now: now, filter: filter)
        if (filter.mode == .personal || filter.eventsOnly) && rotating.rotationEvents?.isEmpty == true { rotating.note = filter.mode == .personal ? "没有符合个性设置的新闻" : "没有符合过滤条件的新闻" }
        return rotationTimeline(rotating, now: now, pageSize: pageSize)
    }
    var entry = snapshot
    entry.checkedAt = snapshot.checkDate
    entry.date = now
    switch mode {
    case .hot: entry.events = Array(hotEvents(all, now: now, filter: filter).prefix(pageSize))
    case .followed: entry.events = Array(followedPool(snapshot, now: now).filter { !newsFilterBlocks($0, filter: filter) }.prefix(pageSize))
    default: entry.events = latestEvents(all, limit: pageSize, now: now, filter: filter)
    }
    entry.displayMode = mode
    if mode == .followed && entry.events.isEmpty { entry.note = "关注对象暂无新报道" }
    else if (filter.mode == .personal || filter.eventsOnly) && entry.events.isEmpty { entry.note = filter.mode == .personal ? "没有符合个性设置的新闻" : "没有符合过滤条件的新闻" }
    entry.followedEvents = nil
    entry.rotationEvents = nil
    entry.conflictSignals = nil
    entry.rotationPage = nil; entry.rotationPageCount = nil
    entry.sourceFeeds = snapshot.sourceFeeds?.mapValues { SourceSnapshot(events: [], fetchedAt: $0.fetchedAt) }
    return [entry]
}

func sameDigest(_ first: [WorldEvent], _ second: [WorldEvent]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy {
        $0.id == $1.id && $0.title == $1.title && $0.date == $1.date
    }
}

func sameRenderedNews(_ first: [WorldEvent], _ second: [WorldEvent]) -> Bool {
    sameDigest(first, second) && first.map(\.displayTitle) == second.map(\.displayTitle)
        && first.map { $0.storyOutlets ?? [] } == second.map { $0.storyOutlets ?? [] } && first.map(\.breakingUntil) == second.map(\.breakingUntil)
        && first.map { $0.followTopics ?? [] } == second.map { $0.followTopics ?? [] } && first.map(\.major) == second.map(\.major) && first.map(\.factNote) == second.map(\.factNote)
}

func widgetNewsChanged(from previous: NewsSnapshot?, to snapshot: NewsSnapshot, filter: NewsFilter, now: Date = Date()) -> Bool {
    guard let previous, previous.mode == snapshot.mode else { return true }
    func candidates(_ entry: NewsSnapshot) -> [WorldEvent] {
        let all = entry.sourceFeeds?.values.flatMap(\.events) ?? entry.rotationEvents ?? entry.events
        let mode = effectiveDisplayMode(entry, now: now)
        if mode == .followed { return Array(followedPool(entry, now: now).prefix(12)) }
        let pool = displayPool(all, mode: mode, now: now, filter: filter)
        return mode == .rotation ? pool : Array(pool.prefix(12))
    }
    return !sameRenderedNews(candidates(previous), candidates(snapshot))
}

func widgetReloadDelay(last: Date, now: Date, newsChanged: Bool) -> TimeInterval {
    max(0, (newsChanged ? 15 : 55) - max(0, now.timeIntervalSince(last)))
}

func newerSnapshot(_ first: NewsSnapshot?, _ second: NewsSnapshot?) -> NewsSnapshot? {
    guard let first else { return second }
    guard let second else { return first }
    return second.revisionDate >= first.revisionDate ? second : first
}

func refreshedSnapshot(previous: NewsSnapshot?, results: [SourceFetchResult], now: Date = Date(), enabledIDs: [String] = NewsSource.all.map(\.id), mode: NewsDisplayMode? = nil, observedAt: Date? = nil) -> NewsSnapshot {
    var feeds = (previous?.sourceFeeds ?? [:]).filter { enabledIDs.contains($0.key) }
    if feeds.isEmpty, let previous {
        for (id, events) in Dictionary(grouping: previous.events, by: \.sourceID) {
            if enabledIDs.contains(id) { feeds[id] = SourceSnapshot(events: events, fetchedAt: previous.lastSuccess ?? previous.date) }
        }
    }
    var successful = 0
    var observed: [WorldEvent] = []
    for result in results {
        guard enabledIDs.contains(result.id) else { continue }
        if let events = result.events {
            let fetched = result.fetchedAt ?? now
            if feeds[result.id]?.fetchedAt ?? .distantPast <= fetched {
                feeds[result.id] = SourceSnapshot(events: events, fetchedAt: fetched)
                observed.append(contentsOf: events)
            }
            successful += 1
        }
    }
    feeds = limitedSourceFeeds(feeds)
    let mode = mode ?? previous?.displayMode ?? .latest
    let pool = displayPool(feeds.values.flatMap(\.events), mode: mode, now: now)
    let selected = Array(pool.prefix(4))
    let oldPool = previous?.rotationEvents ?? previous?.events ?? []
    let changed = !sameDigest(oldPool, pool)
    let note = enabledIDs.isEmpty ? "尚未选择来源" : successful == 0 ? "连接失败 · 保留缓存" : successful < enabledIDs.count ? "部分来源不可用" : nil
    let signalTime = observedAt ?? now
    let oldSignals = previous?.conflictSignals ?? conflictSignals(previous?.sourceFeeds?.values.flatMap(\.events) ?? [], now: signalTime)
    let signals = mergedConflictSignals(oldSignals, conflictSignals(observed, now: signalTime), enabledIDs: enabledIDs, now: signalTime)
    return NewsSnapshot(date: now, events: selected, availableSources: successful, note: note,
                        sourceFeeds: feeds, changedAt: changed ? now : previous?.changedAt ?? previous?.date,
                        lastSuccess: successful > 0 ? now : previous?.lastSuccess ?? previous?.checkDate, enabledSourceIDs: enabledIDs,
                        checkedAt: now, rotationEvents: pool, displayMode: mode, updatedAt: previous?.updatedAt, conflictSignals: signals,
                        followedEvents: previous?.followedEvents)
}

struct NewsSnapshotStore {
    let fileURL: URL
    var groupAvailable: Bool = false
    static var shared: NewsSnapshotStore {
        let manager = FileManager.default
        let group = Bundle.main.object(forInfoDictionaryKey: "WorldWatchAppGroup") as? String
        let shared = group.flatMap { manager.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        let base = shared ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NewsSnapshotStore(fileURL: base.appendingPathComponent("WorldWatch/widget-snapshot.json"), groupAvailable: shared != nil)
    }
    func read() -> NewsSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(NewsSnapshot.self, from: data)
    }
    @discardableResult func write(_ snapshot: NewsSnapshot) throws -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".snapshot.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        if let existing = read(), existing.revisionDate > snapshot.revisionDate { return false }
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        return true
    }
}

enum FeedError: LocalizedError {
    case invalid, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalid: return "来源返回的数据格式无法识别"
        case .http(let code): return "来源返回 HTTP \(code)"
        }
    }
}

// Built once and never mutated afterwards, so concurrent feed parsing can share them safely.
private let isoDateFormatters: [ISO8601DateFormatter] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]].map { (options: ISO8601DateFormatter.Options) in
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = options; return formatter
}
private let feedDateFormatters: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "EEE, dd MMM yyyy HH:mm Z"].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
}

/// Mail-style time label: "10:23" today, "昨天 10:23", otherwise "10月26日".
func shortTimeLabel(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let time = date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_CN")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 " + time }
    return date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_CN")).month(.defaultDigits).day())
}

/// Row time label. Date-only sources show 今天／昨天／日期 instead of a placeholder clock time.
func eventTimeLabel(_ event: WorldEvent, now: Date = Date()) -> String? {
    guard let date = event.date else { return nil }
    guard event.timeKind == "日期" else { return shortTimeLabel(date, now: now) }
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
    return date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_CN")).month(.defaultDigits).day())
}

func parseDate(_ text: String?) -> Date? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    for formatter in isoDateFormatters { if let date = formatter.date(from: text) { return date } }
    for formatter in feedDateFormatters { if let date = formatter.date(from: text) { return date } }
    return nil
}

func decodeHTMLEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let named = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ", "amp": "&",
                 "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "ndash": "–", "mdash": "—", "hellip": "…"]
    let regex = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});")
    var result = "", last = text.startIndex
    // Single pass, so "&amp;quot;" decodes to "&quot;" instead of being decoded twice.
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
        let name = String(text[body])
        var replacement: String?
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else { replacement = named[name.lowercased()] }
        guard let replacement else { continue }
        result += text[last..<whole.lowerBound] + replacement
        last = whole.upperBound
    }
    return result + text[last...]
}

func cleanTitle(_ text: String) -> String {
    decodeHTMLEntities(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A wrong feed timezone or typo can put a story days ahead and pin it to the top of "最新".
/// Treat implausible future publish times as unknown rather than trusting them.
func plausiblePublishDate(_ date: Date?, now: Date = Date()) -> Date? {
    // A few minutes covers clock skew; anything later is a placeholder or a wrong time zone, not a real publish time.
    guard let date, date > now.addingTimeInterval(300) else { return date }
    return nil
}

func safeURL(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
    return url
}

final class RSSReader: NSObject, XMLParserDelegate {
    let source: NewsSource
    var events: [WorldEvent] = []
    private var fields: [String: String] = [:]
    private var path: [String] = []
    private var inItem = false
    private var foundRSS = false
    private var depth = 0
    init(source: NewsSource) { self.source = source }
    func read(_ data: Data) throws -> [WorldEvent] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), foundRSS else { throw FeedError.invalid }
        return events
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if ["rss", "rdf:rdf", "feed"].contains(elementName.lowercased()) { foundRSS = true }
        if elementName == "item" || elementName == "entry" { inItem = true; fields = [:]; path = []; depth = 0; return }
        if inItem {
            depth += 1; path.append(elementName.lowercased())
            if elementName == "link", let href = attributeDict["href"], attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" { fields["link"] = href }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem, let key = path.last, depth == 1 || key == "geo:lat" || key == "geo:long" { fields[key, default: ""] += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inItem, let key = path.last, depth == 1, let string = String(data: CDATABlock, encoding: .utf8) { fields[key, default: ""] += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inItem else { return }
        if elementName != "item" && elementName != "entry" { depth -= 1; if !path.isEmpty { path.removeLast() }; return }
        inItem = false
        var title = cleanTitle(fields["title"] ?? "")
        let publisher = source.aggregator ? cleanTitle(fields["source"] ?? "").nilIfEmpty : nil
        // Google News appends " - Publisher" to every title.
        if let publisher, title.hasSuffix(" - " + publisher) { title = String(title.dropLast(publisher.count + 3)).trimmingCharacters(in: .whitespaces) }
        // Market chatter and self-media relays carry no reporting of their own (Sources/Topics.swift).
        if let publisher, outletTier(publisher: publisher, sourceID: source.id) == .low { return }
        guard !title.isEmpty, let url = safeURL(fields["link"] ?? "") else { return }
        let alert = fields["gdacs:alertlevel"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if source.id == "gdacs", alert != "red", alert != "orange" { return }
        let occurrence = source.id == "gdacs" ? parseDate(fields["gdacs:fromdate"]) : nil
        var published = parseDate(fields["pubdate"] ?? fields["dc:date"] ?? fields["published"] ?? fields["updated"])
        if source.dateOnly, let day = published {
            // Keep the calendar day only: start of that UTC day, so a placeholder noon never sorts above real news.
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            published = utc.startOfDay(for: day)
        }
        events.append(WorldEvent(id: source.id + ":" + url.absoluteString, sourceID: source.id, title: title, url: url,
                                 date: occurrence ?? plausiblePublishDate(published),
                                 timeKind: occurrence != nil ? "发生" : source.dateOnly ? "日期" : "发布", disaster: source.disaster,
                                 severity: alert == "red" ? "红色预警" : alert == "orange" ? "橙色预警" : nil,
                                 translatedTitle: source.language == "zh" ? title.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) : nil,
                                 latitude: fields["geo:lat"].flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                                 longitude: fields["geo:long"].flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                                 eventType: fields["gdacs:eventtype"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                                 endDate: parseDate(fields["gdacs:todate"]), publisher: publisher))
    }
}

private struct EarthquakeFeed: Decodable {
    struct Feature: Decodable {
        struct Properties: Decodable { let title: String?; let place: String?; let mag: Double?; let time: Double?; let url: String? }
        struct Geometry: Decodable { let coordinates: [Double] }
        let id: String; let properties: Properties; let geometry: Geometry?
    }
    let features: [Feature]
}

func parseFeed(_ data: Data, source: NewsSource) throws -> [WorldEvent] {
    if source.id == NewsSource.sina.id { return try parseSinaFeed(data) }
    if source.id != "usgs" { return try RSSReader(source: source).read(data) }
    return try JSONDecoder().decode(EarthquakeFeed.self, from: data).features.compactMap { feature in
        let p = feature.properties
        guard let raw = p.url, let url = safeURL(raw), let title = p.title else { return nil }
        let magnitude = p.mag.map { String(format: "%.1f", $0) } ?? "未知"
        return WorldEvent(id: "usgs:" + feature.id, sourceID: source.id,
                          title: "显著地震 M\(magnitude) · \(p.place ?? title)", url: url,
                          date: p.time.map { Date(timeIntervalSince1970: $0 / 1000) }, timeKind: "发生", disaster: true, severity: "显著地震",
                          latitude: feature.geometry?.coordinates.dropFirst().first, longitude: feature.geometry?.coordinates.first, magnitude: p.mag)
    }
}

func mergedEvents(_ events: [WorldEvent], now: Date = Date()) -> [WorldEvent] {
    var seen = Set<String>()
    return events.filter { event in
        let horizon: TimeInterval = event.disaster ? 7 * 86400 : 3 * 86400
        if let date = event.date, date < now.addingTimeInterval(-horizon) { return false }
        return seen.insert(event.id).inserted
    }.sorted {
        let first = $0.date ?? .distantPast, second = $1.date ?? .distantPast
        return first == second ? $0.id < $1.id : first > second
    }
}

private let newsSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 18
    configuration.timeoutIntervalForResource = 28
    configuration.httpMaximumConnectionsPerHost = 3
    return URLSession(configuration: configuration)
}()

func fetchSource(_ source: NewsSource, timeout: Double = 25) async throws -> [WorldEvent] {
    var request = URLRequest(url: source.url)
    request.timeoutInterval = timeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("WorldWatch/2.14 (personal desktop news reader)", forHTTPHeaderField: "User-Agent")
    for attempt in 0..<2 {
        do {
            let (data, response) = try await newsSession.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw FeedError.invalid }
            guard (200..<300).contains(response.statusCode) else { throw FeedError.http(response.statusCode) }
            return try parseFeed(data, source: source)
        } catch let error as URLError where attempt == 0 && [.timedOut, .networkConnectionLost, .secureConnectionFailed].contains(error.code) {
            // Retry a transient connection once; normal system certificate validation stays enabled.
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch { throw error }
    }
    throw URLError(.cannotConnectToHost)
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
