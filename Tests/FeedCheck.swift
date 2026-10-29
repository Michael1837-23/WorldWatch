import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct FeedCheck {
    static func main() async throws {
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
        let locatedQuake = Data(#"{"features":[{"id":"point","properties":{"title":"M 6.8","mag":6.8,"time":1792886400000,"url":"https://example.org/q"},"geometry":{"coordinates":[121.5,23.4,10]}}]}"#.utf8)
        let located = try parseFeed(locatedQuake, source: NewsSource.all.first { $0.id == "usgs" }!)[0]
        assert(located.longitude == 121.5 && located.latitude == 23.4 && located.magnitude == 6.8)
        let pointXML = #"<rss xmlns:geo="http://www.w3.org/2003/01/geo/wgs84_pos#" xmlns:gdacs="http://www.gdacs.org"><channel><item><title>Red flood</title><link>https://example.org/flood</link><gdacs:alertlevel>Red</gdacs:alertlevel><geo:Point><geo:lat>25.1</geo:lat><geo:long>120.2</geo:long></geo:Point></item></channel></rss>"#
        let flood = try parseFeed(Data(pointXML.utf8), source: gdacs)[0]
        assert(flood.latitude == 25.1 && flood.longitude == 120.2 && legacy.latitude == nil && legacy.longitude == nil)
        assert(mapMarkers([located, flood]).count == 2)
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
        assert(abs(solarPosition(at: parseDate("2026-06-21T12:00:00Z")!).latitude - 23.4) < 1)
        assert(abs(solarPosition(at: parseDate("2026-12-21T12:00:00Z")!).latitude + 23.4) < 1)
        let sun = solarPosition(at: now)
        assert(!isNight(sun, sun: sun))
        assert(isNight(.init(longitude: sun.longitude + 180, latitude: -sun.latitude), sun: sun))
        let hits = mapHotspots([headline("israel-en", "Israel ceasefire", "bbc", 1), headline("israel-zh", "以色列停火", "cns-world", 2), headline("ireland", "Ireland opens a museum", "bbc", 3)], now: now)
        assert(hits.first { $0.countryID == "ISR" }?.count == 4)
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
        assert(mapHotspots([headline("china-en", "China announces export rules", "bbc", 1)], now: now).first?.countryID == "CHN", "英文 China 计入中国")
        assert(mapHotspots([headline("china-domestic", "中国发布新规", "cns-china", 1)], now: now).isEmpty, "国内来源不计入热点")
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
        assert(rankedCameraSources([sky, yt1], health: rankingHealth, now: now.addingTimeInterval(1000)).first?.id == yt1.id)
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
        coverHealth.observe(fingerprint, modified: nil, now: Date().addingTimeInterval(-900))
        coverHealth.observe(fingerprint, modified: nil, now: Date().addingTimeInterval(-600))
        try fallbackStore.writeState([cover.id: coverHealth], name: "health.json")
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
        print("PASS: dHash 与微小像素变化、封面状态机、封面 ETag 与 CDN 缓存不误判、四分钟比较间隔、失败退避、过期/纯色/小图、平台分散、当轮失败及封面顺延、来源持久化、Skyline/频道解析与旧 manifest")

        try FileManager.default.removeItem(at: temporary)
        print("PASS: 地震/GDACS坐标、旧缓存兼容、RSS 1.0/Atom、多国地图、投影四角、确定且无重叠的标签、昼夜与新闻热点边界")
        print("PASS: 直播ID去重与城市过滤、B站开播状态和HTTPS、B站房间号与街景标题过滤、国家短名与国内来源排除、无效图片拒绝、四城错位轮换、截图缓存旧请求保护")
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
