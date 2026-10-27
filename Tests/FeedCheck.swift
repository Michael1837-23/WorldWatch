import Foundation

@main struct FeedCheck {
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            var failures = 0
            await withTaskGroup(of: (String, Int?, String?).self) { group in
                for source in NewsSource.all {
                    group.addTask {
                        do { return (source.name, try await fetchSource(source).count, nil) }
                        catch { return (source.name, nil, error.localizedDescription) }
                    }
                }
                for await (name, count, error) in group {
                    if let count { print("PASS \(name): \(count) 条") }
                    else { failures += 1; print("FAIL \(name): \(error ?? "未知错误")") }
                }
            }
            if failures > 0 { exit(1) }
            return
        }
        let source = NewsSource.all.first { $0.id == "bbc" }!
        let rss = """
        <rss version="2.0"><channel>
        <item><title><![CDATA[A &amp; B]]></title><link>https://example.org/story</link><pubDate>Tue, 27 Oct 2026 05:06:07 GMT</pubDate></item>
        <item><title>Unsafe link</title><link>javascript:alert(1)</link></item>
        <item><title>No time</title><link>https://example.org/no-time</link></item>
        </channel></rss>
        """
        let events = try parseFeed(Data(rss.utf8), source: source)
        assert(events.count == 2 && events[0].title == "A & B")
        assert(events[0].timeKind == "发布" && events[0].date != nil)
        assert(events[1].date == nil, "缺失时间不能伪造成当前时间")
        assert(cleanTitle("Joy Behar &#8216;The View&#8217; &amp;quot;x&#x2014;y &bogus; &lt;b&gt;") == "Joy Behar ‘The View’ &quot;x—y &bogus; <b>", "实体单次解码，未知实体保留")
        let futureRSS = "<rss><channel><item><title>Future</title><link>https://example.org/future</link><pubDate>Tue, 27 Oct 2099 05:06:07 GMT</pubDate></item></channel></rss>"
        let future = try parseFeed(Data(futureRSS.utf8), source: source)
        assert(future[0].date == nil, "远未来的发布时间不能长期置顶")
        var translated = events[0]
        translated.translatedTitle = "测试中文标题"
        let roundtrip = try JSONDecoder().decode(WorldEvent.self, from: JSONEncoder().encode(translated))
        assert(roundtrip.displayTitle == "测试中文标题" && roundtrip.title == "A & B", "显示译文时保留原文")
        let oldJSON = """
        {"id":"legacy","sourceID":"bbc","title":"Original headline","url":"https://example.org/legacy","timeKind":"发布","disaster":false}
        """
        let legacy = try JSONDecoder().decode(WorldEvent.self, from: Data(oldJSON.utf8))
        assert(legacy.translatedTitle == nil && legacy.displayTitle == "Original headline", "升级后能读取旧缓存")
        do { _ = try parseFeed(Data("<html>not RSS</html>".utf8), source: source); fatalError("应拒绝 HTML 错误页") } catch {}
        do { _ = try parseFeed(Data("<rss><broken>".utf8), source: source); fatalError("应拒绝损坏 XML") } catch {}
        let gdacs = NewsSource.all.first { $0.id == "gdacs" }!
        let disasterXML = """
        <rss xmlns:gdacs="http://www.gdacs.org"><channel>
        <item><title>Orange event</title><link>https://example.org/disaster</link><gdacs:alertlevel>Orange</gdacs:alertlevel><gdacs:fromdate>Tue, 27 Oct 2026 01:00:00 GMT</gdacs:fromdate><pubDate>Tue, 27 Oct 2026 06:00:00 GMT</pubDate></item>
        <item><title>Green event</title><link>https://example.org/green</link><gdacs:alertlevel>Green</gdacs:alertlevel></item>
        </channel></rss>
        """
        let disasters = try parseFeed(Data(disasterXML.utf8), source: gdacs)
        assert(disasters.count == 1 && disasters[0].severity == "橙色预警")
        assert(disasters[0].timeKind == "发生" && disasters[0].date == parseDate("2026-10-27T01:00:00Z"))
        let quake = Data("""
        {"features":[{"id":"test-quake","properties":{"title":"M 6.2 - Test location","place":"Test location","mag":6.2,"time":1792886400000,"url":"https://earthquake.usgs.gov/earthquakes/eventpage/test"}}]}
        """.utf8)
        let quakes = try parseFeed(quake, source: NewsSource.all.first { $0.id == "usgs" }!)
        assert(quakes.count == 1 && quakes[0].timeKind == "发生")
        assert(quakes[0].date == Date(timeIntervalSince1970: 1792886400))
        let now = parseDate("2026-10-27T12:00:00Z")!
        let old = WorldEvent(id: "old", sourceID: "bbc", title: "Old", url: URL(string: "https://example.org/old")!, date: now.addingTimeInterval(-4 * 86400), timeKind: "发布", disaster: false, severity: nil)
        assert(mergedEvents(events + events + [old], now: now).count == 2)
        assert(mergedEvents(events + quakes, now: now).first?.id == events[0].id)
        assert(quakes[0].isNoteworthy && !events[0].isNoteworthy)
        for (title, expected) in [("President announces ceasefire", true), ("央行宣布降息", true), ("The country wins an award", false), ("First world war museum opens", false)] {
            let event = WorldEvent(id: title, sourceID: "bbc", title: title, url: URL(string: "https://example.org/test")!, date: now, timeKind: "发布", disaster: false, severity: nil)
            assert(event.isNoteworthy == expected, title)
        }
        print("PASS: RSS、CDATA、无效链接、缺失时间、错误页、GDACS等级与发生时间、USGS毫秒时间、去重与保留期限")
        print("PASS: 重点筛选保留重大主题与显著灾害，避免 award 误匹配 war 与历史纪念报道")
        print("PASS: 中文显示、原文保留、译文缓存序列化与旧版缓存兼容")
        func headline(_ id: String, _ title: String, _ sourceID: String, _ secondsAgo: Double) -> WorldEvent {
            WorldEvent(id: id, sourceID: sourceID, title: title, url: URL(string: "https://example.org/" + id)!, date: now.addingTimeInterval(-secondsAgo), timeKind: "发布", disaster: false, severity: nil)
        }
        let election1 = headline("israel-new", "Israel goes to polls in pivotal election", "bbc", 10)
        let election2 = headline("israel-old", "Turnout rises as Israelis vote in election", "guardian", 20)
        let other = headline("policy", "UK officials discuss treaty at summit", "guardian", 30)
        let digest = digestEvents([election2, other, election1], now: now)
        assert(digest.map(\.id) == ["israel-new", "policy"], "同一选举不要占满摘要，保留最新报道")
        let enabled = ["bbc", "guardian"]
        let initial = refreshedSnapshot(previous: nil, results: [.init(id: "bbc", events: [election1]), .init(id: "guardian", events: [other])], now: now, enabledIDs: enabled)
        let unchanged = refreshedSnapshot(previous: initial, results: [.init(id: "bbc", events: [election1]), .init(id: "guardian", events: [other])], now: now.addingTimeInterval(60), enabledIDs: enabled)
        assert(unchanged.date > initial.date && unchanged.changedAt == initial.changedAt, "检查时间推进不代表内容有更新")
        let partial = refreshedSnapshot(previous: unchanged, results: [.init(id: "bbc", events: nil), .init(id: "guardian", events: [other])], now: now.addingTimeInterval(120), enabledIDs: enabled)
        assert(partial.availableSources == 1 && partial.events.contains { $0.id == election1.id }, "单个来源失败时保留其新闻缓存")
        assert(partial.sourceFeeds?["bbc"]?.fetchedAt == unchanged.sourceFeeds?["bbc"]?.fetchedAt)
        let offline = refreshedSnapshot(previous: partial, results: [.init(id: "bbc", events: nil), .init(id: "guardian", events: nil)], now: now.addingTimeInterval(180), enabledIDs: enabled)
        assert(offline.availableSources == 0 && offline.date > partial.date && offline.lastSuccess == partial.lastSuccess)
        assert(sameDigest(offline.events, partial.events), "离线刷新不应清空摘要")
        let emptyFeed = refreshedSnapshot(previous: initial, results: [.init(id: "bbc", events: []), .init(id: "guardian", events: [other])], now: now.addingTimeInterval(200), enabledIDs: enabled)
        assert(!emptyFeed.events.contains { $0.sourceID == "bbc" }, "成功获取的空来源应清除过期内容")
        let disabledFeed = refreshedSnapshot(previous: initial, results: [.init(id: "guardian", events: [other])], now: now.addingTimeInterval(210), enabledIDs: ["guardian"])
        assert(disabledFeed.events.allSatisfy { $0.sourceID == "guardian" }, "禁用来源不应保留在组件摘要中")
        let mixed = [
            headline("china", "国内公共服务新规正式发布", "cns-china", 10),
            headline("world", "Scientists discover a rare island habitat", "bbc", 11),
            headline("finance", "Markets rally following quarterly earnings", "cnbc", 12),
            headline("tech", "New AI chip launches for data centres", "techcrunch", 13),
            headline("culture", "New film wins at international festival", "variety", 14),
            headline("sports", "Team wins cup final in extra time", "bbc-sport", 15),
            election1
        ]
        let balanced = digestPool(mixed, now: now)
        let tiedA = headline("tie-a", "Central bank announces new reserve rules", "cnbc", 1)
        let tiedB = headline("tie-b", "Company reports record quarterly revenue", "bbc-business", 1)
        assert(sameDigest(digestPool([tiedA, tiedB], now: now), digestPool([tiedB, tiedA], now: now)), "相同时间戳的排序不能依赖来源完成顺序")
        assert(Set(balanced.prefix(4).map(\.category)).count == 4, "四条摘要优先覆盖不同领域")
        assert(balanced.contains { $0.category == .entertainment } && balanced.contains { $0.category == .technology }, "文娱科技不能再被政治关键词过滤掉")
        assert(mixed[0].isDomestic && !mixed[3].isDomestic)
        let near1 = headline("near1", "OpenAI releases new AI model for coding tools", "bbc-tech", 1)
        let near2 = headline("near2", "OpenAI releases new AI model for coding tools today", "techcrunch", 2)
        assert(digestPool([near1, near2], now: now).count == 1, "跨来源近似标题去重")
        assert(canonicalNewsURL(URL(string: "https://example.org/story?utm_source=rss#top")!) == "https://example.org/story")
        var rotationSnapshot = initial
        rotationSnapshot.rotationEvents = balanced
        rotationSnapshot.checkedAt = now
        let entries = rotationTimeline(rotationSnapshot, now: now, minutes: 3)
        assert(entries.count == 3 && entries[1].date > entries[0].date)
        assert(entries[1].date.timeIntervalSince(entries[0].date) == 60)
        assert(entries.allSatisfy { $0.checkDate == now }, "轮播不能伪造新的联网检查时间")
        assert(Set(entries[0].events.map(\.id)).isDisjoint(with: Set(entries[1].events.map(\.id))), "相邻组展示不同报道")
        assert(entries.allSatisfy { $0.rotationEvents == nil && $0.sourceFeeds?.values.allSatisfy { $0.events.isEmpty } == true }, "时间线仅携带显示数据，避免重复打包全部来源")
        let smallEntries = rotationTimeline(rotationSnapshot, now: now, minutes: 2, pageSize: 1)
        assert(smallEntries.allSatisfy { $0.events.count == 1 } && smallEntries[0].events[0].id != smallEntries[1].events[0].id)
        let translatedOnly = WorldEvent(id: mixed[2].id, sourceID: mixed[2].sourceID, title: mixed[2].title, url: mixed[2].url, date: mixed[2].date, timeKind: "发布", disaster: false, severity: nil, translatedTitle: "市场上涨")
        assert(sameDigest([mixed[2]], [translatedOnly]), "译文完成不应伪报新增报道")
        print("PASS: 多领域混排、近似标题与链接去重、不同尺寸按分钟轮播、真实检查时间、精简时间线与译文状态")
        let newest = headline("breaking", "A new cross-border payment service launches", "cnbc", 0)
        let oldest = headline("older-tech", "A developer tool reaches general availability", "techcrunch", 300)
        let liveItems = [mixed[0], mixed[1], mixed[2], oldest]
        let beforeLatest = refreshedSnapshot(previous: nil, results: [.init(id: "cnbc", events: liveItems)], now: now, enabledIDs: ["cnbc"], mode: .latest)
        let afterLatest = refreshedSnapshot(previous: beforeLatest, results: [.init(id: "cnbc", events: liveItems + [newest])], now: now.addingTimeInterval(60), enabledIDs: ["cnbc"], mode: .latest)
        assert(afterLatest.events.first?.id == newest.id, "新报道按时间置顶")
        assert(afterLatest.events.dropFirst().map(\.id) == beforeLatest.events.prefix(3).map(\.id), "保留旧报道的稳定身份并顺次下移")
        let latestNow = widgetTimeline(afterLatest, now: now)
        let latestLater = widgetTimeline(afterLatest, now: now.addingTimeInterval(60))
        assert(latestNow.count == 1 && latestLater.count == 1 && sameDigest(latestNow[0].events, latestLater[0].events), "最新优先不会随时间自动轮换旧报道")
        var switched = afterLatest
        switched.displayMode = .rotation
        let switchedTimeline = widgetTimeline(switched, now: now)
        assert(switchedTimeline.count == 60 && switchedTimeline[0].checkDate == afterLatest.checkDate)
        let recoveredMode = try JSONDecoder().decode(NewsSnapshot.self, from: JSONEncoder().encode(switched))
        assert(recoveredMode.mode == .rotation && initial.mode == .latest, "模式可序列化，旧缓存默认最新优先")
        assert(widgetTimeline(afterLatest, now: now, pageSize: 1)[0].events.count == 1)
        print("PASS: 最新置顶、旧条目顺次下移、无新增不轮换、模式切换与兼容、小尺寸最新显示")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotStore = NewsSnapshotStore(fileURL: temporary.appendingPathComponent("snapshot.json"))
        try snapshotStore.write(offline)
        let acceptedOldSnapshot = try snapshotStore.write(initial)
        assert(!acceptedOldSnapshot, "迟到的旧请求不能覆盖新摘要")
        assert(snapshotStore.read()?.date == offline.date)
        try FileManager.default.removeItem(at: temporary)
        print("PASS: 摘要去重、检查/内容时间区分、部分失败与离线缓存、空来源清理、来源开关同步、旧请求写入保护")
        if let index = CommandLine.arguments.firstIndex(of: "--fixtures"), CommandLine.arguments.count > index + 1 {
            let directory = CommandLine.arguments[index + 1]
            for (id, file) in [("bbc", "BBCWorld"), ("bbc-zh", "BBCChinese"), ("guardian", "Guardian"), ("usgs", "USGS")] {
                let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/monitor-" + file + ".feed"))
                let parsed = try parseFeed(data, source: NewsSource.all.first { $0.id == id }!)
                assert(!parsed.isEmpty && parsed.contains { $0.date != nil })
                print("PASS: 真实来源 \(file) · \(parsed.count) 条 · \(mergedEvents(parsed).count) 条仍在保留期")
            }
        }
    }
}
