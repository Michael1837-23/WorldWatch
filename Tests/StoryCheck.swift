import Foundation

// Hot-story checks. The fixture acceptance reuses the labeled corpus from docs/evaluation/热点聚类评测.md.

private func require(_ condition: Bool, _ message: String) {
    if !condition { fflush(stdout); fatalError("FAIL: " + message) }
}

private struct FixtureItem: Decodable { let id: String; let source: String; let outlet: String; let lang: String; let title: String; let zh: String?; let en: String?; let date: Date?; let url: String }

private func fixtureEntries(_ items: [FixtureItem], suffix: String = "") -> [StoryEntry] {
    items.map { item in
        let event = WorldEvent(id: item.id + suffix, sourceID: item.source, title: item.title + suffix, url: URL(string: item.url + (suffix.isEmpty ? "" : "?copy=" + suffix))!,
                               date: item.date, timeKind: "发布", disaster: false, severity: nil, translatedTitle: item.zh.map { $0 + suffix })
        return StoryEntry(event: event, observedAt: item.date ?? Date(), english: item.en)
    }
}

func storyChecks() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/cluster-eval")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let items = try decoder.decode([FixtureItem].self, from: Data(contentsOf: root.appendingPathComponent("corpus.json")))
    let now = items.compactMap(\.date).max()!.addingTimeInterval(600)
    let entries = fixtureEntries(items)
    let result = buildStories(entries, now: now)
    let again = buildStories(entries, now: now)
    require(result.stories == again.stories, "同一输入两次聚类结果一致")

    // Gold: E = same event, G = related group (merging tolerated), pair labels S/R also tolerated.
    var eventOf: [Int: String] = [:], groupsOf: [Int: Set<String>] = [:], members: [String: [Int]] = [:]
    var groupLines: [(String, [String])] = []
    for line in try String(contentsOf: root.appendingPathComponent("gold.txt"), encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let head = line[..<colon].split(separator: " ").map(String.init), tokens = line[line.index(after: colon)...].split(separator: " ").map(String.init)
        if head[0] == "E" { let idx = tokens.compactMap(Int.init); members[head[1]] = idx; for i in idx { eventOf[i] = head[1] } }
        else { groupLines.append((head[1], tokens)) }
    }
    for (name, tokens) in groupLines { for t in tokens { for i in Int(t).map({ [$0] }) ?? members[t] ?? [] { groupsOf[i, default: []].insert(name) } } }
    let indexOf = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    var tolerated = Set<[Int]>()
    for line in try String(contentsOf: root.appendingPathComponent("pair-labels.tsv"), encoding: .utf8).split(separator: "\n").dropFirst() {
        let parts = line.split(separator: "\t").map(String.init)
        guard parts.count == 4, ["S", "R"].contains(parts[0]), let a = indexOf[parts[2]], let b = indexOf[parts[3]] else { continue }
        tolerated.insert([min(a, b), max(a, b)])
    }
    func wrong(_ a: Int, _ b: Int) -> Bool {
        if items[a].title == items[b].title || items[a].url == items[b].url { return false }
        if let e = eventOf[a], e == eventOf[b] { return false }
        if tolerated.contains([min(a, b), max(a, b)]) { return false }
        return (groupsOf[a] ?? []).isDisjoint(with: groupsOf[b] ?? [])
    }
    let clusters = result.stories.map { $0.memberIDs.compactMap { indexOf[$0] } }
    var hotImpure = 0, inflated = 0
    for cluster in clusters {
        let outlets = Set(cluster.map { items[$0].outlet })
        guard outlets.count >= 2 else { continue }
        let bad = cluster.contains { a in cluster.contains { b in a < b && wrong(a, b) } }
        guard bad else { continue }
        if outlets.count >= 3 {
            hotImpure += 1
            print("  ✗ 热点误合并：" + cluster.map { items[$0].source + ": " + items[$0].title }.joined(separator: " ‖ "))
        }
        let core = cluster.max { a, b in cluster.filter { !wrong(a, $0) }.count < cluster.filter { !wrong(b, $0) }.count }!
        if Set(cluster.filter { !wrong(core, $0) }.map { items[$0].outlet }).count < outlets.count { inflated += 1 }
    }
    let clusterOf = Dictionary(uniqueKeysWithValues: clusters.enumerated().flatMap { c, m in m.map { ($0, c) } })
    var recall: [Double] = []
    for (_, indices) in members {
        let outlets = Set(indices.map { items[$0].outlet })
        guard outlets.count >= 3 else { continue }
        let grouped = Dictionary(grouping: indices, by: { clusterOf[$0] ?? -1 })
        let main = grouped.sorted { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : Set(a.value.map { items[$0].outlet }).count != Set(b.value.map { items[$0].outlet }).count ? Set(a.value.map { items[$0].outlet }).count > Set(b.value.map { items[$0].outlet }).count : a.key < b.key
        }.first!.value
        recall.append(Double(Set(main.map { items[$0].outlet }).count) / Double(outlets.count))
    }
    let outletRecall = recall.reduce(0, +) / Double(recall.count)
    let units = Set(items.map { $0.title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }).count
    print(String(format: "热点夹具：%d 条 → %d 个事件，热点误合并 %d，媒体数虚报 %d，%d 个大事件媒体找回率 %.2f", units, result.stories.count, hotImpure, inflated, recall.count, outletRecall))
    require(hotImpure == 0, "≥3 家的热点不得混入无关报道")
    require(inflated == 0, "媒体数不得被误合并抬高")
    require(recall.count == 15 && outletRecall >= 0.70, "15 个大事件媒体找回率 ≥ 0.70")
    require(result.stories.count <= 560, "658 条合并后不超过 560 个事件")
    // The reference tool gives 0.75 / 544; the app also requires cosine ≥ 0.40 for merges without a shared
    // rare country or name (live data chained "rising costs" headlines from four outlets), costing ~6 merges here.
    require(abs(outletRecall - 0.75) <= 0.02 && (544...556).contains(result.stories.count), "与参考工具（0.75、544）基本一致")

    // Performance: about 2000 headlines in under a second (features cached as in the app).
    let large = entries + fixtureEntries(items, suffix: " 二") + fixtureEntries(items, suffix: " 三")
    let cache = StoryFeatureCache()
    _ = buildStories(large, now: now, cache: cache)
    let started = Date()
    _ = buildStories(large, now: now, cache: cache)
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "热点全量重算：%d 条 %.2f 秒", large.count, elapsed))
    require(elapsed < 1.0, "2000 条全量聚类 < 1 秒")

    // Features.
    require(stripStoryBoilerplate("学习贯彻党的二十届五中全会精神丨中央宣讲团在河南宣讲") == "中央宣讲团在河南宣讲", "去掉栏目前缀")
    require(stripStoryBoilerplate("Bomb threats ‘likely a coordinated campaign’, Ireland says – as it happened").hasSuffix("Ireland says"), "去掉 as it happened")
    require(!storyBigrams("2027年发布").contains("20") && storyBigrams("2027年发布").contains("发布"), "纯数字二元组不计")
    require(!storyWords("Tesla will stop in 2027").contains("2027"), "纯数字单词不计")
    require(StoryGazetteer.shared.countries(in: "Trump says US strikes Iran").contains("US"), "大写 US 是美国")
    require(!StoryGazetteer.shared.countries(in: "Join us for the show").contains("US"), "小写 us 不是美国")
    require(StoryGazetteer.shared.countries(in: "巴拉圭總統遭彈劾").contains("PY") && StoryGazetteer.shared.countries(in: "巴拉圭总统").contains("PY"), "简繁国名")

    // Outlets, heat, breaking.
    func event(_ id: String, _ source: String, _ title: String, _ minutes: Double, publisher: String? = nil, zh: String? = nil) -> StoryEntry {
        var item = WorldEvent(id: id, sourceID: source, title: title, url: URL(string: "https://example.com/" + id)!, date: now.addingTimeInterval(minutes * 60), timeKind: "发布", disaster: false, severity: nil, translatedTitle: zh)
        item.publisher = publisher
        return StoryEntry(event: item, observedAt: item.date!)
    }
    let quake = [event("a", "bbc", "Huge earthquake hits Chile capital, hundreds feared dead", -50),
                 event("b", "bbc-business", "Chile earthquake rattles markets as capital hit", -45),
                 event("c", "guardian", "Earthquake in Chile capital: hundreds feared dead", -30),
                 event("d", "gn-world", "Chile capital earthquake leaves hundreds feared dead", -10, publisher: "Reuters"),
                 event("e", "nyt", "Earthquake devastates Chile capital, hundreds feared dead", 0)]
    let background = Array(entries.prefix(120))   // realistic IDF: a five-headline corpus has no rare words
    let quick = buildStories(quake + background, now: now)
    let story = quick.story(for: "a")!
    require(quick.story(for: "e")?.id == story.id && story.outlets == ["BBC", "卫报", "Reuters", "纽约时报"], "BBC 两个栏目算一家，聚合源按原媒体计")
    require(story.breakingUntil != nil, "60 分钟内第 3 家报道即为突发")
    let slow = buildStories([event("a", "bbc", quake[0].event.title, -122), event("c", "guardian", quake[2].event.title, -90), event("e", "nyt", quake[4].event.title, -60)] + background, now: now)
    require(slow.story(for: "a")?.outlets.count == 3 && slow.story(for: "a")?.breakingUntil == nil, "第 3 家晚于 60 分钟不算突发")
    require(abs(story.heat - (4 + 4)) < 0.01, "热度 = 媒体数 × 衰减 + 2 小时内新增媒体")
    let decorated = decoratedEvents(quake.map(\.event), with: quick, now: now)
    require(isBreaking(decorated[0], now: now) && !isBreaking(decorated[0], now: story.breakingUntil!.addingTimeInterval(1)), "突发 3 小时后消失")
    require(collapsedStories(decorated.sorted { $0.date! > $1.date! }).count == 1, "同一事件折叠成一行")
    require(storySourceLine(decorated[0], expanded: true) == "BBC、卫报等 4 家" && storySourceLine(decorated[0], expanded: false) == "BBC World · 4 家", "来源行")
    var single = WorldEvent(id: "s", sourceID: "dw", title: "Local council approves budget", url: URL(string: "https://example.com/s")!, date: now, timeKind: "发布", disaster: false, severity: nil)
    single = decoratedEvents([single], with: quick, now: now)[0]
    let hot = hotEvents(decorated + [single], now: now)
    require(hot.first?.storyID == story.id && hot.last?.id == "s" && hot.count == 2, "热点范围：多家事件在前，单家新闻在后")
    var filter = NewsFilter(); filter.mode = .personal; filter.blocked = ["Chile"]
    require(hotEvents(decorated, now: now, filter: filter).isEmpty, "代表行仍须通过新闻过滤")
    let disaster = WorldEvent(id: "q", sourceID: "usgs", title: "显著地震 M7.4", url: URL(string: "https://example.com/q")!, date: now, timeKind: "发生", disaster: true, severity: "显著地震", magnitude: 7.4)
    require(isBreaking(decoratedEvents([disaster], with: nil, now: now)[0], now: now) && storyOutlet(disaster) == nil, "7 级以上地震为突发且不计媒体")

    // Index maintenance.
    var index = updatedStoryIndex([:], with: quake.map(\.event), now: now)
    let firstSeen = index["a"]!.observedAt
    var retranslated = quake[0].event; retranslated.translatedTitle = "首都发生强烈地震"
    index = updatedStoryIndex(index, with: [retranslated], now: now.addingTimeInterval(60))
    require(index["a"]!.observedAt == firstSeen && index["a"]!.event.translatedTitle == "首都发生强烈地震", "译文晚到时更新文本、保留首次见到时间")
    require(updatedStoryIndex(index, with: [], now: now.addingTimeInterval(73 * 3600)).isEmpty, "72 小时过期")
    let many = (0..<2100).map { i in WorldEvent(id: "m\(i)", sourceID: "dw", title: "Item \(i)", url: URL(string: "https://example.com/m\(i)")!, date: now.addingTimeInterval(Double(-i)), timeKind: "发布", disaster: false, severity: nil) }
    let capped = updatedStoryIndex([:], with: many, now: now)
    require(capped.count == storyIndexLimit && capped["m0"] != nil && capped["m2099"] == nil, "2000 条上限保留最新")

    // Modes and widget fallback.
    require(NewsDisplayMode(rawValue: "hot") == .hot && NewsDisplayMode(rawValue: "latest") == .latest, "显示模式兼容")
    var snapshot = NewsSnapshot(date: now, events: [], availableSources: 1, note: nil, sourceFeeds: ["bbc": SourceSnapshot(events: decorated, fetchedAt: now)], displayMode: .hot, updatedAt: now)
    require(effectiveDisplayMode(snapshot, now: now) == .hot, "摘要新鲜时使用热点优先")
    require(effectiveDisplayMode(snapshot, now: now.addingTimeInterval(3 * 3600)) == .latest, "摘要超过 2 小时退回最新优先")
    snapshot.sourceFeeds = ["bbc": SourceSnapshot(events: quake.map(\.event), fetchedAt: now)]
    require(effectiveDisplayMode(snapshot, now: now) == .latest, "没有事件信息时退回最新优先")
    let lead = decorated.first { $0.storyLead == true }!
    let limited = limitedSourceFeeds(["bbc": SourceSnapshot(events: [lead] + many.prefix(150).map { WorldEvent(id: $0.id, sourceID: "bbc", title: $0.title, url: $0.url, date: $0.date, timeKind: "发布", disaster: false, severity: nil) }, fetchedAt: now)])
    require(limited["bbc"]!.events.contains { $0.id == lead.id } && limited["bbc"]!.events.count == retainedNewsLimit + 1, "热点代表行不占 100 条名额")
    print("PASS: 热点聚类夹具验收、确定性与性能、特征规则、媒体计数、热度与突发、折叠与热点排序、新闻过滤、灾害突发、索引过期与上限、热点模式降级与名额豁免")
}
