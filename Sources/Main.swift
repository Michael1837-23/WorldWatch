import Cocoa
import Combine
import SwiftUI
import Translation
import WidgetKit

struct CachedFeed: Codable {
    var events: [WorldEvent]
    var fetched: Date
}

@MainActor final class EventStore: ObservableObject {
    @Published var feeds: [String: CachedFeed] = [:]
    @Published var errors: [String: String] = [:]
    @Published var refreshing = false
    @Published var filter = "最新"
    @Published var widgetDisplayMode = NewsDisplayMode.selected
    @Published var newsFilter = NewsFilter.selected
    @Published var rotationDate = Date()
    @Published var showSources = false
    @Published var cameraCities = CameraCity.selected.map(\.id)
    @Published var cameraInterval = CameraCity.interval
    @Published var cameraManifests: [String: CameraManifest] = [:]
    @Published var cameraRefreshing = false
    @Published var cameraSources: [String: [CameraSource]] = [:]
    @Published var cameraHealth: [String: CameraHealth] = [:]
    @Published var disabledCameras = CameraOptions.disabled
    @Published var skylineCameras = CameraOptions.skyline
    @Published var lastCheck: Date?
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published var translationStatus = "正在检查中英翻译语言…"
    @Published var translating = false
    @Published var disabled: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "disabledSources") ?? [])
    @Published var interval: Double = UserDefaults.standard.double(forKey: "refreshInterval") == 0 ? 60 : UserDefaults.standard.double(forKey: "refreshInterval")
    var enabledSources: [NewsSource] { NewsSource.all.filter { !disabled.contains($0.id) } }
    var events: [WorldEvent] { mergedEvents(enabledSources.flatMap { feeds[$0.id]?.events ?? [] }) }
    var healthyCount: Int { enabledSources.filter { errors[$0.id] == nil && feeds[$0.id] != nil }.count }
    private var loop: Task<Void, Never>?
    private var cameraLoop: Task<Void, Never>?
    private var mapLoop: Task<Void, Never>?
    private var widgetReloadTask: Task<Void, Never>?
    private var widgetReloadAt: Date?
    private var incrementalSnapshotTask: Task<Void, Never>?
    private var lastWidgetReload = Date.distantPast
    private var requestedWidgetSnapshot: NewsSnapshot?
    private var observedConflicts: [ConflictSignal] = []
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldWatch/feeds.json")
    init() {
        filter = widgetDisplayMode == .latest ? "最新" : "综合"
        if newsFilter.eventOnly == nil {
            newsFilter.eventOnly = true
            NewsFilter.selected = newsFilter
        }
        if !UserDefaults.standard.bool(forKey: "expandedNewsV22") {
            interval = 60
            UserDefaults.standard.set(60.0, forKey: "refreshInterval")
            UserDefaults.standard.set(true, forKey: "expandedNewsV22")
        }
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode([String: CachedFeed].self, from: data) {
            feeds = limitedCachedFeeds(cache)
            persistFeeds()
        }
        readCameras()
    }
    private func limitedCachedFeeds(_ cached: [String: CachedFeed]) -> [String: CachedFeed] {
        let snapshots = cached.filter { !disabled.contains($0.key) }.mapValues { SourceSnapshot(events: $0.events, fetchedAt: $0.fetched) }
        return limitedSourceFeeds(snapshots).mapValues { CachedFeed(events: $0.events, fetched: $0.fetchedAt) }
    }
    func start() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                let began = Date()
                // Run detached from the loop so restarting it (interval change) cannot cancel in-flight fetches.
                await Task { await self.refresh() }.value
                let remaining = max(1, interval - Date().timeIntervalSince(began))
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            }
        }
    }
    func startMapLayers() {
        mapLoop?.cancel()
        mapLoop = Task {
            while !Task.isCancelled {
                if await MapLayerService.shared.refresh(cities: selectedCities) { objectWillChange.send(); requestWidgetReload() }
                do { try await Task.sleep(nanoseconds: 300 * 1_000_000_000) } catch { return }
            }
        }
    }
    func prepareChinese() {
        translationConfiguration = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        translationConfiguration?.invalidate()
    }
    func prepareChinese(using session: TranslationSession) async {
        do {
            translationStatus = "正在准备中英翻译语言…"
            try await session.prepareTranslation()
            await translateTitles(using: session)
            requestWidgetReload(force: true)
        } catch { translationStatus = "中文翻译未就绪：\(error.localizedDescription)" }
    }
    func translateTitles(using session: TranslationSession? = nil) async {
        guard !translating else { return }
        translating = true
        defer { translating = false }
        let balanced = displayPool(events, mode: widgetDisplayMode)
        let current = widgetDisplayMode == .latest ? Array(balanced.prefix(9)) : rotationEvents(balanced, at: Date(), limit: 6).events
        let currentIDs = Set(current.map(\.id))
        let original = current + balanced.filter { !currentIDs.contains($0.id) } + events.filter { item in !balanced.contains { $0.id == item.id } }
        let cached = await TitleTranslator.shared.applyCache(to: original)
        applyTranslated(cached)
        let pending = Array(cached.filter(needsTitleTranslation).prefix(24))
        guard !pending.isEmpty else { translationStatus = "中文自动翻译已开启"; return }
        let localReady = await TitleTranslator.shared.available()
        translationStatus = localReady ? "正在使用 Apple 本机翻译…" : "正在翻译公开标题，新闻检查继续运行…"
        do {
            for start in stride(from: 0, to: pending.count, by: 4) {
                let batch = Array(pending[start..<min(start + 4, pending.count)])
                let translated = try await TitleTranslator.shared.translate(batch, session: session)
                applyTranslated(translated)
                persistFeeds()
                publishWidgetSnapshot()
            }
            translationStatus = localReady ? "中文自动翻译已开启 · Apple 本机翻译" : "中文自动翻译已开启 · 在线备用翻译"
        } catch {
            applyTranslated(await TitleTranslator.shared.applyCache(to: original))
            persistFeeds(); publishWidgetSnapshot()
            translationStatus = "部分标题待翻译，将自动重试"
        }
    }

    private func applyTranslated(_ events: [WorldEvent]) {
        let translated = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for source in Array(feeds.keys) {
            guard var feed = feeds[source] else { continue }
            feed.events = feed.events.map { translated[$0.id] ?? $0 }
            feeds[source] = feed
        }
    }
    func toggle(_ source: NewsSource) {
        if disabled.contains(source.id) { disabled.remove(source.id) } else { disabled.insert(source.id) }
        UserDefaults.standard.set(Array(disabled), forKey: "disabledSources")
        // Apply the toggle to the widget now; refresh() is skipped while another check is running.
        publishWidgetSnapshot(forceReload: true)
        Task { await refresh() }
    }
    func setDomesticShare(_ share: DomesticShare) {
        DomesticShare.selected = share
        objectWillChange.send()
        publishWidgetSnapshot(forceReload: true)
    }
    func setNewsFilter(_ value: NewsFilter) {
        newsFilter = value.cleaned
        NewsFilter.selected = newsFilter
        publishWidgetSnapshot(forceReload: true)
    }
    func setWidgetDisplayMode(_ mode: NewsDisplayMode) {
        widgetDisplayMode = mode
        NewsDisplayMode.selected = mode
        filter = mode == .latest ? "最新" : "综合"
        publishWidgetSnapshot(forceReload: true)
        Task { await translateTitles() }
    }
    func setInterval(_ seconds: Double) {
        interval = seconds; UserDefaults.standard.set(seconds, forKey: "refreshInterval"); start()
    }
    var selectedCities: [CameraCity] { cameraCities.compactMap { id in CameraCity.all.first { $0.id == id } } }
    func readCameras() {
        let snapshots = CameraSnapshotStore.shared
        cameraSources = Dictionary(uniqueKeysWithValues: CameraCity.all.map { ($0.id, snapshots.pool($0)) })
        cameraHealth = snapshots.health()
        cameraManifests = Dictionary(uniqueKeysWithValues: CameraCity.all.compactMap { city in
            CameraSnapshotStore.shared.read(city.id).map { manifest in
                var visible = manifest; visible.frames = manifest.frames.filter(CameraOptions.allows)
                return (city.id, visible)
            }
        })
    }
    func startCameras() {
        cameraLoop?.cancel()
        cameraLoop = Task {
            while !Task.isCancelled {
                await Task { await self.refreshCameras() }.value
                // Sleep until the earliest city falls due rather than a full interval: a round that found
                // nothing due would otherwise push the next capture out to almost twice the interval.
                let nextDue = selectedCities.compactMap { CameraSnapshotStore.shared.read($0.id)?.checkedAt }
                    .map { $0.addingTimeInterval(cameraInterval) }.min()
                let delay = min(cameraInterval, max(30, nextDue.map { $0.timeIntervalSinceNow } ?? cameraInterval))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }
    func refreshCameras(force: Bool = false) async {
        guard !cameraRefreshing else { return }
        cameraRefreshing = true
        defer { cameraRefreshing = false }
        let changed = await CameraService.shared.refresh(cities: selectedCities, force: force, resetCooldown: force)
        CameraCity.appHeartbeat = Date()
        readCameras()
        if changed { requestWidgetReload() }
    }
    func setCameraSource(_ source: CameraSource, enabled: Bool) {
        if enabled { disabledCameras.remove(source.id) } else { disabledCameras.insert(source.id) }
        CameraOptions.disabled = disabledCameras
        readCameras(); requestWidgetReload(force: true)
        Task { await refreshCameras() }
    }
    func setSkylineCameras(_ enabled: Bool) {
        skylineCameras = enabled; CameraOptions.skyline = enabled
        readCameras(); requestWidgetReload(force: true)
        Task { await refreshCameras() }
    }
    func setCameraInterval(_ value: Double) {
        cameraInterval = value; CameraCity.interval = value; startCameras()
        requestWidgetReload(force: true)
    }
    func toggleCity(_ city: CameraCity) {
        if cameraCities.contains(city.id) { cameraCities.removeAll { $0 == city.id } }
        else if cameraCities.count < 4 { cameraCities.append(city.id) }
        WorldPreferences.shared.set(cameraCities, forKey: "cameraCities")
        requestWidgetReload(force: true)
        startMapLayers()
        Task { await refreshCameras() }
    }
    func moveCity(_ id: String, direction: Int) {
        guard let index = cameraCities.firstIndex(of: id), cameraCities.indices.contains(index + direction) else { return }
        cameraCities.swapAt(index, index + direction)
        WorldPreferences.shared.set(cameraCities, forKey: "cameraCities")
        requestWidgetReload(force: true)
    }
    func setMapRegion(_ value: MapRegion) { MapRegion.selected = value; objectWillChange.send(); requestWidgetReload(force: true) }
    func setMapLayer(_ key: String, enabled: Bool) { WorldPreferences.shared.set(enabled, forKey: key); objectWillChange.send(); requestWidgetReload(force: true); startMapLayers() }
    func requestWidgetReload(force: Bool = false, newsChanged: Bool = false) {
        let now = Date()
        let delay = widgetReloadDelay(last: lastWidgetReload, now: now, newsChanged: newsChanged)
        if force || delay == 0 {
            widgetReloadTask?.cancel(); widgetReloadTask = nil; widgetReloadAt = nil
            lastWidgetReload = now
            requestedWidgetSnapshot = NewsSnapshotStore.shared.read()
            for kind in ["WorldWatchNews", "WorldWatchDashboard", "WorldWatchMap", "WorldWatchLive"] { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        } else {
            let deadline = now.addingTimeInterval(delay)
            if let existing = widgetReloadAt, existing <= deadline { return }
            widgetReloadTask?.cancel(); widgetReloadAt = deadline
            widgetReloadTask = Task {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                widgetReloadTask = nil; widgetReloadAt = nil
                requestWidgetReload(force: true)
            }
        }
    }
    private func scheduleIncrementalSnapshot() {
        guard incrementalSnapshotTask == nil else { return }
        incrementalSnapshotTask = Task {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            incrementalSnapshotTask = nil
            publishWidgetSnapshot()
        }
    }
    func refresh(reloadWidget: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let sources = enabledSources
        await withTaskGroup(of: (String, [WorldEvent]?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source.id, try await fetchSource(source), nil) }
                    catch is CancellationError { return (source.id, nil, nil) }
                    catch let error as URLError where error.code == .cancelled { return (source.id, nil, nil) }
                    catch { return (source.id, nil, error.localizedDescription) }
                }
            }
            for await (id, items, error) in group {
                if let items {
                    let cached = await TitleTranslator.shared.applyCache(to: items)
                    let previous = events
                    let previousConflicts = observedConflicts
                    observedConflicts = mergedConflictSignals(observedConflicts, conflictSignals(cached), enabledIDs: enabledSources.map(\.id))
                    var updated = feeds
                    updated[id] = CachedFeed(events: cached, fetched: Date())
                    feeds = limitedCachedFeeds(updated); errors.removeValue(forKey: id)
                    let changed = !sameRenderedNews(previous, events) || mapMarkers(previous) != mapMarkers(events) || previousConflicts != observedConflicts
                    if changed { scheduleIncrementalSnapshot() }
                }
                else if let error { errors[id] = error }
            }
        }
        await TitleTranslator.shared.prune(keeping: Set(feeds.values.flatMap { $0.events.map(\.title) }))
        lastCheck = Date()
        rotationDate = Date()
        NSLog("世界动态刷新完成：%ld/%ld 来源成功，%ld 条可显示", healthyCount, enabledSources.count, events.count)
        persistFeeds()
        incrementalSnapshotTask?.cancel(); incrementalSnapshotTask = nil
        publishWidgetSnapshot(forceReload: reloadWidget)
        Task { await translateTitles() }
    }
    private func persistFeeds() {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(feeds).write(to: cacheURL, options: .atomic)
        } catch { NSLog("缓存保存失败：%@", error.localizedDescription) }
    }
    func publishWidgetSnapshot(forceReload: Bool = false) {
        let publishedAt = Date()
        let store = NewsSnapshotStore.shared
        let previous = store.read()
        let results = enabledSources.map { source in
            SourceFetchResult(id: source.id, events: errors[source.id] == nil ? feeds[source.id]?.events : nil, fetchedAt: feeds[source.id]?.fetched)
        }
        let checked = max(lastCheck ?? .distantPast, previous?.checkDate ?? .distantPast)
        var snapshot = refreshedSnapshot(previous: previous, results: results, now: checked == .distantPast ? publishedAt : checked, enabledIDs: enabledSources.map(\.id), mode: widgetDisplayMode, observedAt: publishedAt)
        snapshot.conflictSignals = mergedConflictSignals(snapshot.conflictSignals ?? [], observedConflicts, enabledIDs: enabledSources.map(\.id), now: publishedAt)
        snapshot.updatedAt = publishedAt
        if let previous, !sameDigest(previous.rotationEvents ?? previous.events, snapshot.rotationEvents ?? snapshot.events) {
            snapshot.changedAt = publishedAt
        }
        let changed = (requestedWidgetSnapshot ?? previous).map {
            !sameDigest($0.rotationEvents ?? $0.events, snapshot.rotationEvents ?? snapshot.events)
                || ($0.rotationEvents ?? $0.events).map(\.displayTitle) != (snapshot.rotationEvents ?? snapshot.events).map(\.displayTitle)
                || $0.mode != snapshot.mode || $0.availableSources != snapshot.availableSources || $0.enabledSourceIDs != snapshot.enabledSourceIDs
                || !sameDigest(mergedEvents($0.sourceFeeds?.values.flatMap(\.events) ?? []), mergedEvents(snapshot.sourceFeeds?.values.flatMap(\.events) ?? []))
                || mapMarkers($0.sourceFeeds?.values.flatMap(\.events) ?? []) != mapMarkers(snapshot.sourceFeeds?.values.flatMap(\.events) ?? [])
                || $0.conflictSignals != snapshot.conflictSignals
        } ?? true
        do {
            let saved = try store.write(snapshot)
            NSLog("组件摘要同步：shared=%@ checked=%.0f items=%ld", store.groupAvailable ? "YES" : "NO", snapshot.date.timeIntervalSince1970, snapshot.events.count)
            if forceReload { requestWidgetReload(force: true) }
            else if saved {
                let newsChanged = widgetNewsChanged(from: requestedWidgetSnapshot ?? previous, to: snapshot, filter: newsFilter, now: publishedAt)
                if changed || newsChanged { requestWidgetReload(newsChanged: newsChanged) }
            }
        } catch { NSLog("小组件共享摘要保存失败：%@", error.localizedDescription) }
    }
}

struct EventRow: View {
    let event: WorldEvent
    @State private var hovering = false
    var body: some View {
        Button {
            NSWorkspace.shared.open(event.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.sourceName).fontWeight(.semibold).foregroundStyle(.secondary)
                    if let date = event.date {
                        Text((event.timeKind == "发生" ? "发生 " : "") + shortTimeLabel(date)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    if let severity = event.severity {
                        Text(severity).fontWeight(.medium).foregroundStyle(severity == "红色预警" ? Color.red : Color.orange)
                    }
                    Spacer(minLength: 8)
                }
                .font(.system(size: 11)).lineLimit(1)
                Text(event.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(event.translatedTitle == nil ? "打开原始报道 · \(event.url.host ?? "")" : "原文：\(event.title)\n打开原始报道 · \(event.url.host ?? "")")
    }
}

struct WorldView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: EventStore
    @State private var showCameras = false
    static let scopes = ["综合", "最新", "国内", "国际", "政治", "财经", "科技", "文娱", "体育", "灾害"]
    var rows: [WorldEvent] {
        let raw = store.enabledSources.flatMap { store.feeds[$0.id]?.events ?? [] }
        let personal = store.newsFilter.mode == .personal
        let events = personal || store.newsFilter.eventsOnly ? uniqueNewsEvents(applyNewsFilter(raw, filter: store.newsFilter), mergeTopics: false, now: store.rotationDate) : store.events
        if store.filter == "综合" {
            let pool = digestPool(raw, now: store.rotationDate, filter: store.newsFilter)
            let page = rotationEvents(pool, at: store.rotationDate).events
            let ids = Set(page.map(\.id))
            return page + pool.filter { !ids.contains($0.id) }
        }
        if store.filter == "最新" { return balancedByOrigin(events, ratio: DomesticShare.selected.ratio) }
        return events.filter { event in
            switch store.filter {
            case "国内": return event.isDomestic
            case "国际": return !event.isDomestic && !event.disaster
            default: return event.category.rawValue == store.filter
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.translationStatus.hasPrefix("中文自动翻译已开启") { translationNotice }
            Divider()
            content
        }
        .frame(minWidth: 350, maxWidth: .infinity, minHeight: 350, maxHeight: .infinity)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .translationTask(store.translationConfiguration) { session in
            await store.prepareChinese(using: session)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("世界动态").font(.system(size: 22, weight: .bold))
                Spacer()
                Group {
                    Button { showCameras.toggle() } label: {
                        Image(systemName: showCameras ? "newspaper" : "video").frame(width: 28, height: 28)
                    }
                    .help(showCameras ? "返回新闻" : "城市实景").accessibilityLabel(showCameras ? "返回新闻" : "城市实景")
                    if store.refreshing {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    } else {
                        Button { Task { await store.refresh(reloadWidget: true) } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                        }
                        .help("立即检查更新").accessibilityLabel("立即检查更新")
                    }
                    Button { store.showSources = true } label: {
                        Image(systemName: "gearshape").frame(width: 28, height: 28)
                    }
                    .help("设置").accessibilityLabel("设置")
                }
                .buttonStyle(.borderless).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 5) {
                        if needsAttention(now: context.date) { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                        Text(statusText + (store.newsFilter.mode == .personal ? " · 个性新闻" : ""))
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Section("新闻过滤") {
                        Picker("新闻过滤", selection: Binding(get: { store.newsFilter.mode }, set: { mode in
                            var value = store.newsFilter; value.mode = mode; store.setNewsFilter(value)
                        })) {
                            ForEach(NewsFilterMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline)
                        Toggle("只看事件类新闻", isOn: Binding(get: { store.newsFilter.eventsOnly }, set: { on in
                            var value = store.newsFilter; value.eventOnly = on; store.setNewsFilter(value)
                        }))
                    }
                    Section("范围") {
                    Picker("范围", selection: $store.filter) {
                        ForEach(Self.scopes, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    }
                } label: {
                    Text("\(store.filter) · \(rows.count) 条").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                .accessibilityLabel("新闻范围")
            }
        }
        .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 12)
    }

    var translationNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble").foregroundStyle(.secondary)
            Text(store.translationStatus).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !store.translating { Button("启用中文") { store.prepareChinese() }.controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    @ViewBuilder var content: some View {
        if showCameras {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                CameraGrid(cities: store.selectedCities, frames: store.cameraManifests.mapValues(\.frames), index: Int(context.date.timeIntervalSince1970 / 60))
                    .padding(12)
            }
        } else if rows.isEmpty {
            ContentUnavailableView {
                if store.newsFilter.mode == .personal || store.newsFilter.eventsOnly { Label("没有符合条件的新闻", systemImage: "line.3.horizontal.decrease.circle") }
                else if store.refreshing { Label("正在获取新闻", systemImage: "antenna.radiowaves.left.and.right") }
                else if store.enabledSources.isEmpty { Label("尚未选择来源", systemImage: "newspaper") }
                else if store.healthyCount == 0 { Label("暂时无法连接", systemImage: "wifi.exclamationmark") }
                else { Label("暂无报道", systemImage: "globe.asia.australia") }
            } description: {
                Text(store.newsFilter.mode == .personal || store.newsFilter.eventsOnly ? "请调整新闻过滤设置。" : store.enabledSources.isEmpty ? "在设置中启用至少一个来源。" : store.healthyCount == 0 && !store.refreshing ? "请检查网络后重试。" : "新闻最多保留最新 100 条（地震与灾害另计）；新闻最长三天，灾害最长七天。")
            } actions: {
                if store.newsFilter.mode == .personal || store.newsFilter.eventsOnly { Button("调整过滤") { store.showSources = true } }
                else if store.enabledSources.isEmpty { Button("打开设置") { store.showSources = true } }
                else if !store.refreshing { Button("重新连接") { Task { await store.refresh() } } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows.prefix(retainedNewsLimit)) { event in
                        EventRow(event: event)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.92), value: Array(rows.prefix(retainedNewsLimit).map(\.id)))
            }
            .clipped()
        }
    }

    var statusText: String {
        if store.refreshing { return "正在检查更新…" }
        if store.enabledSources.isEmpty { return "未启用来源" }
        guard let date = store.lastCheck else { return store.feeds.isEmpty ? "等待连接" : "显示上次缓存" }
        return "\(shortTimeLabel(date)) 已检查 · \(store.healthyCount)/\(store.enabledSources.count) 个来源"
    }
    func needsAttention(now: Date) -> Bool {
        guard !store.refreshing, !store.enabledSources.isEmpty, let last = store.lastCheck else { return false }
        return store.healthyCount < store.enabledSources.count || now.timeIntervalSince(last) > store.interval * 3
    }
}

struct KeywordFlow: Layout {
    var spacing: CGFloat = 6
    func positions(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: positions(subviews, width: width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = positions(subviews, width: bounds.width).points
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), proposal: .unspecified)
        }
    }
}

struct NewsFilterSection: View {
    @ObservedObject var store: EventStore
    @State private var followedInput = ""
    @State private var blockedInput = ""
    private var enabledIDs: Set<String> { Set(NewsSource.all.map(\.id)).subtracting(store.disabled) }
    private var selectedCount: Int { enabledIDs.subtracting(store.newsFilter.excludedSources).count }
    private func update(_ change: (inout NewsFilter) -> Void) {
        var value = store.newsFilter
        change(&value)
        store.setNewsFilter(value)
    }
    private func addKeyword(_ followed: Bool) {
        let input = followed ? followedInput : blockedInput
        let word = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let current = followed ? store.newsFilter.followed : store.newsFilter.blocked
        guard current.count < 50 else { return }
        update { filter in
            if followed { filter.followed.append(word) } else { filter.blocked.append(word) }
        }
        if followed { followedInput = "" } else { blockedInput = "" }
    }
    private func keywordEditor(_ title: String, followed: Bool) -> some View {
        let words = followed ? store.newsFilter.followed : store.newsFilter.blocked
        let input = followed ? $followedInput : $blockedInput
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).fontWeight(.medium)
            HStack(spacing: 8) {
                TextField("输入关键词", text: input).textFieldStyle(.roundedBorder).onSubmit { addKeyword(followed) }
                    .accessibilityLabel(title)
                Button("添加") { addKeyword(followed) }
                    .disabled(words.count >= 50 || input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("添加\(title)")
            }
            if !words.isEmpty {
                KeywordFlow {
                    ForEach(words, id: \.self) { word in
                        Button {
                            update { filter in
                                if followed { filter.followed.removeAll { $0 == word } } else { filter.blocked.removeAll { $0 == word } }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(word).lineLimit(1).truncationMode(.tail).frame(maxWidth: 270)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain).help("删除\(word)").accessibilityLabel("删除\(title)：\(word)")
                    }
                }
            }
            Text("最多 50 个").font(.caption).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        Section {
            Picker("新闻过滤", selection: Binding(get: { store.newsFilter.mode }, set: { mode in update { $0.mode = mode } })) {
                ForEach(NewsFilterMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { store.newsFilter.eventsOnly }, set: { on in update { $0.eventOnly = on } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("只看事件类新闻")
                    Text("只保留「某地发生了某事」式的报道，排除访谈、评论、解读、特写、预告与软文；按标题规则判断，可能有误差").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if store.newsFilter.mode == .personal {
                VStack(alignment: .leading, spacing: 8) {
                    Text("领域").fontWeight(.medium)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(NewsCategory.allCases, id: \.rawValue) { category in
                            Toggle(category.rawValue, isOn: Binding(get: { !store.newsFilter.excludedCategories.contains(category.rawValue) }, set: { on in
                                update { filter in
                                    if on { filter.excludedCategories.remove(category.rawValue) } else { filter.excludedCategories.insert(category.rawValue) }
                                }
                            }))
                        }
                    }
                }
                DisclosureGroup("来源（已选 \(selectedCount)/\(NewsSource.all.count)）") {
                    HStack {
                        Button("全选") { update { $0.excludedSources.subtract(enabledIDs) } }
                        Button("全不选") { update { $0.excludedSources.formUnion(enabledIDs) } }
                    }.padding(.vertical, 4)
                    ForEach(NewsSource.all) { source in
                        Toggle(isOn: Binding(get: { !store.newsFilter.excludedSources.contains(source.id) && !store.disabled.contains(source.id) }, set: { on in
                            update { filter in
                                if on { filter.excludedSources.remove(source.id) } else { filter.excludedSources.insert(source.id) }
                            }
                        })) {
                            HStack {
                                Text(source.name)
                                if store.disabled.contains(source.id) { Text("已停止抓取").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(store.disabled.contains(source.id))
                    }
                }
                keywordEditor("关注关键词", followed: true)
                Toggle("只看含关注关键词的新闻", isOn: Binding(get: { store.newsFilter.followOnly }, set: { on in update { $0.followOnly = on } }))
                keywordEditor("屏蔽关键词", followed: false)
            }
        } header: { Text("新闻过滤") } footer: {
            Text("事件过滤按标题识别访谈、评论和介绍，可能有误判；关注关键词可保留匹配报道，屏蔽关键词优先。过滤不影响地图。")
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: EventStore
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("显示方式", selection: Binding(get: { store.widgetDisplayMode }, set: { store.setWidgetDisplayMode($0) })) {
                        ForEach(NewsDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("国内新闻占比", selection: Binding(get: { DomesticShare.selected }, set: { store.setDomesticShare($0) })) {
                        ForEach(DomesticShare.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } header: { Text("小组件") } footer: {
                    Text((store.widgetDisplayMode == .latest ? "按报道时间排列，新报道出现在最上方。" : "混合不同领域的近期报道并定时轮换，轮换不代表新发布。")
                         + "北京时间白天国内发稿集中，「均衡」时国内新闻约占三分之一、「少」约占五分之一，超出的顺延到后面，不会丢弃；同时作用于应用里的「最新」列表。")
                        .foregroundStyle(.secondary)
                }
                NewsFilterSection(store: store)
                Section("更新") {
                    Picker("检查间隔", selection: Binding(get: { store.interval }, set: { store.setInterval($0) })) {
                        Text("1 分钟").tag(60.0); Text("3 分钟").tag(180.0); Text("5 分钟").tag(300.0)
                    }
                }
                Section("翻译") {
                    LabeledContent("中英翻译") {
                        Text(store.translationStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Button("准备本机翻译语言") { store.prepareChinese() }
                }
                Section {
                    Picker("地图范围", selection: Binding(get: { MapRegion.selected }, set: { store.setMapRegion($0) })) {
                        ForEach(MapRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    ForEach([("mapEarthquakes", "地震", "USGS，24 小时内 M6.0 及以上"),
                             ("mapCyclones", "台风", "GDACS，仅显示仍活跃的气旋；虚线为约未来 12 小时路径"),
                             ("mapDisasters", "洪水与火山", "GDACS，进行中或 3 天内的红／橙预警"),
                             ("mapConflicts", "持续冲突地区", "UCDP 月度有组织暴力记录为底图，叠加近 48 小时新闻；最多显示 15 国"),
                             ("mapNight", "昼夜分界", "按条目时间在本地计算"),
                             ("mapISS", "国际空间站", "wheretheiss.at，按条目时间估算位置")], id: \.0) { key, label, detail in
                        Toggle(isOn: Binding(get: { WorldPreferences.enabled(key) }, set: { store.setMapLayer(key, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label)
                                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    let baseline = MapLayerStore.shared.ongoing()
                    LabeledContent("冲突数据月份", value: baseline.monthLabel + (baseline.isRecent(at: Date()) ? "（月度发布）" : "（已过期，暂停底图）"))
                    Link("UCDP Candidate Events Dataset · CC BY 4.0", destination: OngoingConflictSnapshot.source)
                        .font(.caption)
                    Text("Hegre 等（2020）。颜色表示所在国有冲突活动，不代表全国都是战区或实时战线。数据存在发布滞后；深浅综合月度记录与新闻评分，由本应用分级。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("世界地图") }
                Section {
                    Picker("抓取间隔", selection: Binding(get: { store.cameraInterval }, set: { store.setCameraInterval($0) })) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) 分钟").tag(Double($0 * 60)) }
                    }
                    Toggle("SkylineWebcams 预览图", isOn: Binding(get: { store.skylineCameras }, set: { store.setSkylineCameras($0) }))
                    ForEach(store.selectedCities + CameraCity.all.filter { !store.cameraCities.contains($0.id) }) { city in
                        VStack(alignment: .leading, spacing: 8) {
                            cameraCityRow(city)
                            DisclosureGroup {
                                if let sources = store.cameraSources[city.id], !sources.isEmpty {
                                    ForEach(sources) { source in cameraSourceRow(source) }
                                } else {
                                    Text("暂无固定来源，选择城市后自动搜索镜头。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } label: {
                                Text("来源（\(store.cameraSources[city.id]?.count ?? 0)）")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("\(city.name)来源")
                        }
                    }
                    Button(store.cameraRefreshing ? "正在重新检测…" : "立即重新检测") {
                        Task { await store.refreshCameras(force: true) }
                    }
                    .disabled(store.cameraRefreshing || store.cameraCities.isEmpty)
                } header: { Text("城市实景") } footer: {
                    Text("已选 \(store.cameraCities.count)/4 座城市，最多选择 4 座，可上下调整显示顺序。画面为定时截图轮播；来源失效时自动尝试其他候选，全部失败则保留旧图。首次画面待验证，后续比较确认是否变化。SkylineWebcams 仅供个人查看，点击打开 SkylineWebcams 原页面。").foregroundStyle(.secondary)
                }
                Section {
                    ForEach(NewsSource.all) { source in
                        Toggle(isOn: Binding(get: { !store.disabled.contains(source.id) }, set: { _ in store.toggle(source) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                sourceDetail(source).font(.system(size: 11))
                            }
                        }
                    }
                } header: { Text("来源") } footer: {
                    Text("新闻最多保留最新 100 条（地震与灾害另计）；新闻最长三天，灾害最长七天。小组件的实际刷新时刻由 macOS 决定。停止抓取会同时影响地图；只想不显示某个来源请用「新闻过滤」。").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440).frame(minHeight: 420, idealHeight: 620)
    }
    private func cameraCityRow(_ city: CameraCity) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { store.cameraCities.contains(city.id) }, set: { _ in store.toggleCity(city) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(city.name)
                    if let manifest = store.cameraManifests[city.id] {
                        if let error = manifest.error { Text(error).foregroundStyle(.orange).font(.caption) }
                        else if let date = manifest.fetchedAt { Text("\(shortTimeLabel(date)) 成功获取").foregroundStyle(.secondary).font(.caption) }
                    } else { Text("等待获取实景截图").foregroundStyle(.secondary).font(.caption) }
                }
            }
            .accessibilityLabel(city.name)
            .disabled(!store.cameraCities.contains(city.id) && store.cameraCities.count >= 4)
            if let index = store.cameraCities.firstIndex(of: city.id) {
                Button { store.moveCity(city.id, direction: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).accessibilityLabel("上移\(city.name)")
                Button { store.moveCity(city.id, direction: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == store.cameraCities.count - 1).accessibilityLabel("下移\(city.name)")
            }
        }
    }
    private func cameraSourceRow(_ source: CameraSource) -> some View {
        let record = store.cameraHealth[source.id] ?? CameraHealth()
        return Toggle(isOn: Binding(get: { !store.disabledCameras.contains(source.id) }, set: { store.setCameraSource(source, enabled: $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(source.platform.title) · \(source.title)").fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(record.state.title)
                    if let changed = record.lastChanged {
                        Text("最近变化 \(shortTimeLabel(changed))")
                    } else { Text("尚未检测到变化") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .help(record.reason ?? source.page.absoluteString)
        }
        .disabled(source.platform == .skyline && !store.skylineCameras)
        .accessibilityLabel("\(source.platform.title)，\(source.title)，\(record.state.title)，\(record.lastChanged.map { "最近变化 " + shortTimeLabel($0) } ?? "尚未检测到变化")")
    }
    @ViewBuilder func sourceDetail(_ source: NewsSource) -> some View {
        if let error = store.errors[source.id], !store.disabled.contains(source.id) {
            Text(error).foregroundStyle(.orange)
        } else if let fetched = store.feeds[source.id]?.fetched {
            Text("\(source.detail) · \(shortTimeLabel(fetched)) 更新").foregroundStyle(.secondary)
        } else {
            Text(source.detail).foregroundStyle(.secondary)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = EventStore()
    var panel: NSWindow!
    var item: NSStatusItem!
    var settingsWindow: NSWindow?
    var settingsRequest: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "世界动态"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 350, height: 350)
        panel.level = .normal
        panel.contentView = NSHostingView(rootView: WorldView(store: store))
        if !panel.setFrameUsingName("WorldWatchDesktop") { resetPosition() }
        ensureVisible()
        panel.setFrameAutosaveName("WorldWatchDesktop")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "globe.asia.australia", accessibilityDescription: "世界动态")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开世界动态", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "隐藏窗口", action: #selector(hide), keyEquivalent: "")
        menu.addItem(withTitle: "重置位置", action: #selector(resetPosition), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "立即检查更新", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出世界动态", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        panel.orderFrontRegardless()
        store.start()
        store.startCameras()
        store.startMapLayers()
        // In-app "设置" buttons set showSources; present the standalone settings window instead of a sheet.
        settingsRequest = store.$showSources.filter { $0 }.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.store.showSources = false
            self?.presentSettings()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func ensureVisible() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(panel.frame) }) { resetPosition() }
    }
    @objc func screensChanged() { ensureVisible() }
    @objc func show() { ensureVisible(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func hide() { panel.orderOut(nil) }
    @objc func openSettings() { presentSettings() }
    func presentSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            window.title = "设置"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 440, height: 620))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.maxX - 444, y: max(f.minY + 20, f.maxY - 634), width: 420, height: min(610, f.height - 40)), display: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func application(_ application: NSApplication, open urls: [URL]) { show() }
    @objc func refresh() { Task { await store.refresh(reloadWidget: true) } }
    @objc func quit() { NSApp.terminate(nil) }
}

@main struct WorldWatchMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
