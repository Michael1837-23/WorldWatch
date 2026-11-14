import Foundation

// 关注追踪 checks (2.10–2.14): topic matching, outlet tiers, fact labels, the followed view, big-event ordering and topic history.

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

    // 2.13 presets, and the look-alikes they must not catch.
    require(ids("OpenAI launches ChatGPT Wallet, allowing its AI agents to make purchases") == ["openai"], "OpenAI 与 ChatGPT")
    require(ids("萨姆·奥特曼：GPT-6 明年发布").contains("openai") && ids("马斯克诉奥特曼案开庭").contains("openai"), "奥特曼带公司语境")
    require(!ids("新版奥特曼电影票房破亿").contains("openai"), "奥特曼动画不算 OpenAI")
    require(ids("Trump floats Apple chairman Tim Cook as Jensen Huang’s successor") == ["trump", "nvidia", "apple"], "Apple 与 Tim Cook")
    require(ids("特朗普：唯有苹果的库克能接替黄仁勋") == ["trump", "nvidia", "apple"], "苹果与库克共现")
    require(ids("蘋果發布會定檔 新機亮相") == ["apple"], "繁体苹果与发布会")
    require(!ids("库克群岛与中国签署深海采矿合作").contains("apple"), "库克群岛不算苹果")
    require(!ids("烟台苹果丰收 果农喜迎好价钱").contains("apple"), "水果不算苹果")
    require(!ids("黎智英案：苹果日报前高层出庭 涉及罚款").contains("apple") && !ids("Apple Daily founder Jimmy Lai sentenced").contains("apple"), "苹果日报不算苹果")
    require(!ids("Pineapple prices soar in Big Apple markets").contains("apple"), "Pineapple 与 Big Apple")
    let saved = Array(topics.prefix(7))
    require(FollowTopic.adding(["openai", "apple"], to: saved).map(\.id) == saved.map(\.id) + ["openai", "apple"], "旧清单补上 OpenAI 与苹果")
    let withKeyword = saved + [FollowTopic(id: "kw-1", name: "openai", aliases: ["openai"])]
    require(FollowTopic.adding(["openai", "apple"], to: withKeyword).map(\.id) == withKeyword.map(\.id) + ["apple"], "已有同名关注词时不重复添加")
    require(FollowTopic.adding(["openai"], to: FollowTopic.adding(["openai"], to: saved)).filter { $0.id == "openai" }.count == 1, "重复执行不重复添加")
    // 2.14 presets, and the look-alikes they must not catch.
    require(ids("Iran strikes US base in Bahrain; Israel weighs response") == ["mideast"] && ids("以军总参谋长主张暂缓对伊朗动武") == ["mideast"], "伊朗与以色列")
    require(ids("胡塞武装袭击红海商船") == ["mideast"] && ids("Hezbollah fires rockets from Lebanon") == ["mideast"] && ids("霍爾木茲海峽航運受阻") == ["mideast"], "胡塞、真主党与繁体霍尔木兹")
    require(!ids("中方将以军事手段回应挑衅").contains("mideast") && ids("Iranian foreign minister visits Beijing") == ["mideast"], "以军事不算以军")
    require(ids("Anthropic files for IPO") == ["anthropic"] && ids("Anthropic 的 Claude Opus 5 登顶编程榜") == ["anthropic"] && ids("Claude AI gets memory feature") == ["anthropic"], "Anthropic 与 Claude")
    require(!ids("Claude Monet painting sells for record sum").contains("anthropic")
            && !ids("Outlook、Teams、Copilot、ChatGPT、Claude：微软故障持续未解").contains("anthropic"), "Claude 单独出现不算 Anthropic")
    require(ids("Tesla opens Cybercab orders to individual buyers") == ["tesla"] && ids("马斯克：特斯拉明年量产 Cybercab") == ["musk", "tesla"], "特斯拉与马斯克")
    require(!ids("Waymo expands robotaxi service to Miami").contains("tesla"), "Robotaxi 不算特斯拉")
    require(ids("台積電員工資料外洩") == ["tsmc"] && ids("TSMC to expand advanced packaging capacity") == ["tsmc"] && ids("英伟达加大台积电订单") == ["nvidia", "tsmc"], "台积电与繁体")
    let v213 = FollowTopic.adding(["openai", "apple"], to: saved)
    var batched = v213
    for batch in newPresetBatches { batched = FollowTopic.adding(batch.ids, to: batched) }
    require(batched.map(\.id) == v213.map(\.id) + ["mideast", "anthropic", "tesla", "tsmc"] && batched.count == FollowTopic.presets.count, "2.13 的清单补上 2.14 的四个对象")
    require(Set(newPresetBatches.flatMap(\.ids)).isSubset(of: Set(FollowTopic.presets.map(\.id))), "迁移的对象都在预置里")
    let full = (0..<FollowTopic.limit).map { FollowTopic(id: "t\($0)", name: "对象\($0)", aliases: ["对象\($0)"]) }
    require(FollowTopic.adding(["openai"], to: full).count == FollowTopic.limit, "满 20 个不再添加")

    var custom = FollowTopic(id: "openai", name: "OpenAI", aliases: ["OpenAI", "奥特曼", "Sam Altman"])
    require(custom.queryZH == "奥特曼" && custom.queryEN == "OpenAI OR \"Sam Altman\"", "自定义对象的搜索词：\(custom.queryZH) / \(custom.queryEN)")
    custom.aliases = ["OpenAI"]; custom.fillQueries()
    require(custom.queryZH == "OpenAI" && custom.queryEN == "OpenAI", "只有英文别名时中文搜索也用英文")
    let decoded = try JSONDecoder().decode([FollowTopic].self, from: Data(#"[{"id":"x","name":"欧盟"}]"#.utf8))
    require(decoded[0].aliases == ["欧盟"] && decoded[0].queryZH == "欧盟" && !decoded[0].showTicks, "缺字段时的默认值")
    let roundTrip = try JSONDecoder().decode([FollowTopic].self, from: JSONEncoder().encode(topics))
    require(roundTrip == topics, "关注对象编码往返")

    // Extra sources: two searches per topic, known to lookups but absent from the widget's source list.
    let searches = NewsSource.topicSources(topics)
    require(searches.count == topics.count * 2 && searches.allSatisfy { $0.aggregator && $0.url.host == "news.google.com" && $0.url.absoluteString.contains("when%3A1d") }, "每个对象两个搜索源")
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
    let outage = (0..<10).map { item("g\($0)", "Microsoft outage disrupts Outlook and Teams worldwide \($0)", publisher: $0 == 0 ? "Reuters" : "Outlet \($0)", minutesAgo: 120 - Double($0), now: now) }
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
    require(follow.rows.first { $0.storyID == "f1" }!.factNote == "据报道" && follow.rows.first { $0.storyID == "f1" }!.followTopics == ["spacex", "tesla"], "传闻标「据报道」")
    require(follow.rows.first { $0.storyID == "g0" }!.major == true && follow.rows.first { $0.storyID == "g0" }!.followTopics == nil, "10 家外媒报道的非关注事件是大事")
    let war = follow.rows.first { $0.storyID == "i1" }!
    require(war.followTopics == ["ukraine"] && war.major == nil && war.publisher == "新京报", "超过 24 小时不再算大事；一档媒体里优先中文标题")
    require(follow.byTopic["spacex"]?.map(\.storyID) == ["f1", "a1"] && follow.majors.count == 2, "按对象分组与大事")
    var ticks = topics; ticks[2].showTicks = true
    require(followAnalysis(result, topics: ticks, now: now).rows.contains { $0.storyID == "e1" && $0.followTopics == ["nvidia"] }, "开启行情后显示股价跳动")
    require(followAnalysis(result, topics: topics, level: .strict, now: now).majors.isEmpty, "严格门槛下 10 家单语报道不是大事")
    require(isMajorStory(outlets: 6, chinese: true, foreign: true, breaking: false, primary: 1, level: .standard) && !isMajorStory(outlets: 9, chinese: true, foreign: false, breaking: false, primary: 3, level: .standard), "中外都报道 6 家够，只有中文 9 家不够")
    require(isMajorStory(outlets: 14, chinese: true, foreign: false, breaking: false, primary: 1, level: .standard) && isMajorStory(outlets: 4, chinese: false, foreign: true, breaking: true, primary: 2, level: .standard), "中文 14 家与外媒突发")
    require(!isMajorStory(outlets: 5, chinese: true, foreign: false, breaking: true, primary: 2, level: .standard) && !isMajorStory(outlets: 9, chinese: false, foreign: true, breaking: true, primary: 2, level: .strict), "中文突发不算，严格不看突发")
    require(!isMajorStory(outlets: 4, chinese: false, foreign: true, breaking: true, primary: 1, level: .standard) && !isMajorStory(outlets: 20, chinese: true, foreign: true, breaking: false, primary: 0, level: .standard), "突发需两家一档；没有一档媒体不算大事")
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

    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    func row(_ id: String, topics ids: [String]? = nil, major: Bool = false, outlets: Int = 2, primary: Int = 1, minutesAgo: Double = 20) -> WorldEvent {
        var event = item(id, "Headline \(id)", publisher: "Reuters", minutesAgo: minutesAgo, now: noon)
        event.storyID = id; event.followTopics = ids; event.major = major ? true : nil; event.primaryOutlets = primary
        event.storyOutlets = outlets >= 2 ? (0..<outlets).map { "O\($0)" } : nil
        event.storyFirstDate = event.date
        return event
    }

    // Big events are ordered by when they became big; the first run does not lift existing ones.
    var grown = row("grow", major: true, minutesAgo: 8 * 60)
    let fresh = row("fresh", topics: ["musk"], minutesAgo: 30)
    let seededRun = promotedRows([fresh, grown], since: [:], now: noon)
    require(seededRun.rows.map(\.id) == ["fresh", "grow"] && seededRun.rows[1].promotedAt == grown.storyFirstDate, "首次运行按首报时间")
    grown.storyID = "grow2"
    let later = promotedRows([fresh, grown], since: seededRun.since, now: noon)
    require(later.rows.map(\.id) == ["grow", "fresh"] && later.rows[0].promotedAt == noon, "新晋大事升到最前")
    let legacy = try JSONDecoder().decode(LegacyAlertLedger.self, from: Data(#"{"sent":{},"seeded":true,"delivered":[],"byTopic":{},"majorSince":{"s1":800000000}}"#.utf8))
    require(legacy.majorSince?["s1"] == Date(timeIntervalSinceReferenceDate: 800_000_000), "从旧版提醒记录读出大事时间")
    require(try JSONDecoder().decode(LegacyAlertLedger.self, from: Data(#"{"sent":{},"seeded":true}"#.utf8)).majorSince == nil, "更早的提醒记录没有大事时间")
    let oldTopic = try JSONDecoder().decode([FollowTopic].self, from: Data(#"[{"id":"musk","name":"马斯克","aliases":["马斯克"],"alerts":false}]"#.utf8))
    let reencoded = String(decoding: try JSONEncoder().encode(oldTopic), as: UTF8.self)
    require(oldTopic[0].aliases == ["马斯克"] && !reencoded.contains("alerts"), "旧清单的提醒开关读取后丢弃")
    for title in ["Trump's GOP was all they knew. Now some wonder if MAGA is dead", "Jensen Huang's Leather Jacket Comes Back to Bite Him", "11 names to watch in Nvidia's CEO search"] {
        require(isSoftNews(item("f-" + title, title, now: now)), "特写与分析：\(title)")
    }
    require(isSoftNews(item("f-nl", "160th anniversary of Sun Yat-sen’s birth; US-China; Nvidia fallout; South Korea", now: now)) && isSoftNews(item("f-sem", "2026年两岸科技创新融合发展研讨会在厦门开幕", now: now)), "简报与研讨会")
    require(isSoftNews(item("f-cn", "放行对华H200芯片出口——特朗普和黄仁勋近两年交往全梳理", now: now)) && !isSoftNews(item("f-us", "U.S. Navy deploys carrier to Taiwan Strait", now: now)), "梳理稿与缩写不误判")

    // 2.13: consumer-tech pieces, index and sector moves, tipsters and gadget blogs.
    for title in ["5 Apple HomeView Tips and Tricks That Will Upgrade Your Smart Home", "Early Black Friday Apple Deals: Watch Ultra 4, MacBook Air, More",
                  "The new Apple TV has a YouTube problem", "tvOS 27.2.1 launching soon with Siri AI for older Apple TV 4K models",
                  "YouTube App Not Working on Your New Apple TV? Here's the Fix", "Five Hacks Every Apple Watch Series 12 User Should Know"] {
        require(isSoftNews(item("ct-" + title, title, now: now)), "数码软文：\(title)")
    }
    require(isSoftNews(item("ct-cn1", "三款人像旗舰横评：OPPO Find X10、vivo X500、iPhone 18 Pro Max 谁的人像直出更自然", now: now))
            && isSoftNews(item("ct-cn2", "年轻人拍照手机怎么选：荣耀Magic9系列、iPhone与小米", now: now)), "横评与选购")
    require(!isSoftNews(item("ct-ok1", "Supreme Court to review Trump's asylum ban", now: now)) && !isSoftNews(item("ct-ok2", "Trump touts trade deals with Japan and Korea", now: now))
            && !isSoftNews(item("ct-ok3", "Chinese Premier Li Qiang meets Musk in Beijing", now: now)) && !isSoftNews(item("ct-ok4", "Iran hacks US water utilities, officials say", now: now)), "review、deals、Premier、hacks 不误判")
    require(isMarketTick(item("ct-t1", "Apple hits fresh all-time intraday highs on stable iPhone demand", now: now))
            && isMarketTick(item("ct-t2", "英伟达震荡未阻美股反弹，三大指数录得8月初以来最大单周涨幅", now: now)) && isMarketTick(item("ct-t3", "苹果，创新高！芯片股，又大跌", now: now)), "指数与板块行情")
    require(!isMarketTick(item("ct-t4", "Taiwan's defense budget hits record high", now: now)), "record high 不算行情")
    require(isRumorHeadline(item("ct-r1", "配A20芯片：古尔曼重申苹果iPhone 18/18e明年春季将登场", now: now)), "古尔曼爆料标「据报道」")
    require(outletTier(publisher: "9to5Mac", sourceID: "topic-apple-en") == .low && outletTier(publisher: "Decider", sourceID: "topic-apple-en") == .low
            && outletTier(publisher: "The Verge", sourceID: "topic-apple-en") == .primary, "数码博客是三档，The Verge 仍是一档")
    require(!ids("12 12 12 Premiere Recap: Anthony Mackie's Apple TV+ heist thriller").contains("apple") && ids("EU fines Apple over Apple TV bundling").contains("apple"), "Apple TV 节目不算苹果")
    // A large story needs a quarter of its outlets (or half) to mention a topic.
    func courtStory(appleMentions: Int) -> FollowAnalysis {
        var court = StoryResult()
        let members = (0..<12).map { item("q\($0)", $0 < appleMentions ? "Epic asks Supreme Court to uphold contempt ruling against Apple" : "Supreme Court to weigh Trump asylum ban",
                                           publisher: $0 == 0 ? "Reuters" : "Court Outlet \($0)", minutesAgo: 60, now: now) }
        for member in members { court.events[member.id] = member }
        court.stories = [story(members, outlets: members.map { $0.publisher! }, now: now)]
        return followAnalysis(court, topics: topics, now: now)
    }
    require(courtStory(appleMentions: 2).rows.first?.followTopics == ["trump"], "12 家里 2 家提到苹果，不算苹果")
    require(courtStory(appleMentions: 3).rows.first?.followTopics == ["trump", "apple"], "12 家里 3 家提到苹果，算苹果")

    // 2.14: one row per event. Background headlines make common words common.
    var joined = StoryResult()
    var joinedStories: [NewsStory] = []
    func addJoined(_ members: [WorldEvent]) {
        for member in members { joined.events[member.id] = member }
        joinedStories.append(story(members, outlets: members.map { $0.publisher! }, now: now))
    }
    for i in 0..<40 { addJoined([item("bg\(i)", "Officials release new report on regional budget \(i)", publisher: "Paper \(i)", minutesAgo: 300, now: now)]) }
    let launchOutlets = ["Reuters", "AP News", "BBC", "CNN", "The New York Times", "The Guardian"]
    let launch = launchOutlets.enumerated().map { item("sa\($0.offset)", "SpaceX launches Starship on 15th test flight as booster is lost", publisher: $0.element, minutesAgo: 120 - Double($0.offset), now: now) }
    let outcome = ["Bloomberg", "CNBC", "Axios"].enumerated().map { item("sb\($0.offset)", "Starship booster explodes after 15th test flight launch", publisher: $0.element, minutesAgo: 60 - Double($0.offset), now: now) }
    let clip = [item("sc0", "Starship booster explodes minutes after 15th test flight lifts off", publisher: "Politico", minutesAgo: 30, now: now)]
    let campus = ["Reuters", "Bloomberg", "CNBC"].enumerated().map { item("sd\($0.offset)", "SpaceX plans $74 billion AI computing campus in Texas", publisher: $0.element, minutesAgo: 90 - Double($0.offset), now: now) }
    let scrubOld = ["Reuters", "AP News", "Space"].enumerated().map { item("se\($0.offset)", "Starship 16th flight scrubbed over valve issue", publisher: $0.element, minutesAgo: 2400 - Double($0.offset), now: now) }
    let scrubNew = ["Reuters", "CNN", "Space"].enumerated().map { item("sf\($0.offset)", "Starship 16th flight scrubbed over valve issue again", publisher: $0.element, minutesAgo: 100 - Double($0.offset), now: now) }
    for group in [launch, outcome, clip, campus, scrubOld, scrubNew] { addJoined(group) }
    joined.stories = joinedStories
    let separateRows = followAnalysis(joined, topics: topics, now: now, joinRows: false).rows
    let joinedRows = followAnalysis(joined, topics: topics, now: now).rows
    require(separateRows.count == 6 && joinedRows.count == 4, "同一事件合并：\(separateRows.count) → \(joinedRows.count)")
    let flight = joinedRows.first { $0.storyID == "sa0" }!
    require(flight.threadStoryIDs == ["sb0", "sc0"] && flight.id.hasPrefix("sb") && flight.storyOutlets?.count == 10, "合并后显示最新的大范围进展，媒体取并集：\(flight.displayTitle)")
    require(flight.major == true && separateRows.allSatisfy { $0.major != true }, "合在一起的 10 家外媒报道成为大事")
    require(joinedRows.contains { $0.storyID == "sd0" && $0.threadStoryIDs == nil }, "同一对象的另一件事不合并")
    require(joinedRows.filter { $0.id.hasPrefix("se") || $0.id.hasPrefix("sf") }.count == 2, "相隔一天以上的同类报道不合并")
    let stamped = promotedRows([flight], since: ["sb0": now.addingTimeInterval(-7200), "_seeded": now], now: now)
    require(stamped.since["sa0"] == now.addingTimeInterval(-7200) && attentionDate(stamped.rows[0]) == flight.storyFirstDate, "合并后的行沿用已并入事件的大事时间，按最新进展排序")
    var ghost = item("ghost", "SpaceX launches Starship (earlier version)", publisher: "Reuters", minutesAgo: 120, now: now); ghost.storyID = "sa1"; ghost.followTopics = ["spacex"]
    var aged = item("aged", "SpaceX static fire completed", publisher: "Reuters", minutesAgo: 4 * 1440, now: now); aged.storyID = "aged"; aged.followTopics = ["spacex"]
    let savedHistory = [TopicHistoryItem(event: ghost, topics: ["spacex"], firstDate: now.addingTimeInterval(-7200), outlets: 6),
                 TopicHistoryItem(event: aged, topics: ["spacex"], firstDate: now.addingTimeInterval(-4 * 86400), outlets: 3)]
    let kept = mergedTopicHistory(savedHistory, rows: joinedRows, indexed: { joined.events[$0] != nil }, now: now)
    require(!kept.contains { $0.event.id == "ghost" } && kept.contains { $0.event.id == "aged" } && kept.contains { storyKey($0.event) == "sa0" }, "仍在索引里的旧版本不留在历史里")
    require(kept.allSatisfy { $0.event.threadStoryIDs == nil }, "历史不存合并编号")
    var folded = item("folded", "Older copy of the outcome", publisher: "Reuters", minutesAgo: 60, now: now); folded.storyID = "sb0"
    let spacexPage = topicTimeline("spacex", live: joinedRows, history: [TopicHistoryItem(event: folded, topics: ["spacex"], firstDate: now.addingTimeInterval(-3600), outlets: 3)])
    require(!spacexPage.contains { $0.id == "folded" } && spacexPage.count == joinedRows.filter { $0.followTopics?.contains("spacex") == true }.count, "对象页不重复显示已并入的事件")

    // Topic history and topic pages.
    var old = item("old", "Older SpaceX story", publisher: "Reuters", minutesAgo: 5 * 1440, now: now); old.storyID = "old"; old.followTopics = ["spacex"]
    let ancient = item("ancient", "Ancient SpaceX story", publisher: "Reuters", minutesAgo: 15 * 1440, now: now)
    let history = [TopicHistoryItem(event: old, topics: ["spacex"], firstDate: now.addingTimeInterval(-5 * 86400), outlets: 3),
                   TopicHistoryItem(event: ancient, topics: ["spacex"], firstDate: now.addingTimeInterval(-15 * 86400), outlets: 1)]
    let merged = mergedTopicHistory(history, rows: follow.rows, now: now)
    require(merged.contains { $0.event.id == "old" } && !merged.contains { $0.event.id == "ancient" } && merged.contains { storyKey($0.event) == "a1" && $0.outlets == 2 }, "历史保留两周并收入当前关注事件")
    require(!merged.contains { $0.event.major == true && $0.topics.isEmpty }, "大事不进对象历史")
    let page = topicTimeline("spacex", live: follow.rows, history: merged)
    require(page.map { storyKey($0) } == ["f1", "a1", "old"] && page[2].historyOutlets == 3, "对象页合并实时与历史：\(page.map { storyKey($0) })")
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

    print("PASS: 关注对象匹配（别名、大写缩写、共现、繁简、北京时间）、自定义搜索词、搜索源与新浪来源、媒体分档、行情与传闻、软新闻、新浪解析、关注列表入选与排序、大事门槛、屏蔽词、组件退回、大事排序、同一事件合并、对象历史与对象页、事件页分栏、关注名额")
}

private extension WorldEvent {
    func with(major: Bool) -> WorldEvent { var copy = self; copy.major = major ? true : nil; return copy }
}

/// `zsh test.command --follow`: fetch the topic searches and 新浪 7×24 live, merge them into a copy of the app's
/// story index, and print the followed view at each big-event level. Read-only for the app's files.
/// Topics the presets point to, measured with `--follow --local --candidates` before suggesting them.
let candidateTopics: [FollowTopic] = [
    FollowTopic(id: "c-tesla", name: "特斯拉", aliases: ["特斯拉", "Tesla", "Cybertruck", "Robotaxi"]),
    FollowTopic(id: "c-xai", name: "xAI", aliases: ["xAI", "Grok"]),
    FollowTopic(id: "c-anthropic", name: "Anthropic", aliases: ["Anthropic"]),
    FollowTopic(id: "c-google", name: "谷歌", aliases: ["谷歌", "Google", "Alphabet", "Gemini", "DeepMind"]),
    FollowTopic(id: "c-microsoft", name: "微软", aliases: ["微软", "Microsoft"]),
    FollowTopic(id: "c-meta", name: "Meta", aliases: ["Meta", "扎克伯格", "Zuckerberg"]),
    FollowTopic(id: "c-amazon", name: "亚马逊", aliases: ["亚马逊", "Amazon"]),
    FollowTopic(id: "c-tsmc", name: "台积电", aliases: ["台积电", "TSMC"]),
    FollowTopic(id: "c-huawei", name: "华为", aliases: ["华为", "Huawei", "任正非", "鸿蒙"]),
    FollowTopic(id: "c-deepseek", name: "DeepSeek", aliases: ["DeepSeek", "深度求索"]),
    FollowTopic(id: "c-chips", name: "芯片管制", aliases: ["出口管制", "实体清单", "export controls", "export curbs", "Entity List"]),
    FollowTopic(id: "c-fed", name: "美联储", aliases: ["美联储", "Federal Reserve", "FOMC"]),
    FollowTopic(id: "c-tariffs", name: "关税", aliases: ["关税", "贸易战", "tariff", "tariffs", "trade war"]),
    FollowTopic(id: "c-mideast", name: "中东局势", aliases: ["以色列", "伊朗", "加沙", "哈马斯", "真主党", "胡塞", "内塔尼亚胡",
                                                       "Israel", "Israeli", "Iran", "Iranian", "Gaza", "Hamas", "Hezbollah", "Houthi", "Houthis", "Netanyahu"]),
    FollowTopic(id: "c-japan", name: "中日关系", aliases: ["中日", "日中", "高市早苗", "Takaichi"],
                pairs: [["日本", "日方", "东京", "Japan", "Japanese", "Tokyo"], ["中国", "中方", "北京", "解放军", "China", "Chinese", "Beijing"]]),
    FollowTopic(id: "c-korea", name: "朝鲜半岛", aliases: ["朝鲜", "金正恩", "North Korea", "Pyongyang", "Kim Jong Un"]),
    FollowTopic(id: "c-russia", name: "普京与俄罗斯", aliases: ["普京", "克里姆林宫", "Putin", "Kremlin"]),
    FollowTopic(id: "c-eu", name: "欧盟", aliases: ["欧盟", "European Union", "EU", "冯德莱恩", "von der Leyen"]),
    FollowTopic(id: "c-venezuela", name: "委内瑞拉", aliases: ["委内瑞拉", "Venezuela", "Venezuelan", "马杜罗", "Maduro"]),
    FollowTopic(id: "c-crypto", name: "比特币", aliases: ["比特币", "Bitcoin", "加密货币", "crypto"])
]

func followProbe() async throws {
    func argument(_ flag: String) -> String? { CommandLine.arguments.firstIndex(of: flag).flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil } }
    let indexURL = argument("--index").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorldWatch/story-index.json")
    var index = (try? JSONDecoder().decode([String: StoryEntry].self, from: Data(contentsOf: indexURL))) ?? [:]
    let candidates = CommandLine.arguments.contains("--candidates")
    // --only musk,trump keeps just those presets, e.g. to compare with an earlier version's list.
    let only = argument("--only").map { Set($0.split(separator: ",").map(String.init)) }
    let topics = FollowTopic.presets.filter { only?.contains($0.id) ?? true } + (candidates ? candidateTopics : [])
    let matcher = TopicMatcher(topics)
    let started = Date()
    index = index.filter { outletTier($0.value.event) != .low }   // the app drops these while parsing
    print("本机索引：\(index.count) 条")
    var fetched: [WorldEvent] = []
    let live = !CommandLine.arguments.contains("--local")
    // --search c-tesla,c-mideast also fetches those candidates' searches, to see what following them would bring.
    let searched = Set((argument("--search") ?? "").split(separator: ",").map(String.init))
    for source in live ? NewsSource.topicSources(FollowTopic.presets + candidateTopics.filter { searched.contains($0.id) }) + [NewsSource.sina] : [] {
        do {
            var items = try await fetchSource(source)
            if source.id == NewsSource.sina.id { items = items.filter { !matcher.topicIDs($0).isEmpty && !isMarketTick($0) } }
            fetched += items
            print("  \(source.id)：\(items.count) 条")
        } catch { print("  \(source.id)：失败 \(error.localizedDescription)") }
        try await Task.sleep(nanoseconds: 700_000_000)
    }
    let now = Date()
    index = updatedStoryIndex(index, with: fetched.filter { outletTier($0) != .low }, now: now) { $0.sourceID.hasPrefix("topic-") || $0.sourceID == NewsSource.sina.id || !matcher.topicIDs($0).isEmpty }
    if let path = argument("--save") { try JSONEncoder().encode(index).write(to: URL(fileURLWithPath: path)); print("索引已存到 \(path)") }
    let clustering = Date()
    let result = buildStories(Array(index.values), now: now)
    print("合并后索引 \(index.count) 条 → \(result.stories.count) 个事件，聚类 \(String(format: "%.1f", Date().timeIntervalSince(clustering))) 秒，抓取 \(String(format: "%.0f", clustering.timeIntervalSince(started))) 秒")
    if CommandLine.arguments.contains("--support") {
        // Large stories: how many outlets mention each topic, to calibrate attribution.
        for story in result.stories where story.outlets.count >= 8 {
            let members = story.memberIDs.compactMap { result.events[$0] }
            var support: [String: Set<String>] = [:]
            for member in members { for id in matcher.topicIDs(member) { support[id, default: []].insert(storyOutlet(member) ?? member.sourceID) } }
            guard !support.isEmpty else { continue }
            let lead = members.first { $0.id == story.leadID } ?? members[0]
            print("  \(story.outlets.count)家 " + support.sorted { $0.value.count > $1.value.count }.map { "\($0.key)=\($0.value.count)" }.joined(separator: " ") + " | \((lead.translatedTitle ?? lead.title).prefix(50))")
        }
        return
    }
    if let path = argument("--dump") {
        // Rows with their stories' members, and every headline for document frequencies: input for tuning row merging.
        let follow = followAnalysis(result, topics: topics, now: now)
        func text(_ e: WorldEvent) -> [String: Any] {
            ["id": e.id, "title": e.title, "zh": e.translatedTitle ?? "", "source": e.sourceID, "publisher": e.publisher ?? "", "date": e.date?.timeIntervalSince1970 ?? 0,
             "chineseSource": isChineseSource(e.sourceID)]
        }
        let rows: [[String: Any]] = follow.rows.map { row in
            let story = result.story(for: row.id)
            return ["story": row.storyID ?? row.id, "display": row.displayTitle, "topics": row.followTopics ?? [], "major": row.major == true,
                    "outlets": row.storyOutlets ?? [], "primary": row.primaryOutlets ?? 0, "first": (row.storyFirstDate ?? row.date)?.timeIntervalSince1970 ?? 0,
                    "members": (story?.memberIDs ?? [row.id]).compactMap { result.events[$0] }.map(text)]
        }
        let all = result.events.values.filter { !$0.disaster }.map(text)
        try JSONSerialization.data(withJSONObject: ["now": now.timeIntervalSince1970, "rows": rows, "events": all]).write(to: URL(fileURLWithPath: path))
        print("已导出 \(rows.count) 行到 \(path)")
        return
    }
    for level in MajorLevel.allCases {
        let follow = followAnalysis(result, topics: topics, level: level, now: now)
        print("\n== 大事门槛「\(level.rawValue)」：关注 \(follow.rows.filter { $0.followTopics != nil }.count) 条，大事 \(follow.majors.count) 条（24 小时）")
        if level == .standard && !live {
            for row in follow.rows.prefix(45) {
                let tag = row.major == true ? "大事" : topicLabel(row.followTopics, topics: topics) ?? ""
                print("  \(shortTimeLabel(row.storyFirstDate ?? row.date ?? now, now: now)) [\(tag)] \(row.sourceName)·\(row.storyOutlets?.count ?? 1)家\(row.factNote.map { " " + $0 } ?? "") | \(row.displayTitle.prefix(58))")
            }
            let english = follow.rows.prefix(40).filter { $0.translatedTitle == nil && !containsHan($0.title) }.count
            print("  前 40 条中仍是英文标题：\(english) 条")
        }
        if level == .standard, let flag = CommandLine.arguments.firstIndex(of: "--topic"), CommandLine.arguments.count > flag + 1 {
            let id = CommandLine.arguments[flag + 1]
            for row in follow.byTopic[id] ?? [] { print("  [\(id)] \(row.sourceName)·\(row.storyOutlets?.count ?? 1)家 | \(row.displayTitle.prefix(70))") }
            let needle = CommandLine.arguments.count > flag + 2 ? CommandLine.arguments[flag + 2] : ""
            if !needle.isEmpty {
                for story in result.stories {
                    let members = story.memberIDs.compactMap { result.events[$0] }
                    guard members.contains(where: { $0.title.contains(needle) || ($0.translatedTitle ?? "").contains(needle) }) else { continue }
                    print("  事件 \(story.outlets.count) 家：" + members.map { "\(outletTier($0).rawValue)档 \($0.sourceName)：\($0.title.prefix(50)) 软=\(isSoftNews($0)) 非事件=\(isNonEventHeadline($0)) 事件=\(isEventHeadline($0)) 对象=\(matcher.topicIDs($0))" }.joined(separator: "\n      "))
                }
            }
        }
        if level == .standard && candidates {
            let followed = Set(FollowTopic.presets.map(\.id))
            print("  候选对象（\(searched.isEmpty ? "只用现有来源" : "含补全搜索：" + searched.sorted().joined(separator: "、"))）：")
            for topic in candidateTopics {
                let rows = follow.byTopic[topic.id] ?? []
                let day = rows.filter { now.timeIntervalSince($0.storyFirstDate ?? now) <= 86400 }
                let fresh = rows.filter { $0.major != true && followed.isDisjoint(with: $0.followTopics ?? []) }
                print("  \(topic.name)：72 小时 \(rows.count) 件，24 小时 \(day.count) 件，其中大事 \(rows.filter { $0.major == true }.count) 件，原本看不到的 \(fresh.count) 件")
                for row in fresh.prefix(searched.contains(topic.id) ? 12 : 5) { print("     · [\(row.sourceName)·\(row.storyOutlets?.count ?? 1)家] \(row.displayTitle.prefix(60))") }
            }
        }
        if level == .standard {
            let timer = Date()
            let separate = followAnalysis(result, topics: topics, level: level, now: now, joinRows: false)
            let plain = Date().timeIntervalSince(timer)
            _ = followAnalysis(result, topics: topics, level: level, now: now)
            print("  关注列表计算 \(String(format: "%.2f", plain)) 秒，含合并 \(String(format: "%.2f", Date().timeIntervalSince(timer) - plain)) 秒")
            let joined = follow.rows.filter { $0.threadStoryIDs != nil }
            print("  同一事件合并：\(separate.rows.count) 行 → \(follow.rows.count) 行，\(joined.count) 行各并入 \(joined.map { $0.threadStoryIDs!.count }.reduce(0, +)) 个事件；大事 \(separate.majors.count) → \(follow.majors.count)，其中因合并才过门槛 \(follow.majors.filter { row in ([row.storyID] + (row.threadStoryIDs ?? [])).allSatisfy { id in !separate.majors.contains { $0.storyID == id } } }.count) 件")
            print("  " + topics.map { "\($0.name) \(separate.byTopic[$0.id]?.count ?? 0)→\(follow.byTopic[$0.id]?.count ?? 0)" }.joined(separator: "，"))
            for row in follow.majors where ([row.storyID] + (row.threadStoryIDs ?? [])).allSatisfy({ id in !separate.majors.contains { $0.storyID == id } }) {
                print("  合并后成为大事：\(row.storyOutlets?.count ?? 1)家 | \(row.displayTitle.prefix(50))")
                for id in [row.storyID].compactMap({ $0 }) + (row.threadStoryIDs ?? []) {
                    if let story = result.story(for: id), let lead = result.events[story.leadID] { print("        · \(story.outlets.count)家 \(lead.displayTitle.prefix(50))") }
                }
            }
            // --history <file>: topic pages (live rows plus saved history) as 2.13 showed them and as they show now.
            if let path = argument("--history"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let history = try? JSONDecoder().decode([TopicHistoryItem].self, from: data) {
                let before = mergedTopicHistory(history, rows: separate.rows, now: now)
                let after = mergedTopicHistory(history, rows: follow.rows, indexed: { result.events[$0] != nil }, now: now)
                func recent(_ rows: [WorldEvent]) -> Int { rows.filter { now.timeIntervalSince($0.storyFirstDate ?? $0.date ?? now) <= 72 * 3600 }.count }
                print("  对象页 72 小时内的行数（原历史 \(history.count) 项 → 整理后 \(after.count) 项）：" + topics.map { topic in
                    "\(topic.name) \(recent(topicTimeline(topic.id, live: separate.rows, history: before)))→\(recent(topicTimeline(topic.id, live: follow.rows, history: after)))"
                }.joined(separator: "，"))
            }
            if let flag = CommandLine.arguments.firstIndex(of: "--topic"), CommandLine.arguments.count > flag + 1 {
                let id = CommandLine.arguments[flag + 1]
                for row in (follow.byTopic[id] ?? []) where row.threadStoryIDs != nil {
                    print("  [合并 \(id)] \(row.storyOutlets?.count ?? 1)家 +\(row.threadStoryIDs!.count)\(row.major == true ? " 大事" : "") | \(row.displayTitle.prefix(60))")
                    for storyID in row.threadStoryIDs! {
                        if let story = result.story(for: storyID), let lead = result.events[story.leadID] { print("        · \(story.outlets.count)家 \(lead.displayTitle.prefix(56))") }
                    }
                }
            }
        }
        if level == .standard && !candidates {
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
