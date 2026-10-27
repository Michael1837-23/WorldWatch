import Cocoa
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
    @Published var rotationDate = Date()
    @Published var showSources = false
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
    private var lastWidgetReload = Date.distantPast
    private var requestedWidgetSnapshot: NewsSnapshot?
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldWatch/feeds.json")
    init() {
        filter = widgetDisplayMode == .latest ? "最新" : "综合"
        if !UserDefaults.standard.bool(forKey: "expandedNewsV22") {
            interval = 60
            UserDefaults.standard.set(60.0, forKey: "refreshInterval")
            UserDefaults.standard.set(true, forKey: "expandedNewsV22")
        }
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode([String: CachedFeed].self, from: data) { feeds = cache }
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
    func prepareChinese() {
        translationConfiguration = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        translationConfiguration?.invalidate()
    }
    func prepareChinese(using session: TranslationSession) async {
        do {
            translationStatus = "正在准备中英翻译语言…"
            try await session.prepareTranslation()
            await translateTitles(using: session)
            WidgetCenter.shared.reloadTimelines(ofKind: "WorldWatchNews")
        } catch { translationStatus = "中文翻译未就绪：\(error.localizedDescription)" }
    }
    func translateTitles(using session: TranslationSession? = nil) async {
        guard !translating else { return }
        translating = true
        defer { translating = false }
        let balanced = displayPool(events, mode: widgetDisplayMode)
        let current = widgetDisplayMode == .latest ? Array(balanced.prefix(4)) : rotationEvents(balanced, at: Date()).events
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
                    feeds[id] = CachedFeed(events: cached, fetched: Date()); errors.removeValue(forKey: id)
                }
                else if let error { errors[id] = error }
            }
        }
        await TitleTranslator.shared.prune(keeping: Set(feeds.values.flatMap { $0.events.map(\.title) }))
        lastCheck = Date()
        rotationDate = Date()
        NSLog("世界动态刷新完成：%ld/%ld 来源成功，%ld 条可显示", healthyCount, enabledSources.count, events.count)
        persistFeeds()
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
        let store = NewsSnapshotStore.shared
        let previous = store.read()
        let results = enabledSources.map { source in
            SourceFetchResult(id: source.id, events: errors[source.id] == nil ? feeds[source.id]?.events : nil)
        }
        let snapshot = refreshedSnapshot(previous: previous, results: results, now: lastCheck ?? previous?.checkDate ?? Date(), enabledIDs: enabledSources.map(\.id), mode: widgetDisplayMode)
        let changed = (requestedWidgetSnapshot ?? previous).map {
            !sameDigest($0.rotationEvents ?? $0.events, snapshot.rotationEvents ?? snapshot.events)
                || ($0.rotationEvents ?? $0.events).map(\.displayTitle) != (snapshot.rotationEvents ?? snapshot.events).map(\.displayTitle)
                || $0.mode != snapshot.mode || $0.availableSources != snapshot.availableSources || $0.enabledSourceIDs != snapshot.enabledSourceIDs
        } ?? true
        do {
            let saved = try store.write(snapshot)
            NSLog("组件摘要同步：shared=%@ checked=%.0f items=%ld", store.groupAvailable ? "YES" : "NO", snapshot.date.timeIntervalSince1970, snapshot.events.count)
            if forceReload || (saved && changed && Date().timeIntervalSince(lastWidgetReload) >= 55) {
                lastWidgetReload = Date()
                requestedWidgetSnapshot = snapshot
                WidgetCenter.shared.reloadTimelines(ofKind: "WorldWatchNews")
            }
        } catch { NSLog("小组件共享摘要保存失败：%@", error.localizedDescription) }
    }
}

private let ink = Color(red: 0.92, green: 0.94, blue: 0.98)
private let secondaryInk = Color(red: 0.64, green: 0.70, blue: 0.79)
private let accent = Color(red: 0.49, green: 0.74, blue: 1.0)

struct EventRow: View {
    let event: WorldEvent
    let cached: Bool
    var body: some View {
        Button {
            NSWorkspace.shared.open(event.url)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if let date = event.date {
                        Text(date, format: .dateTime.hour().minute()).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(date, format: .dateTime.month().day()).font(.system(size: 10))
                    } else { Text("时间未知").font(.system(size: 10)) }
                    Text(event.timeKind).font(.system(size: 10))
                }.foregroundStyle(secondaryInk).frame(width: 55, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text(event.displayTitle).font(.system(size: 14, weight: .medium)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).foregroundStyle(ink)
                    HStack(spacing: 7) {
                        Text(event.category.rawValue).foregroundStyle(accent)
                        Text(NewsSource.all.first { $0.id == event.sourceID }?.name ?? event.sourceID).foregroundStyle(secondaryInk)
                        if let severity = event.severity { Text(severity).foregroundStyle(event.severity == "红色预警" ? Color(red: 1, green: 0.59, blue: 0.57) : Color(red: 1, green: 0.77, blue: 0.47)) }
                        if cached { Text("缓存").foregroundStyle(Color.orange) }
                        if event.translatedTitle != nil { Text("机译").foregroundStyle(secondaryInk) }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").foregroundStyle(secondaryInk.opacity(0.6))
                    }.font(.system(size: 10))
                }
            }.padding(.vertical, 13).padding(.horizontal, 20)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("原文：\(event.title)\n打开原始报道 · \(event.url.host ?? "")")
    }
}

struct WorldView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: EventStore
    var rows: [WorldEvent] {
        if store.filter == "综合" {
            let pool = digestPool(store.events, now: store.rotationDate)
            let page = rotationEvents(pool, at: store.rotationDate).events
            let ids = Set(page.map(\.id))
            return page + pool.filter { !ids.contains($0.id) }
        }
        return store.events.filter { event in
            switch store.filter {
            case "国内": return event.isDomestic
            case "国际": return !event.isDomestic && !event.disaster
            case "最新": return true
            default: return event.category.rawValue == store.filter
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 9) {
                    Image(systemName: "globe.asia.australia.fill").font(.system(size: 21)).foregroundStyle(accent)
                    Text("世界动态").font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
                    Spacer()
                    Button { Task { await store.refresh(reloadWidget: true) } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
                    }.buttonStyle(.plain).foregroundStyle(secondaryInk).disabled(store.refreshing)
                        .help("立即检查更新").accessibilityLabel("立即检查更新")
                    Button { store.showSources.toggle() } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26)
                    }.buttonStyle(.plain).foregroundStyle(store.showSources ? accent : secondaryInk)
                        .help("来源与刷新设置").accessibilityLabel("来源与刷新设置")
                }
                HStack(spacing: 5) {
                    Picker("新闻范围", selection: $store.filter) {
                        ForEach(["综合", "最新", "国内", "国际", "政治", "财经", "科技", "文娱", "体育", "灾害"], id: \.self) { choice in
                            Text(choice == "综合" ? "综合 · 每分钟轮播" : choice).tag(choice)
                        }
                    }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityLabel("新闻范围")
                    Spacer()
                    Text("\(rows.count) 条").font(.system(size: 11)).foregroundStyle(secondaryInk)
                }
            }.padding(20).padding(.bottom, -3)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if !store.translationStatus.hasPrefix("中文自动翻译已开启") {
                HStack(alignment: .center, spacing: 8) {
                    Text(store.translationStatus).font(.system(size: 11)).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !store.translating {
                        Button("启用中文") { store.prepareChinese() }.font(.system(size: 11)).buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            if store.showSources { sourceSettings }
            else if rows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: store.refreshing ? "antenna.radiowaves.left.and.right" : "globe").font(.system(size: 30)).foregroundStyle(accent)
                    Text(store.refreshing ? "正在获取全球动态…" : store.enabledSources.isEmpty ? "尚未选择来源" : store.healthyCount == 0 ? "暂时无法连接来源" : "当前范围暂无新事件")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
                    Text(store.enabledSources.isEmpty ? "点右上角设置，启用一个来源。" : store.healthyCount == 0 && !store.refreshing ? "检查网络后重试；可在来源设置查看错误。" : "新闻保留三天，灾害保留七天。")
                        .font(.system(size: 12)).foregroundStyle(secondaryInk).multilineTextAlignment(.center)
                    if !store.refreshing && !store.enabledSources.isEmpty {
                        Button("重新连接") { Task { await store.refresh() } }.buttonStyle(.bordered)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows.prefix(200)) { event in
                            VStack(spacing: 0) {
                            EventRow(event: event, cached: store.errors[event.sourceID] != nil || Date().timeIntervalSince(store.feeds[event.sourceID]?.fetched ?? .distantPast) > store.interval * 3)
                            Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1).padding(.leading, 89).padding(.trailing, 20)
                            }.transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                    }.animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.92), value: Array(rows.prefix(200).map(\.id)))
                }.clipped()
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .center, spacing: 6) {
                    Circle().fill(statusColor(now: context.date)).frame(width: 5, height: 5)
                    Text(statusText).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(TimeZone.current.abbreviation() ?? "本地") · \(Int(store.interval / 60))分钟检查")
                }.font(.system(size: 10)).foregroundStyle(secondaryInk)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 350, maxWidth: .infinity, minHeight: 350, maxHeight: .infinity)
        .background(Color(red: 0.065, green: 0.085, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .preferredColorScheme(.dark)
        .translationTask(store.translationConfiguration) { session in
            await store.prepareChinese(using: session)
        }
    }
    var statusText: String {
        if store.refreshing { return "正在检查更新…" }
        if store.enabledSources.isEmpty { return "来源已停用" }
        guard let date = store.lastCheck else { return store.feeds.isEmpty ? "等待连接" : "显示上次缓存 · 正在连接" }
        let time = date.formatted(.dateTime.hour().minute())
        return "\(time) 检查 · \(store.healthyCount)/\(store.enabledSources.count) 来源可用"
    }
    func statusColor(now: Date) -> Color {
        if store.refreshing { return accent }
        if store.healthyCount == 0 || store.lastCheck == nil { return .orange }
        if now.timeIntervalSince(store.lastCheck!) > store.interval * 3 { return .orange }
        return store.healthyCount == store.enabledSources.count ? Color(red: 0.49, green: 0.8, blue: 0.68) : .orange
    }
    var sourceSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("小组件显示").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                Picker("显示模式", selection: Binding(get: { store.widgetDisplayMode }, set: { store.setWidgetDisplayMode($0) })) {
                    ForEach(NewsDisplayMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).accessibilityLabel("小组件显示模式")
                Text(store.widgetDisplayMode == .latest ? "按报道时间倒序。新报道置顶，已有条目顺次下移；没有新增时保持原位。" : "混合不同领域，按分钟计划轮换近期报道。轮播不代表新发布。")
                    .font(.system(size: 11)).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("消息来源").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                ForEach(NewsSource.all) { source in
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(isOn: Binding(get: { !store.disabled.contains(source.id) }, set: { _ in store.toggle(source) })) {
                            Text(source.name).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                        }.toggleStyle(.switch).controlSize(.small)
                        Text(source.detail).font(.system(size: 11)).foregroundStyle(secondaryInk)
                        if let error = store.errors[source.id], !store.disabled.contains(source.id) {
                            Text(error).font(.system(size: 10)).foregroundStyle(Color.orange).textSelection(.enabled)
                        } else if let fetched = store.feeds[source.id]?.fetched {
                            Text("上次成功：\(fetched.formatted(.dateTime.month().day().hour().minute()))").font(.system(size: 10)).foregroundStyle(secondaryInk)
                        }
                    }
                }
                Divider()
                Text(store.translationStatus).font(.system(size: 11)).foregroundStyle(secondaryInk)
                Button("准备中英翻译语言") { store.prepareChinese() }.buttonStyle(.bordered)
                Picker("检查间隔", selection: Binding(get: { store.interval }, set: { store.setInterval($0) })) {
                    Text("1 分钟").tag(60.0); Text("3 分钟").tag(180.0); Text("5 分钟").tag(300.0)
                }.font(.system(size: 12))
                Text("默认每分钟联网检查，翻译在后台继续处理。小组件可选最新优先或综合轮播。最新优先按报道时间排序，有新内容时平滑插入；综合轮播混合各领域的近期报道。原生组件实际切换时刻由 macOS 决定，无法保证严格每分钟更新。退出应用后组件仍按系统调度检查，也可手动刷新。")
                    .font(.system(size: 11)).lineSpacing(4).foregroundStyle(secondaryInk)
                Button("完成") { store.showSources = false }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(Color.black)
            }.padding(20)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = EventStore()
    var panel: NSWindow!
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "世界动态"
        panel.delegate = self
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
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
        menu.addItem(withTitle: "打开新闻与设置", action: #selector(show), keyEquivalent: "")
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func ensureVisible() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(panel.frame) }) { resetPosition() }
    }
    @objc func screensChanged() { ensureVisible() }
    @objc func show() { ensureVisible(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func hide() { panel.orderOut(nil) }
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
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
