import Foundation

// 关注追踪 checks (2.10–2.12): topic matching, outlet tiers, fact labels, the followed view, alerts and topic history.

private func require(_ condition: Bool, _ message: String) {
    if !condition { fflush(stdout); fatalError("FAIL: " + message) }
}

private func item(_ id: String, _ title: String, publisher: String? = nil, source: String = "gn-world", minutesAgo: Double = 30, now: Date, translated: String? = nil) -> WorldEvent {
    WorldEvent(id: id, sourceID: source, title: title, url: URL(string: "https://example.com/\(id)")!, date: now.addingTimeInterval(-minutesAgo * 60),
               timeKind: "发布", disaster: false, severity: nil, translatedTitle: translated, publisher: publisher)
}

private func story(_ members: [WorldEvent], outlets: [String], now: Date, breaking: Bool = false) -> NewsStory {
    let dates = members.compactMap(\.date)
    return NewsStory(id: members.map(\.id).min()!, memberIDs: members.map(\.id).sorted(), outlets: outlets, heat: Double(outlets.count),
                     leadID: members[0].id, latestID: members[0].id, firstDate: dates.min(), lastDate: dates.max(), firstObserved: dates.min() ?? now,
                     breakingUntil: breaking ? now.addingTimeInterval(3600) : nil)
}

func topicChecks() throws {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    let topics = FollowTopic.presets
    let matcher = TopicMatcher(topics)
    func ids(_ text: String) -> [String] { matcher.topicIDs([text]) }

    // Matching: aliases, case-sensitive short capitals, co-occurrence pairs, traditional folding, 北京时间.
    require(ids("黄仁勋爆婚外情请辞 马斯克留言认同创办人难取代") == ["musk", "nvidia"], "马斯克与黄仁勋同时命中")
    require(ids("Elon Musk says hiring Jensen Huang would be an honor") == ["musk", "nvidia"], "英文别名")
    require(ids("黃仁勳捲婚外情風暴辭輝達執行長 川普：令人難過") == ["trump", "nvidia"], "繁体与川普")
    require(ids("US and China agree to extend tariff truce").contains("us-china"), "US 与 China 共现")
    require(!ids("Join us for a tour of China's oldest temples").contains("us-china"), "小写 us 是代词，不算美国")
    require(ids("U.S.-China trade talks resume in Geneva").contains("us-china"), "U.S.-China 别名")
    require(!ids("北京时间11月14日，美国职业篮球联赛常规赛继续进行").contains("us-china"), "北京时间不是北京")
    require(ids("China stages unannounced Pacific drills in 'silent intimidation' of Taiwan") == ["taiwan"], "Taiwan 与 China 共现")
    require(ids("台湾地方选举民调出炉").isEmpty, "只提台湾不算两岸")
    require(ids("臺海情勢升溫") == ["taiwan"], "繁体台海")
    require(ids("Russia strikes hospital in central Kyiv") == ["ukraine"], "Kyiv")
    require(ids("SpaceX to attempt first Starship recovery on land") == ["spacex"], "SpaceX")
    require(topicLabel(["musk", "nvidia", "trump"], topics: topics) == "马斯克、英伟达等" && topicLabel(["gone"], topics: topics) == nil, "标签与已删除对象")

    var custom = FollowTopic(id: "openai", name: "OpenAI", aliases: ["OpenAI", "奥特曼", "Sam Altman"])
    require(custom.queryZH == "奥特曼" && custom.queryEN == "OpenAI OR \"Sam Altman\"", "自定义对象的搜索词：\(custom.queryZH) / \(custom.queryEN)")
    custom.aliases = ["OpenAI"]; custom.fillQueries()
    require(custom.queryZH == "OpenAI" && custom.queryEN == "OpenAI", "只有英文别名时中文搜索也用英文")
    let decoded = try JSONDecoder().decode([FollowTopic].self, from: Data(#"[{"id":"x","name":"欧盟"}]"#.utf8))
    require(decoded[0].aliases == ["欧盟"] && decoded[0].queryZH == "欧盟" && decoded[0].alerts, "缺字段时的默认值")
    let roundTrip = try JSONDecoder().decode([FollowTopic].self, from: JSONEncoder().encode(topics))
    require(roundTrip == topics, "关注对象编码往返")

    // Extra sources: two searches per topic, known to lookups but absent from the widget's source list.
    let searches = NewsSource.topicSources(topics)
    require(searches.count == 14 && searches.allSatisfy { $0.aggregator && $0.url.host == "news.google.com" && $0.url.absoluteString.contains("when%3A1d") }, "每个对象两个搜索源")
    require(NewsSource.find("topic-musk-zh")?.language == "zh" && NewsSource.find("topic-musk-en")?.language == "en" && isChineseSource("topic-taiwan-zh"), "搜索源语言")
    require(NewsSource.find("sina-7x24")?.language == "zh" && !NewsSource.all.contains { $0.isExtra }, "新浪与搜索源不在组件来源里")
    require(isChineseSource("sina-7x24") && !isChineseSource("topic-musk-en"), "新浪快讯按中文来源处理")

    // Outlet tiers; aggregator items from low-tier outlets are dropped while parsing.
    require(outletTier(publisher: "Reuters", sourceID: "gn-world") == .primary && outletTier(publisher: "財聯社", sourceID: "gn-zh") == .primary, "一档媒体")
    require(outletTier(publisher: "Benzinga", sourceID: "topic-musk-en") == .low && outletTier(publisher: "Sohu", sourceID: "gn-zh") == .low && outletTier(publisher: "英为财情 Investing.com", sourceID: "gn-zh") == .low, "三档媒体")
    require(outletTier(publisher: "Space", sourceID: "topic-spacex-en") == .ordinary && outletTier(publisher: nil, sourceID: "bbc") == .primary, "二档与直连来源")
    let rss = """
    <rss><channel>
    <item><title>SpaceX to attempt Starship recovery on land - Reuters</title><link>https://news.google.com/a</link><pubDate>Fri, 13 Nov 2026 10:00:00 GMT</pubDate><source url="https://reuters.com">Reuters</source></item>
    <item><title>Is SpaceX stock a buy now? - Benzinga</title><link>https://news.google.com/b</link><pubDate>Fri, 13 Nov 2026 10:00:00 GMT</pubDate><source url="https://benzinga.com">Benzinga</source></item>
    </channel></rss>
    """
    let parsed = try parseFeed(Data(rss.utf8), source: searches.first { $0.id == "topic-spacex-en" }!)
    require(parsed.count == 1 && parsed[0].publisher == "Reuters" && parsed[0].title == "SpaceX to attempt Starship recovery on land", "聚合源丢弃三档媒体并去掉媒体名后缀")

    // Market ticks and unconfirmed wording.
    require(isMarketTick(item("t1", "英伟达股价延续跌势，最新下跌 2.1%。", now: now)) && isMarketTick(item("t2", "Nvidia shares fall 3% as CEO exits", now: now)), "行情跳动")
    require(isMarketTick(item("t5", "22:30:47【美股三大股指小幅高开 英伟达反弹1.6%】", now: now)), "高开与反弹")
    require(isRumorHeadline(item("r4", "市场消息：美国总统特朗普将在马尼拉敦促东南亚国家加入倡议", now: now)), "市场消息是传闻")
    require(isSoftNews(item("s2", "GPT周报｜黄仁勋辞职；谷歌发布新模型", now: now)) && isSoftNews(item("s3", "国际观察丨反对派对内塔尼亚胡的“立法攻势”能否奏效", now: now)), "周报与观察栏目")
    require(isMarketTick(item("t3", "【费城半导体指数日内跌4%】", now: now)) && !isMarketTick(item("t4", "Jensen Huang steps down as Nvidia chief executive", now: now)), "行情与新闻区分")
    require(isRumorHeadline(item("r1", "SpaceX and Tesla Talks on Record Merger Are Said to Progress", now: now)) && isRumorHeadline(item("r2", "SpaceX与特斯拉或于12月宣布合并", now: now)), "传闻措辞")
    require(!isRumorHeadline(item("r3", "SpaceX launches Starship on its 15th test flight", now: now)), "确定措辞")

    // Soft news and editorials are not events.
    require(isSoftNews(item("n1", "2026年海峡两岸农博会·花博会在杭州举办", source: "cns-finance", now: now)), "两岸农博会是软新闻")
    require(!isSoftNews(item("n4", "SpaceX launches Starship on its 15th test flight", now: now)), "事件不是软新闻")
    require(isNonEventHeadline(item("n2", "The Guardian view on venture capitalism: investor profits are no industrial strategy", now: now)), "社论")
    require(isEventHeadline(item("n3", "SpaceX launches Starship on its 15th test flight", now: now)), "事件标题仍保留")

    // 新浪 7×24 parsing: bracketed headline, Beijing time, per-item link.
    let sina = #"{"result":{"data":{"feed":{"list":[{"id":5213657,"rich_text":"【费城半导体指数日内跌4%】费城半导体指数日内跌4.00%，现报10086.09点。","create_time":"2026-11-13 23:00:00","docurl":"https://finance.sina.cn/7x24/a.d.html"},{"id":"5213658","rich_text":"美国议员向黄仁勋发出第二次请求，要求其向国会作简报。","create_time":"2026-11-13 22:58:00","docurl":""}]}}}}"#
    let flashes = try parseSinaFeed(Data(sina.utf8), now: ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z")!)
    require(flashes.count == 2 && flashes[0].title == "费城半导体指数日内跌4%" && flashes[0].url.absoluteString == "https://finance.sina.cn/7x24/a.d.html", "新浪标题与链接")
    require(flashes[1].date == ISO8601DateFormatter().date(from: "2026-11-13T14:58:00Z") && flashes[1].publisher == "新浪财经" && flashes[1].translatedTitle == flashes[1].title, "新浪北京时间")
    require(flashes[1].url.host == "finance.sina.com.cn" && flashes[0].id == "sina-7x24:5213657", "缺链接时用 7×24 首页，编号统一为字符串")

    // The followed view, built from hand-made stories so the rules are tested without clustering.
    var result = StoryResult()
    var stories: [NewsStory] = []
    func add(_ members: [WorldEvent], _ outlets: [String], breaking: Bool = false) {
        for member in members { result.events[member.id] = member }
        stories.append(story(members, outlets: outlets, now: now, breaking: breaking))
    }
    add([item("a1", "SpaceX launches Starship rocket on 15th test flight", publisher: "Reuters", minutesAgo: 50, now: now),
         item("a2", "SpaceX launches giant Starship on 15th test flight", publisher: "Space", minutesAgo: 40, now: now)], ["Reuters", "Space"])
    add([item("b1", "Why does Musk's Grok keep failing?", publisher: "Some Blog", minutesAgo: 30, now: now)], ["Some Blog"])
    add([item("c1", "Musk unveils new Grok model", publisher: "Tech Blog", minutesAgo: 25, now: now)], ["Tech Blog"])
    add([item("d1", "Trump signs executive order on chip tariffs", publisher: "Reuters", minutesAgo: 20, now: now)], ["Reuters"])
    add([item("e1", "Nvidia shares fall 3% in premarket trading", publisher: "Reuters", minutesAgo: 15, now: now)], ["Reuters"])
    add([item("f1", "SpaceX and Tesla merger talks are said to progress", publisher: "Bloomberg", minutesAgo: 10, now: now)], ["Bloomberg"])
    let outage = (0..<10).map { item("g\($0)", "Microsoft outage disrupts Outlook and Teams worldwide \($0)", publisher: "Outlet \($0)", minutesAgo: 120 - Double($0), now: now) }
    add(outage, outage.map { $0.publisher! })
    add((0..<3).map { item("h\($0)", "Local council approves new budget \($0)", publisher: "Paper \($0)", minutesAgo: 60, now: now) }, ["Paper 0", "Paper 1", "Paper 2"])
    add([item("i1", "Ukraine says Russia struck Kharkiv power plant", publisher: "Kyiv Post", minutesAgo: 60 * 30, now: now),
         item("i2", "俄罗斯袭击哈尔科夫电厂", publisher: "新京报", minutesAgo: 60 * 29, now: now, translated: nil),
         item("i3", "Russia hits Kharkiv power station", publisher: "Al Jazeera", minutesAgo: 60 * 29, now: now)], ["Kyiv Post", "新京报", "半岛电视台"])
    add([item("j1", "Old story about Trump wins appeal", publisher: "Reuters", minutesAgo: 60 * 80, now: now)], ["Reuters"])
    add([item("k1", "Italy evacuates schools after bomb threat emails", publisher: "Reuters", minutesAgo: 90, now: now),
         item("k2", "Bomb threats force Italian schools to evacuate", publisher: "AP News", minutesAgo: 89, now: now),
         item("k3", "Italy schools evacuated over bomb hoax", publisher: "Daily One", minutesAgo: 88, now: now),
         item("k4", "Musk comments as Italy schools evacuate after bomb threats", publisher: "Daily Two", minutesAgo: 87, now: now)], ["Reuters", "AP News", "Daily One", "Daily Two"])
    result.stories = stories
    let quake = WorldEvent(id: "usgs:big", sourceID: "usgs", title: "显著地震 M7.2 · Japan", url: URL(string: "https://usgs.gov/a")!, date: now.addingTimeInterval(-3600),
                           timeKind: "发生", disaster: true, severity: "显著地震", magnitude: 7.2)
    let small = WorldEvent(id: "usgs:small", sourceID: "usgs", title: "显著地震 M6.1 · Chile", url: URL(string: "https://usgs.gov/b")!, date: now.addingTimeInterval(-3600),
                           timeKind: "发生", disaster: true, severity: "显著地震", magnitude: 6.1)
    let follow = followAnalysis(result, topics: topics, disasters: [quake, small], now: now)
    let shown = follow.rows.map { $0.storyID ?? $0.id }
    require(shown == ["f1", "d1", "a1", "usgs:big", "g0", "i1"], "关注列表的入选与顺序：\(shown)")
    let starship = follow.rows.first { $0.storyID == "a1" }!
    require(starship.followTopics == ["spacex"] && starship.primaryOutlets == 1 && starship.storyOutlets?.count == 2 && starship.publisher == "Reuters" && starship.factNote == nil, "SpaceX 事件")
    require(follow.rows.first { $0.storyID == "f1" }!.factNote == "据报道" && follow.rows.first { $0.storyID == "f1" }!.followTopics == ["spacex"], "传闻标「据报道」")
    require(follow.rows.first { $0.storyID == "g0" }!.major == true && follow.rows.first { $0.storyID == "g0" }!.followTopics == nil, "10 家外媒报道的非关注事件是大事")
    let war = follow.rows.first { $0.storyID == "i1" }!
    require(war.followTopics == ["ukraine"] && war.major == nil && war.publisher == "新京报", "超过 24 小时不再算大事；一档媒体里优先中文标题")
    require(follow.byTopic["spacex"]?.map(\.storyID) == ["f1", "a1"] && follow.majors.count == 2, "按对象分组与大事")
    var ticks = topics; ticks[2].showTicks = true
    require(followAnalysis(result, topics: ticks, now: now).rows.contains { $0.storyID == "e1" && $0.followTopics == ["nvidia"] }, "开启行情后显示股价跳动")
    require(followAnalysis(result, topics: topics, level: .strict, now: now).majors.isEmpty, "严格门槛下 10 家单语报道不是大事")
    require(isMajorStory(outlets: 6, chinese: true, foreign: true, breaking: false, level: .standard) && !isMajorStory(outlets: 9, chinese: true, foreign: false, breaking: false, level: .standard), "中外都报道 6 家够，只有中文 9 家不够")
    require(isMajorStory(outlets: 14, chinese: true, foreign: false, breaking: false, level: .standard) && isMajorStory(outlets: 4, chinese: false, foreign: true, breaking: true, level: .standard), "中文 14 家与外媒突发")
    require(!isMajorStory(outlets: 5, chinese: true, foreign: false, breaking: true, level: .standard) && !isMajorStory(outlets: 9, chinese: false, foreign: true, breaking: true, level: .strict), "中文突发不算，严格不看突发")
    require(followAnalysis(result, topics: topics, level: .loose, now: now).majors.contains { $0.storyID == "i1" } == false, "宽松门槛也只看 24 小时内")
    var blocked = NewsFilter(); blocked.mode = .personal; blocked.blocked = ["Trump"]
    require(!followAnalysis(result, topics: topics, filter: blocked, now: now).rows.contains { $0.storyID == "d1" }, "屏蔽词优先")
    require(followAnalysis(result, topics: [], now: now).rows.allSatisfy { $0.major == true }, "没有关注对象时只剩大事")

    // Widget fallback and pool selection.
    let retained = [item("w1", "Trump signs executive order on chip tariffs", source: "bbc", minutesAgo: 10, now: now),
                    item("w2", "Why Trump keeps winning?", source: "bbc", minutesAgo: 9, now: now),
                    item("w3", "Local council approves new budget", source: "bbc", minutesAgo: 8, now: now),
                    item("w4", "Nvidia shares fall 3% in premarket trading", source: "cnbc", minutesAgo: 7, now: now), quake]
    let fallback = followedFallback(retained, topics: topics, now: now)
    require(fallback.map(\.id) == ["w1", "usgs:big"] && fallback[0].followTopics == ["trump"] && fallback[1].major == true, "组件退回关键词匹配：\(fallback.map(\.id))")
    var snapshot = NewsSnapshot(date: now, events: [], availableSources: 1, note: nil, sourceFeeds: ["bbc": SourceSnapshot(events: retained, fetchedAt: now)])
    snapshot.followedEvents = [starship]
    snapshot.updatedAt = now.addingTimeInterval(-600)
    snapshot.displayMode = .followed
    require(followedPool(snapshot, now: now, topics: topics).map(\.id) == ["a1"], "新鲜时用 App 计算的列表")
    snapshot.updatedAt = now.addingTimeInterval(-3 * 3600)
    require(followedPool(snapshot, now: now, topics: topics).map(\.id) == ["w1", "usgs:big"], "过期时退回关键词匹配")
    snapshot.updatedAt = now
    let entry = widgetTimeline(snapshot, now: now, pageSize: 4)
    require(entry.count == 1 && entry[0].events.map(\.id) == ["a1"] && entry[0].followedEvents == nil && entry[0].mode == .followed, "组件关注优先模式")
    snapshot.followedEvents = []
    require(widgetTimeline(snapshot, now: now, pageSize: 4)[0].note == "关注对象暂无新报道", "没有关注报道时的提示")
    require(NewsDisplayMode.allCases.first == .followed && NewsDisplayMode.followed.title == "关注优先", "关注优先排第一")

    // Alerts: first run only records; quiet hours; caps; freshness; eligibility.
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    func row(_ id: String, topics ids: [String]? = nil, major: Bool = false, outlets: Int = 2, primary: Int = 1, minutesAgo: Double = 20) -> WorldEvent {
        var event = item(id, "Headline \(id)", publisher: "Reuters", minutesAgo: minutesAgo, now: noon)
        event.storyID = id; event.followTopics = ids; event.major = major ? true : nil; event.primaryOutlets = primary
        event.storyOutlets = outlets >= 2 ? (0..<outlets).map { "O\($0)" } : nil
        event.storyFirstDate = event.date
        return event
    }
    let settings = AlertSettings()
    var first = alertDecision(rows: [row("m1", major: true)], topics: topics, settings: settings, ledger: AlertLedger(), now: noon, calendar: calendar)
    require(first.send.isEmpty && first.ledger.seeded && first.ledger.sent["m1"] != nil, "首次运行只记录，不推送")
    first = alertDecision(rows: [row("m1", major: true), row("m2", major: true), row("t1", topics: ["musk"]), row("t2", topics: ["musk"], outlets: 1),
                                 row("t3", topics: ["musk"], primary: 0), row("t4", topics: ["musk"], minutesAgo: 200)],
                          topics: topics, settings: settings, ledger: first.ledger, now: noon, calendar: calendar)
    require(first.send.map(\.id) == ["m2", "t1"], "只推新的大事和已证实的关注事件：\(first.send.map(\.id))")
    let again = alertDecision(rows: [row("m2", major: true)], topics: topics, settings: settings, ledger: first.ledger, now: noon.addingTimeInterval(60), calendar: calendar)
    require(again.send.isEmpty, "同一事件只提醒一次")
    let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 23, minute: 30))!
    let quiet = alertDecision(rows: [row("q1", major: true, minutesAgo: 0)], topics: topics, settings: settings, ledger: first.ledger, now: night, calendar: calendar)
    require(quiet.send.isEmpty && quiet.ledger.sent["q1"] == nil, "免打扰时段不推送也不记为已推")
    require(settings.isQuiet(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 6))!, calendar: calendar) && !settings.isQuiet(noon, calendar: calendar), "跨午夜的免打扰")
    let burst = alertDecision(rows: (1...5).map { row("b\($0)", major: true) }, topics: topics, settings: settings, ledger: AlertLedger(seeded: true), now: noon, calendar: calendar)
    require(burst.send.count == alertsPerPass, "每轮最多 3 条")
    let perTopic = alertDecision(rows: (1...3).map { row("p\($0)", topics: ["trump"]) }, topics: topics, settings: settings, ledger: AlertLedger(seeded: true), now: noon, calendar: calendar)
    require(perTopic.send.count == alertsPerTopicHour, "同一对象每小时最多 2 条")
    var muted = topics; muted[1].alerts = false
    require(alertDecision(rows: [row("x1", topics: ["trump"])], topics: muted, settings: settings, ledger: AlertLedger(seeded: true), now: noon, calendar: calendar).send.isEmpty, "关闭单个对象的提醒")
    var hourly = AlertLedger(seeded: true); hourly.delivered = (0..<alertsPerHour).map { noon.addingTimeInterval(Double(-$0 * 60)) }
    require(alertDecision(rows: [row("y1", major: true)], topics: topics, settings: settings, ledger: hourly, now: noon, calendar: calendar).send.isEmpty, "每小时上限")
    let content = alertContent(follow.rows.first { $0.storyID == "f1" }!, topics: topics)
    require(content.title == "SpaceX" && content.body.hasPrefix("【据报道】") && alertContent(quake.with(major: true), topics: topics).title == "大事", "通知文字：\(content)")

    // Topic history and topic pages.
    var old = item("old", "Older SpaceX story", publisher: "Reuters", minutesAgo: 5 * 1440, now: now); old.storyID = "old"; old.followTopics = ["spacex"]
    let ancient = item("ancient", "Ancient SpaceX story", publisher: "Reuters", minutesAgo: 15 * 1440, now: now)
    let history = [TopicHistoryItem(event: old, topics: ["spacex"], firstDate: now.addingTimeInterval(-5 * 86400), outlets: 3),
                   TopicHistoryItem(event: ancient, topics: ["spacex"], firstDate: now.addingTimeInterval(-15 * 86400), outlets: 1)]
    let merged = mergedTopicHistory(history, rows: follow.rows, now: now)
    require(merged.contains { $0.event.id == "old" } && !merged.contains { $0.event.id == "ancient" } && merged.contains { alertKey($0.event) == "a1" && $0.outlets == 2 }, "历史保留两周并收入当前关注事件")
    require(!merged.contains { $0.event.major == true && $0.topics.isEmpty }, "大事不进对象历史")
    let page = topicTimeline("spacex", live: follow.rows, history: merged)
    require(page.map { alertKey($0) } == ["f1", "a1", "old"] && page[2].historyOutlets == 3, "对象页合并实时与历史：\(page.map { alertKey($0) })")
    require(dayLabel(now, now: now) == "今天" && dayLabel(now.addingTimeInterval(-86400), now: now) == "昨天", "日期分组")

    // Event page sides.
    let sides = eventSides([result.events["i3"]!, result.events["i1"]!, result.events["i2"]!, item("i4", "Russia hits Kharkiv again", publisher: "Kyiv Post", minutesAgo: 60, now: now)])
    require(sides.chinese.map(\.id) == ["i2"] && sides.foreign.map(\.id) == ["i1", "i3"] && sides.primaryOutlets == 2, "事件页中外分栏，每家一条")

    // Index allowance for followed headlines.
    var index: [String: StoryEntry] = [:]
    let general = (0..<2100).map { item("gen\($0)", "General \($0)", source: "bbc", minutesAgo: Double($0), now: now) }
    let followed = (0..<50).map { item("fol\($0)", "Followed \($0)", source: "topic-musk-en", minutesAgo: Double(3000 + $0), now: now) }
    let isFollowed: (WorldEvent) -> Bool = { $0.sourceID.hasPrefix("topic-") }
    index = updatedStoryIndex(index, with: general + followed, now: now, followed: isFollowed)
    require(index.count == storyIndexLimit + 50 && index["fol49"] != nil && index["gen2099"] == nil, "关注报道另有名额")
    var translatedEntry = index["fol1"]!.event; translatedEntry.translatedTitle = "关注 1"
    index = updatedStoryIndex(index, with: [translatedEntry], now: now, followed: isFollowed)
    index = updatedStoryIndex(index, with: [item("fol1", "Followed 1", source: "topic-musk-en", minutesAgo: 3001, now: now)], now: now, followed: isFollowed)
    require(index["fol1"]?.event.translatedTitle == "关注 1", "重复抓到未翻译标题时保留译文")

    print("PASS: 关注对象匹配（别名、大写缩写、共现、繁简、北京时间）、自定义搜索词、搜索源与新浪来源、媒体分档、行情与传闻、软新闻、新浪解析、关注列表入选与排序、大事门槛、屏蔽词、组件退回、提醒（首次、去重、免打扰、上限、新鲜度）、对象历史与对象页、事件页分栏、关注名额")
}

private extension WorldEvent {
    func with(major: Bool) -> WorldEvent { var copy = self; copy.major = major ? true : nil; return copy }
}

/// `zsh test.command --follow`: fetch the topic searches and 新浪 7×24 live, merge them into a copy of the app's
/// story index, and print the followed view at each big-event level. Read-only for the app's files.
func followProbe() async throws {
    let indexURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorldWatch/story-index.json")
    var index = (try? JSONDecoder().decode([String: StoryEntry].self, from: Data(contentsOf: indexURL))) ?? [:]
    let topics = FollowTopic.presets
    let matcher = TopicMatcher(topics)
    let started = Date()
    print("本机索引：\(index.count) 条")
    var fetched: [WorldEvent] = []
    for source in NewsSource.topicSources(topics) + [NewsSource.sina] {
        do {
            var items = try await fetchSource(source)
            if source.id == NewsSource.sina.id { items = items.filter { !matcher.topicIDs($0).isEmpty && !isMarketTick($0) } }
            fetched += items
            print("  \(source.id)：\(items.count) 条")
        } catch { print("  \(source.id)：失败 \(error.localizedDescription)") }
        try await Task.sleep(nanoseconds: 700_000_000)
    }
    let now = Date()
    index = updatedStoryIndex(index, with: fetched, now: now) { $0.sourceID.hasPrefix("topic-") || $0.sourceID == NewsSource.sina.id || !matcher.topicIDs($0).isEmpty }
    let clustering = Date()
    let result = buildStories(Array(index.values), now: now)
    print("合并后索引 \(index.count) 条 → \(result.stories.count) 个事件，聚类 \(String(format: "%.1f", Date().timeIntervalSince(clustering))) 秒，抓取 \(String(format: "%.0f", clustering.timeIntervalSince(started))) 秒")
    for level in MajorLevel.allCases {
        let follow = followAnalysis(result, topics: topics, level: level, now: now)
        print("\n== 大事门槛「\(level.rawValue)」：关注 \(follow.rows.filter { $0.followTopics != nil }.count) 条，大事 \(follow.majors.count) 条（24 小时）")
        if level == .standard {
            for topic in topics {
                let rows = follow.byTopic[topic.id] ?? []
                let day = rows.filter { now.timeIntervalSince($0.storyFirstDate ?? now) <= 86400 }
                print("  \(topic.name)：72 小时 \(rows.count) 条，24 小时 \(day.count) 条，据报道 \(rows.filter { $0.factNote != nil }.count) 条")
                for row in day.prefix(4) { print("     · [\(row.sourceName)·\(row.storyOutlets?.count ?? 1)家] \(row.displayTitle.prefix(60))") }
            }
        }
        for row in follow.majors.prefix(level == .standard ? 20 : 8) {
            print("  大事 [\(row.storyOutlets?.count ?? 0)家] \(row.displayTitle.prefix(64))")
        }
    }
}
