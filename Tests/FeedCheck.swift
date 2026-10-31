import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func cameraHTTPDateString(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return formatter.string(from: date)
}

@main struct FeedCheck {
    static func main() async throws {
        if CommandLine.arguments.contains("--map-layers") {
            let store = MapLayerStore(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/acceptance-2.7/MapLayers"))
            let preferencesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/R58LB5VQ4A.local.michael.worldwatch/Library/Preferences/R58LB5VQ4A.local.michael.worldwatch.plist")
            let preferences = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: preferencesURL), format: nil)) as? [String: Any]
            let ids = preferences?["cameraCities"] as? [String] ?? CameraCity.defaults
            let cities = Array(ids.compactMap { id in CameraCity.all.first { $0.id == id } }.prefix(4))
            _ = await MapLayerService(store: store).refresh(cities: cities, minimumAge: 0, budget: 40)
            let now = Date()
            print("实测 UTC：\(now.formatted(.iso8601))")
            let cyclones = store.cyclones(at: now)
            print("活跃台风：\(cyclones.count)")
            for track in cyclones { print("\(track.name) · \(track.red ? "Red" : "Orange") · 历史 \(track.history.count)／预测 \(track.forecast.count)") }
            for city in cities { print("城市 \(city.englishName) \(cityConditions(city, at: now, weather: store.weather()))") }
            let orbit = store.station()
            print("ISS 轨迹点数：\(orbit.count)")
            if let position = issPosition(orbit, at: now) { print("ISS：\(position.latitude), \(position.longitude)") }
            let group = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/R58LB5VQ4A.local.michael.worldwatch/WorldWatch/widget-snapshot.json")
            if let snapshot = NewsSnapshotStore(fileURL: group).read() {
                let ongoing = store.ongoing()
                print("持续冲突来源：UCDP \(ongoing.version)，\(ongoing.monthLabel)，国家汇总 \(ongoing.countries.count)")
                let signals = snapshot.conflictSignals ?? conflictSignals(snapshot.sourceFeeds?.values.flatMap(\.events) ?? snapshot.events, now: now)
                for item in mapConflicts(signals: signals, ongoing: ongoing, now: now).prefix(15) {
                    print("冲突 \(WorldMap.countries.first { $0.id == item.countryID }!.name)：\(item.score) 分／\(item.level) 级")
                }
            }
            return
        }
        if CommandLine.arguments.contains("--cameras") {
            let store = CameraSnapshotStore(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/camera-probe"))
            let service = CameraService(store: store)
            let oldInterval = CameraCity.interval
            CameraCity.interval = 300
            defer { CameraCity.interval = oldInterval }
            let flag = CommandLine.arguments.firstIndex(of: "--cameras")!
            let requested = CommandLine.arguments.dropFirst(flag + 1).first
            let cities = requested.map { wanted in CameraCity.all.filter { $0.id == wanted } } ?? CameraCity.all
            for start in stride(from: 0, to: cities.count, by: 4) {
                _ = await service.refresh(cities: Array(cities[start..<min(start + 4, cities.count)]), budget: 90, force: true, resetCooldown: true, diagnostic: true)
            }
            for city in cities {
                let manifest = store.read(city.id)
                print("\(manifest?.frames.isEmpty == false ? "PASS" : "FAIL") \(city.name): \(manifest?.frames.count ?? 0) 张 · \(manifest?.error ?? "成功")")
                for source in store.pool(city) {
                    let record = store.health()[source.id] ?? CameraHealth()
                    print("  来源 \(source.id) · \(record.state.title) · \(record.reason ?? "") · \(source.page.absoluteString)")
                }
                for frame in manifest?.frames ?? [] { print("  \(frame.sourceType) · \(frame.page.absoluteString) · \(frame.imageURL.absoluteString)") }
            }
            return
        }
        if CommandLine.arguments.contains("--live") {
            var failures = 0
            let flag = CommandLine.arguments.firstIndex(of: "--live")!
            let requested = CommandLine.arguments.dropFirst(flag + 1).first
            await withTaskGroup(of: (String, Int?, String?).self) { group in
                for source in NewsSource.all where requested == nil || source.id == requested {
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
        let tech = headline("filter-tech", "AI chip launch", "techcrunch", 2)
        let finance = headline("filter-finance", "Markets rally as AI chips rise", "cnbc", 3)
        let bbc = headline("filter-bbc", "AI chip launch", "bbc", 1)
        let technologyOnly = Set(NewsCategory.allCases.map(\.rawValue)).subtracting([NewsCategory.technology.rawValue])
        var eventOnly = NewsFilter(); eventOnly.eventOnly = true
        let hamilton = headline("hamilton", "F1 has never had anyone like me - Hamilton", "bbc-sport", 0)
        let profile = headline("profile", "敦煌印象：画家的壁上人生", "cns-culture", 1)
        let explanation = headline("explanation", "Why electric cars are changing the market", "bbc", 2)
        let opened = headline("opened", "第十六届中国国际薯业博览会在成都开幕", "cns-finance", 3)
        let attack = headline("attack", "Russia strikes energy facilities in Kyiv", "france24", 4)
        let reportWithHow = headline("how-event", "How Israel choked off Hebron as 5,000 forced to flee", "bbc", 4)
        let movie = headline("movie", "纪录电影《白茶人生》在福鼎公映", "cns-culture", 5)
        assert(applyNewsFilter([hamilton, profile, explanation, opened, attack, reportWithHow, movie], filter: eventOnly).map(\.id) == ["opened", "attack", "how-event", "movie"])
        var translationOnly = headline("translation-only", "A racing champion speaks", "bbc-sport", 1)
        translationOnly.translatedTitle = "F1从来没有像我这样的人——汉密尔顿"
        assert(!newsFilterAllows(translationOnly, filter: eventOnly), "译文也参与判断")
        var personalEvents = NewsFilter(mode: .personal, followed: ["Hamilton"], eventOnly: true)
        assert(newsFilterAllows(hamilton, filter: personalEvents), "关注词仍能保留对应报道")
        personalEvents.blocked = ["Hamilton"]
        assert(!newsFilterAllows(hamilton, filter: personalEvents), "屏蔽词优先")
        let eventFilterDisaster = WorldEvent(id: "disaster-explainer", sourceID: "gdacs", title: explanation.title, url: explanation.url, date: now, timeKind: "发生", disaster: true, severity: nil)
        assert(newsFilterAllows(eventFilterDisaster, filter: eventOnly), "灾害不受标题启发式过滤")
        let oldFilter = try JSONDecoder().decode(NewsFilter.self, from: Data(#"{"mode":"personal","excludedCategories":[],"excludedSources":[],"followed":[],"blocked":[],"followOnly":false}"#.utf8))
        assert(!oldFilter.eventsOnly && oldFilter.mode == .personal, "旧过滤设置保持兼容")
        let decodedEventOnly = try JSONDecoder().decode(NewsFilter.self, from: JSONEncoder().encode(eventOnly))
        assert(decodedEventOnly.eventsOnly)
        let eventFilterSnapshot = NewsSnapshot(date: now, events: [hamilton, opened], availableSources: 1, note: nil,
            sourceFeeds: ["fixture": SourceSnapshot(events: [hamilton, opened, attack], fetchedAt: now)])
        let eventWidgetIDs = widgetTimeline(eventFilterSnapshot, now: now, pageSize: 9, filter: eventOnly)[0].events.map(\.id)
        assert(!eventWidgetIDs.contains("hamilton") && eventWidgetIDs.contains("opened") && eventWidgetIDs.contains("attack"), "组件新闻与应用共用事件过滤")
        print("PASS: 事件过滤识别访谈、人物介绍与解说，保留真实事件及灾害，兼容关注词和旧设置")
        var custom = NewsFilter(mode: .personal, excludedCategories: technologyOnly)
        assert(applyNewsFilter([tech, finance, bbc], filter: NewsFilter()).count == 3)
        assert(newsFilterAllows(tech, filter: custom) && !newsFilterAllows(finance, filter: custom))
        custom.excludedSources.insert("techcrunch")
        assert(!newsFilterAllows(tech, filter: custom))
        var noBBC = NewsFilter(mode: .personal); noBBC.excludedSources.insert("bbc")
        assert(!newsFilterAllows(bbc, filter: noBBC) && newsFilterAllows(tech, filter: noBBC))
        assert(newsFilterAllows(headline("new-source", "Fresh product", "future-source", 1), filter: NewsFilter(mode: .personal)), "未知新来源默认选择")
        custom.followed = [" ai "]
        assert(newsFilterAllows(finance, filter: custom) && newsFilterAllows(tech, filter: custom), "关注词覆盖领域和来源")
        assert(!newsFilterAllows(headline("said", "She said hello", "bbc", 1), filter: custom))
        custom.followOnly = true
        assert(!newsFilterAllows(headline("not-followed", "Apple launches Mac", "techcrunch", 1), filter: custom))
        assert(newsFilterAllows(headline("capitals", "AI CHIP news", "bbc", 1), filter: custom))
        custom.blocked = ["AI"]
        assert(!newsFilterAllows(tech, filter: custom) && newsFilterAllows(finance, filter: custom) == false, "屏蔽词优先")
        custom.followed = ["US"]; custom.blocked = []
        assert(!newsFilterAllows(headline("virus", "virus spreads", "bbc", 1), filter: custom))
        assert(newsFilterAllows(headline("us-news", "US officials report", "bbc", 1), filter: custom))
        custom.followed = ["苹果"]
        var translatedApple = headline("apple", "Apple releases MacBook", "bbc", 1)
        translatedApple.translatedTitle = "蘋果发布新款 MacBook"
        assert(newsFilterAllows(translatedApple, filter: custom))
        custom.followed = ["蘋果"]
        translatedApple.translatedTitle = "苹果发布新款 MacBook"
        assert(newsFilterAllows(translatedApple, filter: custom))
        assert(cleanedKeywords([" AI ", "ai", "蘋果", "苹果", "  "]).count == 2)
        assert(cleanedKeywords((0..<60).map { "word\($0)" }).count == 50)
        let encodedFilter = try JSONEncoder().encode(custom.cleaned)
        let decodedFilter = try JSONDecoder().decode(NewsFilter.self, from: encodedFilter)
        assert(decodedFilter == custom.cleaned)
        let suiteName = "WorldWatch-filter-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        assert(NewsFilter.read(from: defaults) == NewsFilter())
        defaults.set(encodedFilter, forKey: "newsFilter")
        assert(NewsFilter.read(from: defaults) == custom.cleaned)
        defaults.removePersistentDomain(forName: suiteName)
        var orderedFilter = NewsFilter(mode: .personal, excludedCategories: technologyOnly)
        let beforeDedup = latestEvents([bbc, tech, finance], now: now, domesticRatio: nil, filter: orderedFilter)
        assert(beforeDedup.map(\.id) == [tech.id], "先过滤才能保留同标题的科技报道")
        orderedFilter.followed = ["AI"]
        let personalLatest = latestEvents([bbc, tech, finance], now: now, domesticRatio: 1.0 / 3, filter: orderedFilter)
        assert(personalLatest.allSatisfy { newsFilterAllows($0, filter: orderedFilter) })
        let domestic = headline("filter-domestic", "国内 AI 政策", "cns-china", 0)
        let mixedFiltered = latestEvents([domestic, bbc, finance], now: now, domesticRatio: 1.0 / 3, filter: orderedFilter)
        assert(mixedFiltered.allSatisfy { newsFilterAllows($0, filter: orderedFilter) })
        let d0 = headline("d0", "国内公共服务方案", "cns-china", 0)
        let d1 = headline("d1", "国内农业生产进展", "cns-society", 1)
        let f0 = headline("f0", "Market prices rise", "cnbc", 2)
        let f1 = headline("f1", "Companies announce earnings", "cnbc", 3)
        let abroad = headline("abroad", "World science report", "bbc", 4)
        var noFinance = NewsFilter(mode: .personal); noFinance.excludedCategories.insert(NewsCategory.finance.rawValue)
        assert(latestEvents([d0, d1, f0, f1, abroad], now: now, domesticRatio: 1.0 / 3, filter: noFinance).map(\.id) == ["d0", "abroad", "d1"], "过滤后再按国内占比排序")
        let snapshot = NewsSnapshot(date: now, events: [bbc, tech, finance], availableSources: 1, note: nil,
                                    sourceFeeds: ["fixture": SourceSnapshot(events: [bbc, tech, finance], fetchedAt: now)])
        let personalEntries = widgetTimeline(snapshot, now: now, filter: orderedFilter)
        assert(personalEntries.count == 1 && personalEntries[0].events.allSatisfy { newsFilterAllows($0, filter: orderedFilter) })
        var none = orderedFilter; none.followOnly = true; none.followed = []
        assert(widgetTimeline(snapshot, now: now, filter: none)[0].note == "没有符合个性设置的新闻")
        var rotatingSnapshot = snapshot; rotatingSnapshot.displayMode = .rotation
        let filteredRotation = widgetTimeline(rotatingSnapshot, now: now, filter: none)
        assert(filteredRotation.count == 60 && filteredRotation.allSatisfy { $0.events.isEmpty && $0.note == "没有符合个性设置的新闻" })
        let conflictEvents = [headline("conflict-filter", "Missile attack hits Iran", "bbc", 1)]
        let conflictsBefore = mapConflicts(conflictEvents, now: now)
        _ = applyNewsFilter(conflictEvents, filter: none)
        assert(!conflictsBefore.isEmpty && mapConflicts(conflictEvents, now: now) == conflictsBefore, "地图仍使用原始新闻")
        print("PASS: 个性新闻领域/来源、关注与屏蔽优先级、中英/简繁/大小写/单词边界、关键词去重上限、JSON与默认、先过滤后去重和国内占比、组件空态及地图不受影响")
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
        let similarity = [
            headline("sim1", "alpha beta gamma delta epsilon", "bbc", 1),
            headline("sim2", "alpha beta gamma delta zeta", "guardian", 2),
            headline("sim3", "alpha beta gamma theta iota", "bbc", 3),
            headline("sim4", "alpha beta gamma delta epsilon eta zeta theta iota kappa", "bbc", 4),
            headline("sim5", "red blue cat", "bbc", 5),
            headline("sim6", "red blue cat dog", "guardian", 6)
        ]
        assert(uniqueNewsEvents(similarity, mergeTopics: false, now: now).map(\.id) == ["sim1", "sim3", "sim4", "sim5"], "保持原 Jaccard 阈值与短标题比较规则")
        let terms = (0..<20).map { String(format: "word%02d", $0) }
        let boundary1 = headline("boundary1", terms.prefix(13).joined(separator: " "), "bbc", 1)
        let boundary2 = headline("boundary2", terms.joined(separator: " "), "guardian", 2)
        assert(uniqueNewsEvents([boundary1, boundary2], mergeTopics: false, now: now).count == 1, "相似度恰为 0.65 时仍去重")
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
        let domesticFlood = (0..<6).map { headline("cn\($0)", "国内新闻\($0)", "cns-china", Double($0)) } + [headline("world-a", "Global summit opens", "bbc", 10), headline("world-b", "Markets steady", "cnbc", 20)]
        let capped = balancedByOrigin(mergedEvents(domesticFlood, now: now), ratio: 1.0 / 3)
        assert(capped.count == domesticFlood.count && capped.prefix(3).filter(\.isDomestic).count == 1, "国内占比上限只顺延，不丢弃")
        assert(capped.prefix(3).map(\.id) == ["cn0", "world-a", "world-b"])
        assert(balancedByOrigin(mergedEvents(domesticFlood, now: now), ratio: nil).prefix(3).allSatisfy(\.isDomestic), "不限时保持纯时间顺序")
        func eventTitle(_ title: String, _ source: String = "bbc") -> Bool { isEventHeadline(headline("ev-" + title, title, source, 1)) }
        assert(!eventTitle("Black Doves actress says she loved playing 'a very Welsh assassin'"), "访谈式「某人说她喜欢」不算事件")
        assert(!eventTitle("‘Paycheck to paycheck’: Texas border voters shed parties amid economic hardship"), "引语开头的特写不算事件")
        assert(eventTitle("Fallon Sherrock pulls off shock defeat of world darts No 1 Luke Littler"))
        assert(eventTitle("2027版熊猫贵金属纪念币发行仪式在京举行", "cns-finance"))
        assert(!eventTitle("Trump vs MAGA: Why his movement is splitting"), "冒号后的为什么属于解读")
        assert(!eventTitle("清香“调”进江南：汾酒城市巡游杭州站，看见传统名酒的“慢表达”", "cns-finance"), "软文不算事件")
        assert(!eventTitle("Can Democrats win the US Senate? 10 key midterm races to watch") && !eventTitle("Massive Gen Z protests set to sweep cities across Germany"))
        assert(eventTitle("北海道特急深夜撞熊出轨 乘客被迫车内过夜", "cna") && eventTitle("Rival US and Russian resolutions on Western Sahara fail at UN"))
        assert(!eventTitle("Britain’s Prime Minister Says He’s Open to a Formal Apology"), "只有「说」没有动作不算事件")
        assert(eventTitle("Players' union strikes over pay cuts"), "所有格撇号不误判为引语开头")
        let unSource = NewsSource.all.first { $0.id == "un" }!
        let unXML = "<rss><channel><item><title>Somalia looks to the future</title><link>https://news.un.org/en/story/1</link><pubDate>\(cameraHTTPDateString(Date()))</pubDate></item></channel></rss>"
        let unEvents = try parseFeed(Data(unXML.utf8), source: unSource)
        assert(unEvents[0].timeKind == "日期" && unEvents[0].date! <= Date() && ["今天", "昨天"].contains(eventTimeLabel(unEvents[0]) ?? ""), "只有日期的来源不显示占位时刻，也不排到当前时间之后")
        assert(plausiblePublishDate(Date().addingTimeInterval(1200)) == nil && plausiblePublishDate(Date().addingTimeInterval(120)) != nil, "超过 5 分钟的未来时间视为未知")
        print("PASS: 只有日期的来源与未来时间、事件类新闻判断、国内新闻占比上限、最新置顶、旧条目顺次下移、无新增不轮换、模式切换与兼容、小尺寸最新显示")
        let recentNews = (0..<160).map { index in
            headline("limited-\(index)", "News item \(index)", index.isMultiple(of: 2) ? "bbc" : "guardian", Double(index))
        }
        let limited = limitedSourceFeeds([
            "bbc": SourceSnapshot(events: recentNews.filter { $0.sourceID == "bbc" }, fetchedAt: now),
            "guardian": SourceSnapshot(events: recentNews.filter { $0.sourceID == "guardian" }, fetchedAt: now),
            "empty": SourceSnapshot(events: [], fetchedAt: now)
        ])
        let retained = mergedEvents(limited.values.flatMap(\.events), now: now)
        assert(retained.map(\.id) == recentNews.prefix(100).map(\.id), "所有来源合计只保留最新 100 条")
        assert(limited["empty"]?.events.isEmpty == true && limited["bbc"]?.fetchedAt == now, "保留空来源和检查时间")
        let quakeEvent = WorldEvent(id: "usgs:old", sourceID: "usgs", title: "M6.8", url: URL(string: "https://example.org/q")!,
                                    date: now.addingTimeInterval(-86400), timeKind: "发生", disaster: true, severity: "显著地震", latitude: 1, longitude: 2, magnitude: 6.8)
        let withDisaster = limitedSourceFeeds([
            "bbc": SourceSnapshot(events: recentNews.filter { $0.sourceID == "bbc" }, fetchedAt: now),
            "guardian": SourceSnapshot(events: recentNews.filter { $0.sourceID == "guardian" }, fetchedAt: now),
            "usgs": SourceSnapshot(events: [quakeEvent], fetchedAt: now)
        ])
        assert(withDisaster["usgs"]?.events.map(\.id) == [quakeEvent.id], "地震与灾害不受 100 条上限挤占")
        assert(withDisaster.filter { $0.key != "usgs" }.values.flatMap(\.events).count == 100, "普通新闻仍保留 100 条")
        let limitedSnapshot = refreshedSnapshot(previous: nil, results: [
            .init(id: "bbc", events: recentNews.filter { $0.sourceID == "bbc" }),
            .init(id: "guardian", events: recentNews.filter { $0.sourceID == "guardian" })
        ], now: now, enabledIDs: ["bbc", "guardian"])
        assert(limitedSnapshot.sourceFeeds?.values.reduce(0, { $0 + $1.events.count }) == 100, "组件联网更新也遵守总量上限")
        print("PASS: 多来源缓存及组件摘要合计保留最新 100 条，来源状态不丢失")
        assert(widgetReloadDelay(last: now, now: now.addingTimeInterval(5), newsChanged: true) == 10)
        assert(widgetReloadDelay(last: now, now: now.addingTimeInterval(5), newsChanged: false) == 50)
        assert(widgetReloadDelay(last: now, now: now.addingTimeInterval(16), newsChanged: true) == 0)
        var firstUpdate = initial
        firstUpdate.checkedAt = now
        firstUpdate.updatedAt = now.addingTimeInterval(5)
        let laterHeadline = headline("incremental", "A new breakthrough in vaccines", "bbc", 0)
        var incremental = refreshedSnapshot(previous: firstUpdate,
            results: [SourceFetchResult(id: "bbc", events: [laterHeadline], fetchedAt: now.addingTimeInterval(10))],
            now: now, enabledIDs: enabled)
        incremental.updatedAt = now.addingTimeInterval(10)
        assert(incremental.checkDate == now && incremental.revisionDate == now.addingTimeInterval(10), "增量内容不能伪造整轮检查时间")
        assert(incremental.sourceFeeds?["bbc"]?.events.first?.id == laterHeadline.id && incremental.sourceFeeds?["guardian"]?.events.first?.id == other.id)
        assert(incremental.sourceFeeds?["bbc"]?.fetchedAt == now.addingTimeInterval(10))
        assert(widgetNewsChanged(from: firstUpdate, to: incremental, filter: NewsFilter(), now: now))
        let preserved = refreshedSnapshot(previous: incremental,
            results: [SourceFetchResult(id: "bbc", events: [election1], fetchedAt: now.addingTimeInterval(9))],
            now: now.addingTimeInterval(11), enabledIDs: enabled)
        assert(preserved.sourceFeeds?["bbc"]?.events.first?.id == laterHeadline.id, "较旧来源不能覆盖新来源")
        let cleared = refreshedSnapshot(previous: incremental,
            results: [SourceFetchResult(id: "bbc", events: [], fetchedAt: now.addingTimeInterval(11))],
            now: now.addingTimeInterval(11), enabledIDs: enabled)
        assert(cleared.sourceFeeds?["bbc"]?.events.isEmpty == true, "较新的成功空来源仍清除旧新闻")
        assert(newerSnapshot(firstUpdate, incremental)?.revisionDate == incremental.revisionDate)
        assert(newerSnapshot(incremental, firstUpdate)?.revisionDate == incremental.revisionDate)
        assert(newerSnapshot(nil, incremental)?.revisionDate == incremental.revisionDate)
        var hiddenChange = incremental
        hiddenChange.sourceFeeds?["bbc"]?.events = [headline("hidden", "No matching keyword", "bbc", 0)]
        let noMatches = NewsFilter(mode: .personal, followed: ["不存在的关键词"], followOnly: true)
        assert(!widgetNewsChanged(from: firstUpdate, to: hiddenChange, filter: noMatches, now: now), "不可见的新闻变化不触发快速重载")
        var translatedChanged = incremental
        translatedChanged.sourceFeeds?["bbc"]?.events[0].translatedTitle = "疫苗新进展"
        assert(widgetNewsChanged(from: incremental, to: translatedChanged, filter: NewsFilter(), now: now), "可见标题译文变化应快速重载")
        let translationFilter = NewsFilter(mode: .personal, followed: ["疫苗"], followOnly: true)
        assert(widgetNewsChanged(from: incremental, to: translatedChanged, filter: translationFilter, now: now), "译文可让原先未显示的新闻命中个性关键词")
        print("PASS: 新闻重载15秒优先、常规55秒、增量摘要保留真实检查时间与新来源、空来源清理、最新摘要选择和可见内容变化")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotStore = NewsSnapshotStore(fileURL: temporary.appendingPathComponent("snapshot.json"))
        let revisionStore = NewsSnapshotStore(fileURL: temporary.appendingPathComponent("revision/snapshot.json"))
        try revisionStore.write(incremental)
        let acceptedRevision = try revisionStore.write(firstUpdate)
        assert(!acceptedRevision && revisionStore.read()?.revisionDate == incremental.revisionDate, "迟到的增量摘要不能覆盖新版本")
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            var candidate = incremental
            candidate.updatedAt = now.addingTimeInterval(Double(index + 20))
            try! revisionStore.write(candidate)
        }
        assert(revisionStore.read()?.revisionDate == now.addingTimeInterval(39), "并发写入时最晚摘要胜出")
        let decodedIncremental = try JSONDecoder().decode(NewsSnapshot.self, from: JSONEncoder().encode(incremental))
        assert(decodedIncremental.checkDate == now && decodedIncremental.revisionDate == incremental.revisionDate)
        let legacySnapshot = try JSONDecoder().decode(NewsSnapshot.self, from: JSONEncoder().encode(initial))
        assert(legacySnapshot.updatedAt == nil && legacySnapshot.revisionDate == legacySnapshot.checkDate)
        try snapshotStore.write(offline)
        let acceptedOldSnapshot = try snapshotStore.write(initial)
        assert(!acceptedOldSnapshot, "迟到的旧请求不能覆盖新摘要")
        assert(snapshotStore.read()?.date == offline.date)
        try FileManager.default.removeItem(at: temporary)
        print("PASS: 摘要去重、检查/内容时间区分、部分失败与离线缓存、空来源清理、来源开关同步、旧请求写入保护")
        let locatedQuake = Data(#"{"features":[{"id":"point","properties":{"title":"M 6.8","mag":6.8,"time":1792886400000,"url":"https://example.org/q"},"geometry":{"coordinates":[121.5,23.4,10]}}]}"#.utf8)
        let located = try parseFeed(locatedQuake, source: NewsSource.all.first { $0.id == "usgs" }!)[0]
        assert(located.longitude == 121.5 && located.latitude == 23.4 && located.magnitude == 6.8)
        let pointXML = #"<rss xmlns:geo="http://www.w3.org/2003/01/geo/wgs84_pos#" xmlns:gdacs="http://www.gdacs.org"><channel><item><title>Red flood</title><link>https://example.org/flood</link><gdacs:alertlevel>Red</gdacs:alertlevel><geo:Point><geo:lat>25.1</geo:lat><geo:long>120.2</geo:long></geo:Point></item></channel></rss>"#
        let flood = try parseFeed(Data(pointXML.utf8), source: gdacs)[0]
        assert(flood.latitude == 25.1 && flood.longitude == 120.2 && legacy.latitude == nil && legacy.longitude == nil)
        assert(mapMarkers([located], now: located.date!.addingTimeInterval(3600)).first?.label == "M6.8")
        let rdf = #"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"><item><title>DW international</title><link>https://example.org/dw</link><dc:date>2026-10-27T12:00:00Z</dc:date></item></rdf:RDF>"#
        let rdfEvents = try parseFeed(Data(rdf.utf8), source: source)
        assert(rdfEvents.first?.date == now)
        let atom = #"<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Atom report</title><link rel="alternate" href="https://example.org/atom"/><updated>2026-10-27T12:00:00Z</updated></entry></feed>"#
        let atomEvents = try parseFeed(Data(atom.utf8), source: source)
        assert(atomEvents.first?.url.absoluteString == "https://example.org/atom")
        let cnaEvents = try parseFeed(Data("<rss><channel><item><title>美國與日本舉行會議</title><link>https://example.org/cna</link></item></channel></rss>".utf8), source: NewsSource.all.first { $0.id == "cna" }!)
        assert(cnaEvents.first?.displayTitle == "美国与日本举行会议" && cnaEvents.first?.title == "美國與日本舉行會議")
        assert(WorldMap.countries.count > 150)
        for id in ["CHN", "USA", "JPN"] { assert(WorldMap.countries.contains { $0.id == id && !$0.name.isEmpty && !$0.rings.isEmpty }) }
        let projection = MapProjection(bounds: .init(west: -180, east: 180, south: -90, north: 90), size: CGSize(width: 360, height: 180), fit: false)
        assert(projection.point(.init(longitude: 0, latitude: 0)) == CGPoint(x: 180, y: 90))
        for (coordinate, expected) in [(MapCoordinate(longitude: -180, latitude: 90), CGPoint.zero), (.init(longitude: 180, latitude: -90), CGPoint(x: 360, y: 180)), (.init(longitude: -180, latitude: -90), CGPoint(x: 0, y: 180)), (.init(longitude: 180, latitude: 90), CGPoint(x: 360, y: 0))] { assert(projection.point(coordinate) == expected) }
        let labelProjection = MapProjection(bounds: MapRegion.world.bounds, size: CGSize(width: 400, height: 200))
        let labels = mapLabels(projection: labelProjection)
        assert(labels == mapLabels(projection: labelProjection))
        for a in labels.indices { for b in labels.indices where a < b { assert(!labels[a].rect.intersects(labels[b].rect)) } }
        let larger = mapLabels(projection: MapProjection(bounds: MapRegion.world.bounds, size: CGSize(width: 800, height: 400)))
        assert(larger.count >= labels.count && larger.count <= 30)
        let compactMap = MapProjection(bounds: MapRegion.world.bounds, size: CGSize(width: 350, height: 145))
        let cityObstacles = ["shanghai", "hongkong", "beijing", "newyork", "london"].compactMap { id in CameraCity.all.first { $0.id == id } }.map { city -> MapLabel in
            let point = compactMap.visible(city.coordinate)
            return MapLabel(countryID: "city", text: "", rect: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
        }
        let compactLabels = mapLabels(projection: compactMap, reserved: cityObstacles).filter { !$0.text.isEmpty }
        assert(compactLabels.contains { $0.countryID == "CHN" } && compactLabels.contains { $0.countryID == "USA" }, "紧凑地图优先显示中美并避开城市圆点")
        assert(compactLabels.contains { $0.countryID == "continent:africa" && $0.text == "Africa" }, "非洲保留大陆标签")
        assert(!compactLabels.contains { ["MEX", "IND", "COD", "ARG"].contains($0.countryID) }, "全球地图只保留主要国家标签")
        let namedHotspots = mapLabels(projection: compactMap, reserved: cityObstacles, hotspots: [.init(countryID: "UKR", score: 14), .init(countryID: "SDN", score: 3), .init(countryID: "YEM", score: 3)])
        assert(namedHotspots.contains { $0.text == "Ukraine" } && namedHotspots.contains { $0.text == "Sudan" } && namedHotspots.contains { $0.text == "Yemen" }, "显色热点需要有名称")
        for a in namedHotspots.indices where !namedHotspots[a].text.isEmpty { for b in namedHotspots.indices where a != b { assert(!namedHotspots[a].rect.intersects(namedHotspots[b].rect)) } }
        let satelliteAtRussia = compactMap.visible(.init(longitude: 96, latitude: 51))
        let satelliteObstacle = MapLabel(countryID: "satellite", text: "", rect: CGRect(x: satelliteAtRussia.x - 6, y: satelliteAtRussia.y - 6, width: 12, height: 12))
        assert(mapLabels(projection: compactMap, reserved: cityObstacles + [satelliteObstacle], hotspots: [.init(countryID: "UKR", score: 14)]).contains { $0.countryID == "RUS" }, "卫星经过时俄罗斯名称不能消失")
        assert(abs(solarPosition(at: parseDate("2026-06-21T12:00:00Z")!).latitude - 23.4) < 1)
        assert(abs(solarPosition(at: parseDate("2026-12-21T12:00:00Z")!).latitude + 23.4) < 1)
        let sun = solarPosition(at: now)
        assert(!isNight(sun, sun: sun))
        assert(isNight(.init(longitude: sun.longitude + 180, latitude: -sun.latitude), sun: sun))
        let hits = mapConflicts([headline("israel-en", "Israel ceasefire", "bbc", 1), headline("israel-zh", "以色列停火", "cns-world", 2), headline("ireland", "Ireland opens a museum", "bbc", 3)], now: now)
        assert(hits.isEmpty, "低于 3 分不染色")
        assert(!hits.contains { $0.countryID == "IRN" })
        assert(youtubeVideoIDs(#"{"videoId":"abcdefghijk"}{"videoId":"123456789_-"}{"videoId":"abcdefghijk"}"#) == ["abcdefghijk", "123456789_-"])
        let youtubeHTML = #"<script>var ytInitialData = {"contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Tokyo Shibuya live camera"}]},"badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_LIVE_NOW"}}]}},{"videoRenderer":{"videoId":"123456789_-","title":{"runs":[{"text":"Paris SkylineWebcams"}]},"badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_LIVE_NOW"}}]}}]};</script>"#
        assert(cityYouTubeIDs(youtubeHTML, city: CameraCity.all.first { $0.id == "tokyo" }!) == ["abcdefghijk"])
        assert(cityYouTubeIDs(youtubeHTML, city: CameraCity.all.first { $0.id == "beijing" }!).isEmpty)
        assert(bilibiliKeyframe(Data(#"{"data":{"live_status":1,"keyframe":"http://example.org/camera.jpg"}}"#.utf8))?.absoluteString == "https://example.org/camera.jpg")
        assert(bilibiliKeyframe(Data(#"{"data":{"live_status":0,"keyframe":"http://example.org/camera.jpg"}}"#.utf8)) == nil)
        assert(bilibiliRoomIDs(#"<a href="//live.bilibili.com/3291055?x=1">a</a><a href="https://live.bilibili.com/h5/856077">b</a><a href="//live.bilibili.com/3291055">c</a>"#) == [3291055, 856077])
        let beijing = CameraCity.all.first { $0.id == "beijing" }!, chongqing = CameraCity.all.first { $0.id == "chongqing" }!
        assert(bilibiliSceneTitle("窗外街景｜北京朝阳大悦城实时街景", city: beijing))
        let newYork = CameraCity.all.first { $0.id == "newyork" }!
        assert(bilibiliSceneTitle("纽约时代广场实时街景", city: newYork))
        assert(!bilibiliSceneTitle("纽约街景点歌聊天", city: newYork))
        assert(!bilibiliSceneTitle("【直播】重庆狼队 vs 长沙TES.A", city: chongqing) && !bilibiliSceneTitle("窗外街景｜北京朝阳大悦城实时街景", city: chongqing), "排除电竞与其他城市")
        assert(WorldMap.countries.first { $0.id == "CHN" }?.name == "China" && WorldMap.countries.first { $0.id == "USA" }?.name == "United States")
        assert(mapConflicts([headline("china-en", "Missile airstrike hits China", "bbc", 1)], now: now).first?.countryID == "CHN", "英文 China 计入中国")
        assert(mapConflicts([headline("china-domestic", "中国发布新规", "cns-china", 1)], now: now).isEmpty, "国内来源不计入冲突")
        assert(cameraJPEG(Data(repeating: 0, count: 6000)) == nil)
        assert(cameraRotationIndex(entry: 19, city: 3, count: 1) == 0)
        assert((0..<4).map { cameraRotationIndex(entry: 0, city: $0, count: 3) } == [0, 1, 2, 0])
        assert((0..<4).map { cameraRotationIndex(entry: 1, city: $0, count: 3) } == [1, 2, 0, 1])
        let cameraStore = CameraSnapshotStore(root: temporary.appendingPathComponent("Cameras"))
        let latestCamera = CameraManifest(checkedAt: now, fetchedAt: now, frames: [], error: nil)
        try cameraStore.write(latestCamera, city: "tokyo")
        let acceptedCamera = try cameraStore.write(.init(checkedAt: now.addingTimeInterval(-1), frames: [], error: "older"), city: "tokyo")
        assert(!acceptedCamera && cameraStore.read("tokyo")?.checkedAt == now)
        let cachedFrame = CameraFrame(file: "batch/0.jpg", sourceType: "测试", page: URL(string: "https://example.org/camera")!, imageURL: URL(string: "https://example.org/image.jpg")!, fetchedAt: now)
        try cameraStore.write(.init(checkedAt: now, fetchedAt: now, frames: [cachedFrame], error: nil), city: "tokyo")
        let failedCity = CameraCity(id: "tokyo", name: "东京", keywords: [], candidates: [])
        let captured = await CameraService(store: cameraStore).refresh(cities: [failedCity], force: true)
        assert(!captured && cameraStore.read("tokyo")?.frames.first?.file == cachedFrame.file && cameraStore.read("tokyo")?.fetchedAt == now && cameraStore.read("tokyo")?.error != nil)
        func cameraSample(_ variant: Int = 0, side: Int = 360, solid: Bool = false) -> Data {
            let width = side, height = side * 2 / 3
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            var random: UInt64 = 123
            for y in 0..<height { for x in 0..<width {
                let column = x * 9 / width, row = y * 8 / height
                var value = 45 + (column * 37 + row * 19) % 160
                if row == 3 && column == 4 { value = variant == 1 ? 125 : 120 }
                if row == 3 && column == 5 { value = 121 }
                if variant == 2 { value = 255 - value }
                if solid { value = 80 }
                else { random = random &* 6364136223846793005 &+ 1; value += Int((random >> 32) % 7) - 3 }
                for c in 0..<3 { pixels[(y * width + x) * 4 + c] = UInt8(clamping: value) }
            } }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let output = NSMutableData()
            let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil); assert(CGImageDestinationFinalize(destination))
            return output as Data
        }
        let sample = cameraSample(), fingerprint = CameraFingerprint.make(sample)!
        let noise = CameraFingerprint.make(cameraSample(1))!, different = CameraFingerprint.make(cameraSample(2))!
        assert(fingerprint.hash == CameraFingerprint.make(sample)!.hash)
        let noiseDistance = (fingerprint.hash ^ noise.hash).nonzeroBitCount
        assert(noiseDistance > 0 && noiseDistance <= 2, "轻微噪声的 dHash 距离小且非零：\(noiseDistance)")
        assert((fingerprint.hash ^ different.hash).nonzeroBitCount > 30)
        assert(fingerprint.bytes >= CameraThresholds.minimumBytes && fingerprint.deviation > 3)
        var health = CameraHealth()
        health.observe(fingerprint, modified: nil, now: now)
        assert(health.state == .unverified && health.lastChanged == nil)
        health.observe(fingerprint, modified: nil, now: now.addingTimeInterval(120))
        assert(health.unchangedCount == 0 && health.lastComparedAt == now)
        health.observe(fingerprint, modified: nil, now: now.addingTimeInterval(300))
        assert(health.unchangedCount == 1)
        health.observe(fingerprint, modified: nil, now: now.addingTimeInterval(600))
        assert(health.state == .staticCover && health.cooldownUntil == now.addingTimeInterval(22200))
        health.observe(different, modified: nil, now: now.addingTimeInterval(900))
        assert(health.state == .live && health.unchangedCount == 0 && health.lastChanged == now.addingTimeInterval(900))
        var noisyHealth = CameraHealth()
        noisyHealth.observe(fingerprint, modified: nil, now: now)
        noisyHealth.observe(noise, modified: nil, now: now.addingTimeInterval(300))
        assert(noisyHealth.state == .live, "少量真实像素变化不误判为静态封面")
        var failingHealth = CameraHealth()
        for seconds in [600.0, 1800, 7200, 21600, 21600] {
            failingHealth.fail(now: now, reason: "超时")
            assert(failingHealth.state == .failing && failingHealth.cooldownUntil == now.addingTimeInterval(seconds))
        }
        var oldHealth = CameraHealth()
        oldHealth.observe(fingerprint, modified: now.addingTimeInterval(-7201), now: now)
        assert(oldHealth.state == .offline)
        var solidHealth = CameraHealth()
        solidHealth.observe(CameraFingerprint.make(cameraSample(solid: true))!, modified: nil, now: now)
        assert(solidHealth.state == .offline)
        var tinyHealth = CameraHealth()
        tinyHealth.observe(CameraFingerprint.make(cameraSample(side: 90))!, modified: nil, now: now)
        assert(tinyHealth.state == .offline)
        let imageLink = URL(string: "https://example.org/scene.jpg")!
        func testSource(_ id: String, _ platform: CameraPlatform = .official) -> CameraSource {
            .init(id: id, platform: platform, title: id, imageURL: imageLink, page: imageLink)
        }
        let yt1 = testSource("yt1", .youtube), yt2 = testSource("yt2", .youtube), yt3 = testSource("yt3", .youtube), sky = testSource("sky", .skyline)
        var rankingHealth = [yt1.id: health, yt2.id: health, yt3.id: health]
        assert(rankedCameraSources([yt1, sky], health: rankingHealth, now: now.addingTimeInterval(1000)).first?.id == sky.id, "从未检测的新来源优先被检测")
        var rotation = rankingHealth
        rotation[yt1.id]?.lastFetched = now.addingTimeInterval(-60); rotation[yt2.id]?.lastFetched = now.addingTimeInterval(-1800); rotation[yt3.id]?.lastFetched = now.addingTimeInterval(-600)
        assert(rankedCameraSources([yt1, yt2, yt3], health: rotation, now: now).map(\.id) == [yt2.id, yt3.id, yt1.id], "可用镜头按最久未抓取轮换")
        var covered = rotation; covered[yt2.id]?.state = .staticCover
        assert(rankedCameraSources([yt1, yt2, yt3], health: covered, now: now).last?.id == yt2.id, "封面冷却结束后排在可用镜头之后")
        rankingHealth[yt1.id]?.cooldownUntil = now.addingTimeInterval(2000)
        assert(rankedCameraSources([yt1, sky], health: rankingHealth, now: now.addingTimeInterval(1000)).map(\.id) == [sky.id])
        assert(rankedCameraSources([yt3, sky], health: rankingHealth, now: now.addingTimeInterval(1000), selected: [yt1, yt2]).first?.id == sky.id)
        assert(rankedCameraSources([sky], health: [:], skyline: false).isEmpty)
        assert(rankedCameraSources([yt1], health: [:], disabled: [yt1.id]).isEmpty)
        let skylineHTML = #"<a href="en/webcam/united-states/new-york/new-york/times-square.html"><img src="https://cdn.skylinewebcams.com/live538.webp">Times Square</a><a href="/en/webcam/france/ile-de-france/paris/tour-eiffel.html"><img src="https://cdn.skylinewebcams.com/live955.jpg">Eiffel Tower</a>"#
        let skyline = skylineSources(skylineHTML)
        assert(skyline.map(\.id) == ["skyline:538", "skyline:955"])
        assert(skyline[0].page.absoluteString == "https://www.skylinewebcams.com/en/webcam/united-states/new-york/new-york/times-square.html")
        assert(youtubeLiveVideoID(#"<link rel="canonical" href="https://www.youtube.com/watch?v=abcdefghijk"><script>var x={"videoId":"recommend01"};</script>"#) == "abcdefghijk")
        assert(youtubeLiveVideoID(#"{"videoDetails":{"videoId":"123456789_-","title":"Tokyo camera"}}"#) == "123456789_-")
        assert(youtubeLiveVideoID(#"{"videoId":"recommend01"}"#) == nil)
        assert(youtubeDeclaredLive(#"{"isLiveNow":false}"#) == false)
        assert(youtubePlayerTitle(#"{"videoDetails":{"videoId":"abcdefghijk","title":"Tokyo camera"}}"#) == "Tokyo camera")
        assert(cameraHTTPDate("Wed, 28 Oct 2026 12:00:00 GMT") != nil)
        let legacyFrame = Data(#"{"file":"batch/0.jpg","sourceType":"官方摄像头","page":"https://example.org/camera","imageURL":"https://example.org/image.jpg","fetchedAt":0}"#.utf8)
        let decodedFrame = try JSONDecoder().decode(CameraFrame.self, from: legacyFrame)
        assert(decodedFrame.sourceID == nil && decodedFrame.platform == nil)
        let legacyManifest = Data(#"{"checkedAt":0,"frames":[{"file":"batch/0.jpg","sourceType":"官方摄像头","page":"https://example.org/camera","imageURL":"https://example.org/image.jpg","fetchedAt":0}]}"#.utf8)
        let oldManifest = try JSONDecoder().decode(CameraManifest.self, from: legacyManifest)
        assert(oldManifest.frames.count == 1)
        let fallbackStore = CameraSnapshotStore(root: temporary.appendingPathComponent("Fallback"))
        let fallbackCity = CameraCity(id: "fixture", name: "样例", keywords: [], candidates: [])
        let failed = testSource("a-failure"), cover = testSource("b-cover"), good = testSource("c-good")
        try fallbackStore.writeState([fallbackCity.id: [failed, cover, good]], name: "sources.json")
        var coverHealth = CameraHealth()
        coverHealth.observe(fingerprint, modified: nil, now: Date().addingTimeInterval(-1500))
        coverHealth.observe(fingerprint, modified: nil, now: Date().addingTimeInterval(-1200))
        // Rotation tries the least recently fetched first; the good camera was fetched after the cover, so the cover is reached first.
        var goodHealth = CameraHealth(); goodHealth.lastFetched = Date().addingTimeInterval(-700)
        try fallbackStore.writeState([cover.id: coverHealth, good.id: goodHealth], name: "health.json")
        // Separate URLs ensure a first-candidate transport failure and a second-candidate cover both fall through.
        let distinctSources = [failed, cover, good].enumerated().map { index, source -> CameraSource in
            var source = source; source.imageURL = URL(string: "https://example.org/\(index).png")!; return source
        }
        try fallbackStore.writeState([fallbackCity.id: distinctSources], name: "sources.json")
        let fallbackService = CameraService(store: fallbackStore, request: { url, _ in
            if url.lastPathComponent == "0.png" { throw URLError(.timedOut) }
            return (sample, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        })
        let fellThrough = await fallbackService.refresh(cities: [fallbackCity], limit: 1, force: true)
        assert(fellThrough && fallbackStore.read(fallbackCity.id)?.frames.first?.sourceID == good.id)
        assert(fallbackStore.health()[failed.id]?.state == .failing && fallbackStore.health()[cover.id]?.state == .staticCover)
        assert(fallbackStore.sources()[fallbackCity.id]?.count == 3)
        let topUpStore = CameraSnapshotStore(root: temporary.appendingPathComponent("TopUp"))
        let topUpSources = ["x-cam", "y-cam"].enumerated().map { index, id -> CameraSource in
            var source = testSource(id); source.imageURL = URL(string: "https://example.org/top\(index).png")!; return source
        }
        try topUpStore.writeState([fallbackCity.id: topUpSources], name: "sources.json")
        let earlier = Date().addingTimeInterval(-3600)
        try topUpStore.write(CameraManifest(checkedAt: earlier, fetchedAt: earlier, frames: topUpSources.map { source in
            CameraFrame(file: "old/\(source.id).jpg", sourceType: "官方", page: source.page, imageURL: source.imageURL, fetchedAt: earlier, sourceID: source.id, platform: .official)
        }, error: nil), city: fallbackCity.id)
        let topUpService = CameraService(store: topUpStore, request: { url, _ in
            (sample, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        })
        _ = await topUpService.refresh(cities: [fallbackCity], limit: 1, force: true)
        let toppedUp = topUpStore.read(fallbackCity.id)?.frames.compactMap(\.sourceID) ?? []
        assert(Set(toppedUp) == ["x-cam", "y-cam"] && toppedUp.count == 2, "只抓到一张新图时用上一批其他镜头补足轮播")
        let sharedPageStore = CameraSnapshotStore(root: temporary.appendingPathComponent("SharedPage"))
        try sharedPageStore.writeState([fallbackCity.id: distinctSources], name: "sources.json")
        let sharedPageService = CameraService(store: sharedPageStore, request: { url, _ in
            (sample, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        })
        _ = await sharedPageService.refresh(cities: [fallbackCity], force: true)
        assert(sharedPageStore.read(fallbackCity.id)?.frames.count == 3, "同一官方观看页的不同镜头均可轮播")
        assert(CameraCity.all.flatMap(\.fixedSources).allSatisfy { !$0.page.absoluteString.contains("/en/webcam/en/webcam/") })
        let migratedStore = CameraSnapshotStore(root: temporary.appendingPathComponent("Migrated"))
        let shanghai = CameraCity.all.first { $0.id == "shanghai" }!
        let correct = shanghai.fixedSources.first { $0.platform == .skyline }!
        var incorrect = correct
        incorrect.page = URL(string: "https://www.skylinewebcams.com/en/webcam/en/webcam/china/shanghai/shanghai/skyline-of-shanghai.html")!
        try migratedStore.writeState([shanghai.id: [incorrect]], name: "sources.json")
        var fetched = CameraHealth(); fetched.lastFetched = Date(); fetched.state = .live
        try migratedStore.writeState([correct.id: fetched], name: "health.json")
        try migratedStore.write(.init(checkedAt: Date(), frames: [.init(file: "batch/0.jpg", sourceType: "SkylineWebcams", page: incorrect.page,
            imageURL: correct.imageURL, fetchedAt: Date(), sourceID: correct.id, platform: .skyline)], error: nil), city: shanghai.id)
        let migratedService = CameraService(store: migratedStore, request: { _, _ in throw URLError(.notConnectedToInternet) })
        _ = await migratedService.refresh(cities: [shanghai], limit: 1, force: true)
        assert(migratedStore.read(shanghai.id)?.frames.first?.page == correct.page)
        assert(migratedStore.sources()[shanghai.id]?.first { $0.id == correct.id }?.page == correct.page)
        let intervalStore = CameraSnapshotStore(root: temporary.appendingPathComponent("Interval"))
        let intervalSource = testSource("skyline:fixture", .skyline)
        try intervalStore.writeState([fallbackCity.id: [intervalSource]], name: "sources.json")
        var recent = CameraHealth()
        recent.lastFetched = Date(); recent.state = .live
        try intervalStore.writeState([intervalSource.id: recent], name: "health.json")
        let intervalService = CameraService(store: intervalStore, request: { _, _ in
            assertionFailure("立即检测也不得突破 Skyline 抓取间隔")
            throw URLError(.timedOut)
        })
        _ = await intervalService.refresh(cities: [fallbackCity], force: true, resetCooldown: true)
        assert(intervalStore.health()[intervalSource.id]?.failures == 0)

        assert(CameraCity.all.map(\.englishName) == ["Beijing", "Shanghai", "Hong Kong", "Chongqing", "Tokyo", "Taipei", "New York", "Los Angeles", "Paris", "London"])
        var uploadedCover = CameraHealth()
        uploadedCover.observe(fingerprint, modified: nil, etag: "\"\(Int(now.timeIntervalSince1970) - 86400 * 15)\"", now: now)
        assert(uploadedCover.state == .staticCover && uploadedCover.cooldownUntil != nil, "YouTube 封面 ETag 为旧上传时间戳时立即判为封面")
        var refreshing = CameraHealth()
        refreshing.observe(fingerprint, modified: nil, etag: "\"232310\"", now: now)
        assert(refreshing.state == .unverified, "小计数 ETag 是自动刷新的直播帧")
        var cached = CameraHealth(), stamp = now.addingTimeInterval(-600)
        for minutes in [0.0, 5, 10, 15] { cached.observe(fingerprint, modified: stamp, now: now.addingTimeInterval(minutes * 60)) }
        assert(cached.state == .unverified && cached.unchangedCount == 0, "Last-Modified 未变说明 CDN 缓存未更新，不计为静止")
        print("PASS: dHash 与微小像素变化、可用镜头轮换、封面状态机、封面 ETag 与 CDN 缓存不误判、四分钟比较间隔、失败退避、过期/纯色/小图、平台分散、当轮失败及封面顺延、来源持久化、Skyline/频道解析与旧 manifest")

        try FileManager.default.removeItem(at: temporary)
        print("PASS: 地震/GDACS坐标、旧缓存兼容、RSS 1.0/Atom、多国地图、投影四角、确定且无重叠的标签、昼夜与冲突边界")
        print("PASS: 直播ID去重与城市过滤、B站开播状态和HTTPS、B站房间号与街景标题过滤、国家短名与国内来源排除、无效图片拒绝、四城错位轮换、截图缓存旧请求保护")
        func earthquake(_ hours: Double, _ magnitude: Double) -> WorldEvent {
            WorldEvent(id: "q", sourceID: "usgs", title: "Earthquake", url: imageLink, date: now.addingTimeInterval(-hours * 3600),
                       timeKind: "发生", disaster: true, severity: nil, latitude: 20, longitude: 120, magnitude: magnitude)
        }
        assert(mapMarkers([earthquake(25, 7), earthquake(1, 5.8)], now: now).isEmpty)
        assert(mapMarkers([earthquake(1, 6.2)], now: now).first?.label == "M6.2")
        func gdacsEvent(_ type: String, ended: Double) -> WorldEvent {
            WorldEvent(id: type, sourceID: "gdacs", title: type, url: imageLink, date: now.addingTimeInterval(-10 * 86400),
                       timeKind: "发生", disaster: true, severity: "红色预警", latitude: 10, longitude: 20,
                       eventType: type, endDate: now.addingTimeInterval(ended))
        }
        assert(mapMarkers([gdacsEvent("DR", ended: 3600), gdacsEvent("FL", ended: -4 * 86400), gdacsEvent("TC", ended: 3600), gdacsEvent("EQ", ended: 3600)], now: now).isEmpty)
        assert(mapMarkers([gdacsEvent("VO", ended: 3600)], now: now).first?.symbol == "mountain.2.fill")
        let metadataXML = "<rss xmlns:gdacs=\"http://www.gdacs.org\"><channel><item><title>Volcano</title><link>https://example.org/v</link><gdacs:alertlevel>Red</gdacs:alertlevel><gdacs:eventtype>VO</gdacs:eventtype><gdacs:todate>2026-10-28T00:00:00</gdacs:todate></item></channel></rss>"
        let metadata = try parseFeed(Data(metadataXML.utf8), source: gdacs)[0]
        assert(metadata.eventType == "VO" && metadata.endDate == parseDate("2026-10-28T00:00:00Z"))
        assert(legacy.eventType == nil && legacy.endDate == nil)
        let cycloneJSON = Data(#"{"features":[{"properties":{"eventid":1,"name":"Tropical Cyclone ARNAB-26","alertlevel":"Red","todate":"2026-10-27T09:00:00","url":{"geometry":"https://www.gdacs.org/geometry"}}},{"properties":{"eventid":2,"name":"Tropical Cyclone OLD-26","alertlevel":"Orange","todate":"2026-10-25T00:00:00Z","url":{"geometry":"https://www.gdacs.org/geometry"}}}]}"#.utf8)
        let active = try parseCycloneEvents(cycloneJSON, now: now)
        assert(active.count == 1 && active[0].name == "ARNAB")
        func line(_ a: Int, _ forecast: Bool) -> [String: Any] {
            ["properties": ["Class": "Line_Line_\(a)", "forecast": forecast], "geometry": ["type": "LineString", "coordinates": [[Double(a), 10], [Double(a + 1), 10]]]]
        }
        let geometryJSON = try JSONSerialization.data(withJSONObject: ["features": (0..<100).reversed().map { line($0, $0 >= 70) } + [["properties": ["Class": "Poly_Red"], "geometry": ["type": "Polygon", "coordinates": []]]]])
        let track = try parseCycloneGeometry(geometryJSON, event: active[0])
        assert(track.history.first?.longitude == 0 && track.history.last?.longitude == 70)
        assert(track.forecast.first?.longitude == 70 && track.forecast.last?.longitude == 100)
        assert(track.history.count + track.forecast.count <= 60 && track.current?.longitude == 70)
        let realGeometry = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/cyclone-arnab.json"))
        let realTrack = try parseCycloneGeometry(realGeometry, event: active[0])
        assert(realTrack.history.count == 8 && realTrack.forecast.count == 5)
        assert(realTrack.history.first == MapCoordinate(longitude: 89.1, latitude: 16))
        assert(realTrack.current == MapCoordinate(longitude: 81.6, latitude: 16.4))
        assert(realTrack.forecast.last == MapCoordinate(longitude: 81.6, latitude: 21.9))
        assert(mapConflicts([headline("highest", "Airstrike hits Iran despite ceasefire", "bbc", 1)], now: now).first?.score == 3)
        let disasterHeadline = WorldEvent(id: "disaster-title", sourceID: "gdacs", title: "Iran airstrike killed", url: imageLink,
                                         date: now, timeKind: "发生", disaster: true, severity: "红色预警")
        assert(mapConflicts([disasterHeadline], now: now).isEmpty)
        assert(conflictWeight("Iran airstrike despite ceasefire") == 3)
        assert(conflictWeight("Iran 军事进攻与伤亡") == 3 && conflictWeight("warship awards") == 0)
        assert(conflictWeight("At least 64 killed in high-speed train collision in central Spain") == 0, "事故伤亡不算冲突")
        assert(conflictWeight("Gunmen attack village, 12 killed") == 3 && conflictWeight("Troops advance, dozens dead") == 3)
        assert((0...32).map(conflictLevel) == (0...32).map { score in score >= 30 ? 4 : score >= 16 ? 3 : score >= 8 ? 2 : score >= 3 ? 1 : 0 })
        assert(mapConflicts([headline("domestic", "中国导弹空袭", "cns-china", 1)], now: now).isEmpty)
        assert(mapConflicts([headline("48h", "Missiles hit Iran", "bbc", 48 * 3600 + 1)], now: now).isEmpty)
        assert(mapConflicts([headline("36h", "Missiles hit Iran", "bbc", 36 * 3600)], now: now).first?.score == 3)
        assert(conflictWeight("Russia strikes energy facilities in Kyiv") == 3)
        assert(conflictWeight("Workers strike as Russia discusses pay") == 0, "普通罢工不能误判为军事打击")
        let strikeCountries = mapConflicts([headline("kyiv-strike", "Russia strikes energy facilities in Kyiv", "bbc", 3600)], now: now)
        assert(strikeCountries.contains { $0.countryID == "UKR" } && !strikeCountries.contains { $0.countryID == "RUS" }, "袭击方不能被当成事发地")
        assert(conflictLocations("US says Russia strikes energy facilities in Kyiv") == ["UKR"], "发言方和攻击方不染色")
        assert(conflictLocations("Russian strikes plunge Ukrainian city into blackout") == ["UKR"])
        assert(conflictLocations("Yemenis in Aden prepare for another war as missiles fall") == ["YEM"], "亚丁的实际袭击应归入也门")
        assert(conflictLocations("Ukraine launches missile attacks on Russia") == ["RUS"], "按攻击目标而非固定国家名单判断")
        assert(conflictLocations("Ukraine launches missile strikes on Moscow") == ["RUS"])
        assert(conflictLocations("US troops killed in Iraq") == ["IRQ"])
        assert(conflictLocations("US officials condemn attacks in Gaza") == ["PSE"])
        assert(conflictLocations("Three killed in Russian missile attack on Kyiv") == ["UKR"], "俄军修饰词不是事发地")
        assert(conflictLocations("美军空袭伊朗首都德黑兰") == ["IRN"])
        assert(conflictLocations("俄罗斯导弹袭击乌克兰基辅") == ["UKR"])
        assert(conflictLocations("US announces sanctions on Iran").isEmpty)
        assert(conflictLocations("Qatari officials in Iran in bid to revive ceasefire deal with US").isEmpty)
        assert(conflictLocations("Ukraine suspends attacks on Russia").isEmpty)
        assert(conflictLocations("特朗普施压下，乌克兰已暂停袭击俄罗斯炼油厂").isEmpty)
        assert(conflictLocations("美伊战争推升油价 美国石油巨擘获利攀升").isEmpty)
        let legacySignal = ConflictSignal(id: "old", sourceID: "bbc", date: now, weight: 3, countries: ["USA"])
        assert(mapConflicts(signals: [legacySignal], now: now).isEmpty, "旧版按提及国家评分的数据不能继续误染")
        print("PASS: 冲突按事发地与受袭目标归属，排除发言方、攻击方及经济连带报道")
        let olderConflict = headline("old-conflict", "Missile attack hits Iran", "bbc", 12 * 3600)
        let newerFillers = (0..<120).map { headline("filler-\($0)", "Ordinary update \($0)", "guardian", Double($0)) }
        let boundedSnapshot = refreshedSnapshot(previous: nil, results: [.init(id: "bbc", events: [olderConflict]), .init(id: "guardian", events: newerFillers)], now: now, enabledIDs: ["bbc", "guardian"])
        assert(boundedSnapshot.sourceFeeds?.values.reduce(0, { $0 + $1.events.count }) == 100)
        assert(!boundedSnapshot.sourceFeeds!.values.flatMap(\.events).contains { $0.id == olderConflict.id })
        assert(mapConflicts(signals: boundedSnapshot.conflictSignals ?? [], now: now).contains { $0.countryID == "IRN" }, "新闻数量上限不应挤掉冲突信号")
        let offlineSnapshot = refreshedSnapshot(previous: boundedSnapshot, results: [.init(id: "bbc", events: nil)], now: now.addingTimeInterval(60), enabledIDs: ["bbc", "guardian"])
        assert(mapConflicts(signals: offlineSnapshot.conflictSignals ?? [], now: now.addingTimeInterval(60)).contains { $0.countryID == "IRN" }, "来源失败时保留未过期信号")
        assert(mergedConflictSignals(boundedSnapshot.conflictSignals ?? [], [], enabledIDs: ["guardian"], now: now).isEmpty, "停止抓取的来源不再贡献信号")
        assert(mapConflicts(signals: boundedSnapshot.conflictSignals ?? [], now: now.addingTimeInterval(37 * 3600)).isEmpty, "冲突信号在 48 小时后过期")
        assert(widgetTimeline(boundedSnapshot, now: now)[0].conflictSignals == nil, "新闻时间线不能重复携带信号")
        let signalJSON = try JSONEncoder().encode(boundedSnapshot)
        let decodedSignals = try JSONDecoder().decode(NewsSnapshot.self, from: signalJSON)
        assert(decodedSignals.conflictSignals == boundedSnapshot.conflictSignals)
        print("PASS: 100 条新闻上限下仍保留轻量冲突信号、来源关闭和 48 小时过期，时间线不重复携带")
        assert(mapConflicts([headline("irish", "Ireland military airstrikes", "bbc", 1)], now: now).allSatisfy { $0.countryID != "IRN" })
        let many = WorldMap.ranked.prefix(25).enumerated().map { headline("conflict\($0.offset)", "Airstrikes hit " + $0.element.name, "bbc", 1) }
        assert(mapConflicts(many, now: now).count == 15)
        assert(cityTime(newYork, at: parseDate("2026-11-01T05:30:00Z")!) == "01:30")
        assert(cityTime(newYork, at: parseDate("2026-11-01T06:30:00Z")!) == "01:30")
        assert(cityTime(newYork, at: parseDate("2026-11-01T07:30:00Z")!) == "02:30")
        let tokyo = CameraCity.all.first { $0.id == "tokyo" }!
        assert(cityTime(tokyo, at: parseDate("2026-11-01T05:30:00Z")!) == "14:30")
        let meteo = Data(#"[{"current":{"temperature_2m":8.3,"time":"2026-10-27T12:00"}},{"current":{"temperature_2m":18.6,"time":"2026-10-27T12:00"}}]"#.utf8)
        let weather = try parseCityWeather(meteo, cities: [newYork, tokyo])
        assert(weather.count == 2 && weather[0].temperature == 8.3 && weather[1].cityID == "tokyo")
        assert(cityConditions(newYork, at: now, weather: weather).hasSuffix("8°"))
        assert(!cityConditions(newYork, at: now.addingTimeInterval(3 * 3600 + 1), weather: weather).contains("°"))
        let orbit = [ISSPoint(date: now, coordinate: .init(longitude: 179, latitude: 0)), ISSPoint(date: now.addingTimeInterval(300), coordinate: .init(longitude: -179, latitude: 10))]
        let midpoint = issPosition(orbit, at: now.addingTimeInterval(150))!
        assert(abs(midpoint.longitude) == 180 && midpoint.latitude == 5)
        assert(issPosition(orbit, at: now.addingTimeInterval(301)) == nil)
        assert(mapSegments(orbit.map(\.coordinate)).count == 2)
        assert(issPosition(orbit, at: now) != issPosition(orbit, at: now.addingTimeInterval(180)))
        assert(!recentISSTrack(orbit, at: now.addingTimeInterval(301)).isEmpty, "位置超出覆盖时间时仍可查看最近轨道")
        assert(recentISSTrack(orbit, at: now.addingTimeInterval(2101)).isEmpty, "过期轨道不长期显示")
        let completeOrbit = [ISSPoint(date: now.addingTimeInterval(-2700), coordinate: .init(longitude: 0, latitude: 10)), ISSPoint(date: now.addingTimeInterval(2700), coordinate: .init(longitude: 30, latitude: 30))]
        let freshOrbit = MapLayerCache(checkedAt: now.addingTimeInterval(-60), fetchedAt: now.addingTimeInterval(-60), value: completeOrbit)
        assert(!issRefreshNeeded(freshOrbit, at: now, minimumAge: 3600))
        assert(issRefreshNeeded(freshOrbit, at: now.addingTimeInterval(901), minimumAge: 3600), "组件不能等待一小时才补充空间站轨道")
        let recentFailure = MapLayerCache(checkedAt: now.addingTimeInterval(-100), fetchedAt: now.addingTimeInterval(-3600), value: orbit)
        let oldFailure = MapLayerCache(checkedAt: now.addingTimeInterval(-301), fetchedAt: now.addingTimeInterval(-3600), value: orbit)
        assert(!issRefreshNeeded(recentFailure, at: now, minimumAge: 1800), "失败后保留五分钟退避")
        assert(issRefreshNeeded(oldFailure, at: now, minimumAge: 1800), "失败后五分钟可重试")
        assert(issRefreshNeeded(nil, at: now, minimumAge: 1800))
        print("PASS: Africa 标签、最近空间站轨道、覆盖期补刷及五分钟失败重试")
        let stationJSON = Data(#"[{"latitude":10,"longitude":20,"timestamp":1000},{"latitude":20,"longitude":30,"timestamp":1300}]"#.utf8)
        let stationPoints = try parseISS(stationJSON)
        assert(stationPoints.count == 2)
        let preferences = UserDefaults(suiteName: "WorldWatchTests-" + UUID().uuidString)!
        preferences.set(false, forKey: "mapHotspots")
        assert(!WorldPreferences.enabled("mapConflicts", in: preferences))
        preferences.set(true, forKey: "mapConflicts")
        assert(WorldPreferences.enabled("mapConflicts", in: preferences))
        preferences.removeObject(forKey: "mapConflicts"); preferences.removeObject(forKey: "mapHotspots")
        var crowded: [MapLabel] = []
        let tiny = MapProjection(bounds: MapRegion.world.bounds, size: CGSize(width: 160, height: 80))
        placeMapLabel([String(repeating: "Long city ", count: 10), "03:12 · 8°"], id: "city", at: CGPoint(x: 80, y: 40), projection: tiny, labels: &crowded)
        assert(crowded.first?.text == "03:12 · 8°")
        let combined = mapLabels(projection: tiny, reserved: crowded)
        for a in combined.indices { for b in combined.indices where a < b { assert(!combined[a].rect.intersects(combined[b].rect)) } }
        let layerStore = MapLayerStore(root: temporary.appendingPathComponent("MapLayers"))
        let ucdpHeader = "id,active_year,code_status,type_of_violence,country,adm_1,best,date_start,date_end,note\r\n"
        let ucdpRows = """
        1,true,Clear,1,Ukraine,Kyiv,1000,2026-09-01,2026-09-02,"comma, quote ""test""
        second line"
        2,true,Clear,1,Russia (Soviet Union),Belgorod,30,2026-09-03,2026-09-03,local
        3,true,Clear,3,Israel,Gaza Strip,25,2026-09-04,2026-09-04,location
        4,false,Clear,1,United States of America,,2000,2026-09-04,2026-09-04,inactive
        5,true,Check deaths,1,United States of America,,2000,2026-09-04,2026-09-04,provisional
        6,true,Clear,1,United States of America,,2000,2026-08-01,2026-09-04,cross-month
        7,true,Clear,1,United States of America,,2000,2026-09-01,2026-10-01,cross-month
        8,true,Clear,1,United States of America,,0,2026-09-01,2026-09-01,zero
        2,true,Clear,1,Russia (Soviet Union),Belgorod,30,2026-09-03,2026-09-03,duplicate
        """
        let ucdpData = Data(([0xEF, 0xBB, 0xBF] as [UInt8]) + Array((ucdpHeader + ucdpRows).utf8))
        let ongoing = try parseOngoingConflictCSV(ucdpData, version: "26.0.9", now: now)
        assert(ongoing.countries.map(\.countryID) == ["UKR", "RUS", "PSE"])
        assert(ongoing.countries.map(\.level) == [4, 2, 2] && ongoing.countries.allSatisfy { $0.events == 1 })
        assert(ongoing.monthLabel == "2026年9月" && ongoing.periodEnd == parseDate("2026-10-01T00:00:00Z"))
        let decodedOngoing = try JSONDecoder().decode(OngoingConflictSnapshot.self, from: JSONEncoder().encode(ongoing))
        assert(decodedOngoing == ongoing)
        let indexData = Data("GEDEvent_v26_0_8.csv GEDEvent_v26_0_9.csv GEDEvent_v26_0_10.csv GEDEvent_v26_0_13.csv".utf8)
        let selectedVersion = try latestOngoingConflictVersion(indexData, now: now)
        assert(selectedVersion == "26.0.9", "忽略尚未结束的月份")
        for bad in ["26.foo.0.9", "26..9", "26.0.13", "26.0.10"] {
            do { _ = try parseOngoingConflictCSV(ucdpData, version: bad, now: now); fatalError("应拒绝无效或未完成的月份") } catch {}
        }
        for bad in [ucdpHeader + "1,true,Clear", ucdpHeader + "\"unterminated", "<html>Unavailable</html>"] {
            do { _ = try parseOngoingConflictCSV(Data(bad.utf8), version: "26.0.9", now: now); fatalError("应拒绝损坏数据") } catch {}
        }
        assert(ongoingCountryID("Central African Republic", administration: "") == "CAF")
        assert(ongoingCountryID("Myanmar (Burma)", administration: "") == "MMR")
        let sustained = mapConflicts(signals: [], ongoing: ongoing, now: now)
        assert(sustained.map(\.countryID) == ["UKR", "RUS", "PSE"], "没有新报道时，持续冲突仍显色")
        assert(!mapConflicts(signals: [], ongoing: ongoing, now: now.addingTimeInterval(86400)).isEmpty)
        assert(mapConflicts(signals: [], ongoing: ongoing, now: ongoing.periodEnd.addingTimeInterval(121 * 86400)).isEmpty)
        assert(mapConflicts(signals: [], ongoing: ongoing, now: ongoing.periodEnd.addingTimeInterval(-1)).isEmpty)
        let blended = mapConflicts(signals: conflictSignals([headline("iran-current", "Missiles hit Iran", "bbc", 1)], now: now), ongoing: ongoing, now: now)
        assert(blended.contains { $0.countryID == "IRN" && $0.level == 1 } && blended.contains { $0.countryID == "RUS" })
        let seed = OngoingConflictSnapshot.initial
        assert(seed.version == "26.0.9" && seed.countries.count == 29 && !seed.countries.contains { $0.countryID == "USA" })
        let seedMap = mapConflicts(signals: [], ongoing: seed, now: now)
        assert(seedMap.count == 15 && seedMap.contains { $0.countryID == "RUS" } && seedMap.contains { $0.countryID == "UKR" })
        assert(layerStore.ongoing() == seed, "无网络缓存时使用经过核对的离线月度汇总")
        try layerStore.write(.init(checkedAt: now, fetchedAt: now, value: ongoing), name: "ongoing-conflicts")
        try layerStore.write(.init(checkedAt: now.addingTimeInterval(-1), fetchedAt: now, value: seed), name: "ongoing-conflicts")
        assert(layerStore.ongoing() == ongoing, "旧请求不能覆盖新缓存")
        print("PASS: UCDP 月份选择、CSV 引号/换行/BOM/去重、有效记录与发生地、俄乌离线基线、新闻叠加、120 天过期及 15 国上限")
        try layerStore.write(.init(checkedAt: now, fetchedAt: now.addingTimeInterval(-86401), value: [track]), name: "cyclones")
        assert(layerStore.cyclones(at: now).isEmpty)
        try FileManager.default.removeItem(at: temporary)
        let forecastSample = MapCyclone(id: 1, name: "TEST", red: true, end: now,
            history: [.init(longitude: 84, latitude: 16), .init(longitude: 83, latitude: 16), .init(longitude: 82, latitude: 16)],
            forecast: [.init(longitude: 82, latitude: 16), .init(longitude: 82, latitude: 17), .init(longitude: 82, latitude: 20)])
        let twelve = cycloneForecast(forecastSample)
        assert(twelve.count == 3 && abs(twelve[2].latitude - 17.9) < 0.15, "未来 12 小时约为两倍历史 6 小时步长")
        assert(cycloneForecast(MapCyclone(id: 2, name: "X", red: false, end: now, history: [], forecast: [])).isEmpty)
        print("PASS: 2.7 地震时限与震级标签、GDACS类型和结束时间、台风过滤/名称/乱序历史预测/60点上限、冲突评分/48小时/四级/15国/词边界、夏令时、天气数组及过期、ISS插值及经线断线、偏好迁移与过期缓存")
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
