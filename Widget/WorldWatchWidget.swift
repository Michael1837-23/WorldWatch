import SwiftUI
import WidgetKit
import AppIntents

extension NewsSnapshot: TimelineEntry {}
typealias WorldWatchEntry = NewsSnapshot

struct WorldWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorldWatchEntry {
        WorldWatchEntry(date: Date(), events: [], availableSources: 0, note: "全球新闻与灾害动态")
    }
    func getSnapshot(in context: Context, completion: @escaping (WorldWatchEntry) -> Void) {
        var snapshot = cached() ?? placeholder(in: context)
        snapshot.displayMode = NewsDisplayMode.selected
        completion(widgetTimeline(snapshot, pageSize: pageSize(context.family)).first ?? snapshot)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WorldWatchEntry>) -> Void) {
        Task {
            var entry = await load()
            entry.displayMode = NewsDisplayMode.selected
            let delay: TimeInterval = entry.availableSources == 0 ? 5 * 60 : 15 * 60
            completion(Timeline(entries: widgetTimeline(entry, pageSize: pageSize(context.family)), policy: .after(Date().addingTimeInterval(delay))))
        }
    }
    /// Candidates per entry. The view shows as many as fit, so latest mode sends a few spares;
    /// rotation pages stay close to what is usually visible so few stories are skipped.
    func pageSize(_ family: WidgetFamily) -> Int {
        let rotation = NewsDisplayMode.selected == .rotation
        switch family {
        case .systemSmall: return rotation ? 2 : 3
        case .systemMedium: return rotation ? 3 : 5
        default: return rotation ? 6 : 9
        }
    }
    func cached() -> WorldWatchEntry? {
        if let shared = NewsSnapshotStore.shared.read() { return shared }
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldWatch/widget-snapshot.json")
        guard let data = try? Data(contentsOf: legacy) else { return nil }
        return try? JSONDecoder().decode(WorldWatchEntry.self, from: data)
    }
    func load(force: Bool = false) async -> WorldWatchEntry {
        let previous = cached()
        // App Intent completion reloads the timeline. Reuse its just-fetched result once.
        if !force, let previous, Date().timeIntervalSince(previous.checkDate) < 120 {
            NSLog("组件复用最新摘要：checked=%.0f", previous.date.timeIntervalSince1970)
            var latest = previous
            latest.displayMode = NewsDisplayMode.selected
            return latest
        }
        let enabledIDs = previous?.enabledSourceIDs ?? NewsSource.all.map(\.id)
        var results: [SourceFetchResult] = []
        await withTaskGroup(of: SourceFetchResult.self) { group in
            for source in NewsSource.all where enabledIDs.contains(source.id) {
                group.addTask { SourceFetchResult(id: source.id, events: try? await fetchSource(source, timeout: 10)) }
            }
            for await result in group {
                results.append(result)
            }
        }
        let previousEvents = previous?.sourceFeeds?.values.flatMap(\.events) ?? previous?.rotationEvents ?? previous?.events ?? []
        let known = Dictionary(previousEvents.compactMap { event in event.translatedTitle.map { (event.title, $0) } }, uniquingKeysWith: { first, _ in first })
        results = results.map { result in
            SourceFetchResult(id: result.id, events: result.events?.map { event in
                var item = event; item.translatedTitle = known[event.title]; return item
            })
        }
        var entry = refreshedSnapshot(previous: previous, results: results, enabledIDs: enabledIDs, mode: NewsDisplayMode.selected)
        var pool = await TitleTranslator.shared.applyCache(to: entry.rotationEvents ?? entry.events)
        let current = entry.mode == .latest ? Array(pool.prefix(9)) : rotationEvents(pool, at: Date(), limit: 6).events
        var translatedPage = current
        do { translatedPage = try await TitleTranslator.shared.translate(current) }
        catch {
            translatedPage = await TitleTranslator.shared.applyCache(to: current)
            entry.note = "部分标题待翻译"
        }
        let translated = Dictionary(translatedPage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pool = pool.map { translated[$0.id] ?? $0 }
        entry.rotationEvents = pool
        entry.events = Array(pool.prefix(4))
        let byTitle = Dictionary(pool.compactMap { event in event.translatedTitle.map { (event.title, $0) } }, uniquingKeysWith: { first, _ in first })
        if var feeds = entry.sourceFeeds {
            for id in Array(feeds.keys) {
                if var feed = feeds[id] {
                    feed.events = feed.events.map { event in var item = event; item.translatedTitle = byTitle[event.title] ?? event.translatedTitle; return item }
                    feeds[id] = feed
                }
            }
            entry.sourceFeeds = feeds
            await TitleTranslator.shared.prune(keeping: Set(feeds.values.flatMap { $0.events.map(\.title) }))
        }
        do { try NewsSnapshotStore.shared.write(entry) }
        catch { NSLog("小组件缓存保存失败：%@", error.localizedDescription) }
        NSLog("组件联网检查完成：checked=%.0f sources=%ld", entry.date.timeIntervalSince1970, entry.availableSources)
        return NewsSnapshotStore.shared.read() ?? entry
    }
}

struct RefreshWorldNewsIntent: AppIntent {
    static var title: LocalizedStringResource = "立即刷新世界动态"
    static var description = IntentDescription("重新检查新闻来源并更新中文摘要。")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        NSLog("用户请求组件立即刷新")
        _ = await WorldWatchProvider().load(force: true)
        // WidgetKit reloads the timeline after this user interaction completes.
        return .result()
    }
}

/// Stacks rows top to bottom and fills the height: whole rows first, then one truncated row
/// if a useful part of it fits, otherwise the leftover space is shared between rows.
/// Rows that do not fit are parked just below the clipped bounds.
struct FillingStack: Layout {
    var spacing: CGFloat
    var maxExtraSpacing: CGFloat = 14
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var heights: [CGFloat] = []
        var used: CGFloat = 0
        for subview in subviews {
            let gap = heights.isEmpty ? 0 : spacing
            let remaining = bounds.height - used - gap
            let natural = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            if natural <= remaining { heights.append(natural); used += gap + natural; continue }
            let minimum = max(30, subview.sizeThatFits(ProposedViewSize(width: width, height: 0)).height)
            if heights.isEmpty || minimum <= remaining {
                let height = max(0, min(natural, remaining))
                heights.append(height); used += gap + height
            }
            break
        }
        let extra = heights.count > 1 ? min(maxExtraSpacing, max(0, bounds.height - used) / CGFloat(heights.count - 1)) : 0
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index < heights.count {
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: width, height: heights[index]))
                y += heights[index] + spacing + extra
            } else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.maxY + spacing), proposal: ProposedViewSize(width: width, height: nil))
            }
        }
    }
}

struct WidgetRow: View {
    let event: WorldEvent
    let family: WidgetFamily
    var body: some View {
        Link(destination: event.url) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.sourceName).fontWeight(.semibold)
                    if let severity = event.severity {
                        Text(severity).foregroundStyle(severity == "红色预警" ? Color.red : Color.orange)
                    }
                    Spacer(minLength: 4)
                    if let date = event.date { Text(shortTimeLabel(date)).monospacedDigit() }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Text(event.displayTitle)
                    .font(.system(size: family == .systemMedium ? 13 : 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(family == .systemSmall ? 5 : family == .systemMedium ? 2 : 3)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WorldWatchWidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: WorldWatchEntry
    var body: some View {
        Group {
            if entry.events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "globe.asia.australia").font(.title2)
                    Text(entry.note ?? "暂无新报道").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FillingStack(spacing: family == .systemLarge ? 9 : 7) {
                    ForEach(entry.events) { event in
                        WidgetRow(event: event, family: family)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.92), value: entry.events.map(\.id))
                .clipped()
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "worldwatch://open"))
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

struct WorldWatchWidget: Widget {
    let kind = "WorldWatchNews"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorldWatchProvider()) { entry in WorldWatchWidgetView(entry: entry) }
            .configurationDisplayName("世界动态")
            .description("国内外政治、财经、科技、文娱、体育与灾害。可在应用中选择最新优先或综合轮播，更新时间由 macOS 调度。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WorldComponentEntry: TimelineEntry {
    let date: Date
    let events: [WorldEvent]
    let markers: [MapMarker]
    let hotspots: [MapHotspot]
    let sun: MapCoordinate
    let settings: MapSettings
    let cities: [CameraCity]
    let frames: [String: [CameraFrame]]
    let index: Int
}

struct WorldComponentProvider: TimelineProvider {
    var cameras = true
    var news = true
    func placeholder(in context: Context) -> WorldComponentEntry { entries(snapshot: nil, minutes: 1)[0] }
    func getSnapshot(in context: Context, completion: @escaping (WorldComponentEntry) -> Void) {
        completion(entries(snapshot: NewsSnapshotStore.shared.read(), minutes: 1)[0])
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WorldComponentEntry>) -> Void) {
        Task {
            let snapshot = NewsSnapshotStore.shared.read()
            let stale = CameraCity.selected.filter { city in
                CameraSnapshotStore.shared.read(city.id)?.fetchedAt.map { Date().timeIntervalSince($0) >= CameraCity.interval * 2 } ?? true
            }
            async let refreshed = refreshNews(snapshot)
            if cameras && !stale.isEmpty { _ = await CameraService.shared.refresh(cities: stale, limit: 1, budget: 20) }
            let latest = await refreshed
            let timeline = entries(snapshot: latest)
            let kind = news ? (cameras ? "WorldWatchDashboard" : "WorldWatchMap") : "WorldWatchLive"
            NSLog("新组件时间线：%@ family=%@ entries=%ld", kind, String(describing: context.family), timeline.count)
            completion(Timeline(entries: timeline, policy: .after(Date().addingTimeInterval(900))))
        }
    }
    private func refreshNews(_ snapshot: NewsSnapshot?) async -> NewsSnapshot? {
        if !news { return snapshot }
        if let snapshot, Date().timeIntervalSince(snapshot.checkDate) < 900 { return snapshot }
        return await WorldWatchProvider().load()
    }
    /// WidgetKit rejects timeline archives that are too large (each entry archives its images and map),
    /// so entries are spaced three minutes apart: ten entries cover the 30-minute refresh window.
    static let entrySpacing: TimeInterval = 180
    func entries(snapshot: NewsSnapshot?, now: Date = Date(), minutes: Int = 30) -> [WorldComponentEntry] {
        let all = snapshot?.sourceFeeds?.values.flatMap(\.events) ?? snapshot?.rotationEvents ?? snapshot?.events ?? []
        let retained = mergedEvents(all, now: now)
        let markers = mapMarkers(retained), hotspots = mapHotspots(retained, now: now)
        let mode = NewsDisplayMode.selected, pool = displayPool(retained, mode: mode, now: now)
        let cities = CameraCity.selected, settings = MapSettings()
        let frames = Dictionary(uniqueKeysWithValues: cities.map { ($0.id, CameraSnapshotStore.shared.read($0.id)?.frames.filter(CameraOptions.allows) ?? []) })
        let spacing = Self.entrySpacing, slot = floor(now.timeIntervalSince1970 / spacing) * spacing
        return (0..<max(1, Int(Double(minutes * 60) / spacing))).map { index in
            let date = index == 0 ? now : Date(timeIntervalSince1970: slot + Double(index) * spacing)
            let news = mode == .latest ? Array(pool.prefix(12)) : rotationEvents(pool, at: date, limit: 10).events
            return WorldComponentEntry(date: date, events: news, markers: markers, hotspots: hotspots, sun: solarPosition(at: date),
                                       settings: settings, cities: cities, frames: frames, index: Int(date.timeIntervalSince1970 / spacing))
        }
    }
}

struct WorldComponentView: View {
    @Environment(\.widgetFamily) var family
    let entry: WorldComponentEntry
    let kind: String
    var cameraStore = CameraSnapshotStore.shared
    // Only the dashboard shows the camera tiles, so only it pins their cities on the map.
    var map: some View {
        WorldMapCanvas(markers: entry.markers, hotspots: entry.hotspots, sun: entry.sun, settings: entry.settings,
                       cameras: kind == "WorldWatchDashboard" ? entry.cities : [])
    }
    var body: some View {
        Group {
            if kind == "WorldWatchMap" { map }
            else if kind == "WorldWatchLive" {
                CameraGrid(cities: entry.cities, frames: entry.frames, index: entry.index, rows: family == .systemMedium ? 1 : 2, maxPixel: 360, store: cameraStore)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 16) {
                        VStack(spacing: 8) {
                            map.frame(height: max(50, (geometry.size.height - 8) * 0.5))
                            CameraGrid(cities: entry.cities, frames: entry.frames, index: entry.index, maxPixel: 360, store: cameraStore)
                        }
                        .frame(width: max(0, (geometry.size.width - 16) * 0.52))
                        FillingStack(spacing: 9) {
                            ForEach(entry.events) { event in WidgetRow(event: event, family: .systemLarge) }
                        }
                        .clipped()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "worldwatch://open"))
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

struct WorldDashboardWidget: Widget {
    let kind = "WorldWatchDashboard"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorldComponentProvider()) { WorldComponentView(entry: $0, kind: kind) }
            .configurationDisplayName("世界总览")
            .description("世界地图、四座城市实景截图与新闻。新闻热点按提及量估计，非核实的冲突数据。")
            .supportedFamilies([.systemExtraLarge])
    }
}

struct WorldMapWidget: Widget {
    let kind = "WorldWatchMap"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorldComponentProvider(cameras: false)) { WorldComponentView(entry: $0, kind: kind) }
            .configurationDisplayName("世界地图")
            .description("国家、地震、灾害与昼夜。新闻热点按提及量估计，非核实的冲突数据。")
            .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

struct WorldLiveWidget: Widget {
    let kind = "WorldWatchLive"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorldComponentProvider(news: false)) { WorldComponentView(entry: $0, kind: kind) }
            .configurationDisplayName("世界实景")
            .description("城市摄像头的定时截图轮播。城市与顺序在应用设置中调整。")
            .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main struct WorldWatchWidgets: WidgetBundle {
    init() {
        NSLog("世界动态组件目录 2.6/14：WorldWatchNews、WorldWatchDashboard、WorldWatchMap、WorldWatchLive")
    }
    var body: some Widget {
        WorldWatchWidget()
        WorldDashboardWidget()
        WorldMapWidget()
        WorldLiveWidget()
    }
}
