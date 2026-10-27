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
    func pageSize(_ family: WidgetFamily) -> Int { family == .systemSmall ? 1 : family == .systemMedium ? 2 : 4 }
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
        let current = entry.mode == .latest ? Array(pool.prefix(4)) : rotationEvents(pool, at: Date()).events
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

struct WorldWatchWidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: WorldWatchEntry
    var rowLimit: Int { family == .systemSmall ? 1 : family == .systemMedium ? 2 : 4 }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 4 : 6) {
            HStack(spacing: 6) {
                Image(systemName: "globe.asia.australia.fill").widgetAccentable()
                Text("世界动态").fontWeight(.semibold)
                Spacer(minLength: 0)
                if family != .systemSmall { Text(entry.mode.title).foregroundStyle(.secondary).font(.caption2) }
                Button(intent: RefreshWorldNewsIntent()) {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("立即刷新世界动态")
                    .accessibilityHint("检查来源需要数秒；没有新报道时标题保持不变")
            }.font(.system(size: 13))
            if entry.events.isEmpty {
                Text(entry.note ?? "暂无重点事件").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: family == .systemMedium ? 4 : 6) {
                ForEach(Array(entry.events.prefix(rowLimit))) { event in
                    VStack(alignment: .leading, spacing: 6) {
                    Link(destination: event.url) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.displayTitle).font(.system(size: family == .systemLarge ? 14 : family == .systemMedium ? 12 : 13, weight: .medium))
                                .lineLimit(family == .systemSmall ? 4 : 2).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.opacity)
                            HStack(spacing: 5) {
                                if let date = event.date { Text(date, format: .dateTime.hour().minute()) }
                                Text(event.category.rawValue)
                                Text(NewsSource.all.first { $0.id == event.sourceID }?.name ?? event.sourceID).lineLimit(1)
                                if event.translatedTitle != nil { Text("机译") }
                                if let cached = entry.sourceFeeds?[event.sourceID], cached.fetchedAt < entry.checkDate.addingTimeInterval(-1) { Text("缓存") }
                            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if family != .systemSmall && event.id != entry.events.prefix(rowLimit).last?.id { Divider() }
                    }.transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
                }.animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.92), value: Array(entry.events.prefix(rowLimit).map(\.id)))
                    .clipped()
                Spacer(minLength: 0)
            }
            HStack(spacing: 3) {
                if entry.note != nil { Image(systemName: "exclamationmark.circle") }
                Text(statusCaption)
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(family == .systemSmall ? 2 : 1)
                .invalidatableContent()
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "worldwatch://open"))
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
    var statusCaption: String {
        let checked = entry.checkDate.formatted(.dateTime.hour().minute().second())
        if entry.enabledSourceIDs?.isEmpty == true { return "未启用来源 · 请在应用中设置" }
        if entry.availableSources == 0 { return "\(checked) 检查失败 · 保留缓存" }
        if entry.mode == .latest { return "\(entry.availableSources)/\(entry.enabledSourceIDs?.count ?? NewsSource.all.count)源 · \(checked)检查 · 最新优先" }
        let page = entry.rotationPage ?? 1
        let pages = entry.rotationPageCount ?? 1
        return "\(entry.availableSources)/\(entry.enabledSourceIDs?.count ?? NewsSource.all.count)源 · \(checked)检查 · 轮播\(page)/\(pages)"

    }
}

@main struct WorldWatchWidget: Widget {
    let kind = "WorldWatchNews"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorldWatchProvider()) { entry in WorldWatchWidgetView(entry: entry) }
            .configurationDisplayName("世界动态")
            .description("国内外政治、财经、科技、文娱、体育与灾害。可在应用中选择最新优先或综合轮播，更新时间由 macOS 调度。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
