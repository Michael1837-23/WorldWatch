import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum CameraCandidate: Sendable {
    case youtubeSearch(String)
    case bilibiliRoom(Int)
    case bilibiliSearch(String)
    case jpeg(String, String)
}

struct CameraCity: Identifiable, Sendable {
    let id: String
    let name: String
    let keywords: [String]
    let candidates: [CameraCandidate]
    var englishName: String {
        ["beijing": "Beijing", "shanghai": "Shanghai", "hongkong": "Hong Kong", "chongqing": "Chongqing", "tokyo": "Tokyo", "taipei": "Taipei", "newyork": "New York", "losangeles": "Los Angeles", "paris": "Paris", "london": "London"][id] ?? name
    }
    static let all: [CameraCity] = [
        .init(id: "beijing", name: "北京", keywords: ["beijing", "北京", "peking"], candidates: [.bilibiliRoom(3291055), .bilibiliSearch("北京 街景"), .bilibiliSearch("北京 实景"), .youtubeSearch("beijing city live camera")]),
        .init(id: "shanghai", name: "上海", keywords: ["shanghai", "上海"], candidates: [.youtubeSearch("shanghai bund live camera"), .youtubeSearch("Shanghai Bund live"), .bilibiliSearch("上海 街景")]),
        .init(id: "hongkong", name: "香港", keywords: ["hong kong", "hongkong", "香港", "victoria harbour"], candidates: [.jpeg("https://www.hko.gov.hk/wxinfo/aws/hko_mica/hk2/latest_HK2.jpg", "https://www.hko.gov.hk/en/wxinfo/ts/index_webcam.htm"), .youtubeSearch("hong kong victoria harbour live")]),
        .init(id: "chongqing", name: "重庆", keywords: ["chongqing", "重庆", "重慶"], candidates: [.bilibiliSearch("重庆 街景"), .bilibiliSearch("重庆 慢直播"), .bilibiliSearch("重庆 实景"), .youtubeSearch("chongqing city live camera")]),
        .init(id: "tokyo", name: "东京", keywords: ["tokyo", "shibuya", "shinjuku", "東京", "渋谷", "新宿"], candidates: [.youtubeSearch("tokyo shibuya live camera"), .youtubeSearch("tokyo shinjuku live camera")]),
        .init(id: "taipei", name: "台北", keywords: ["taipei", "台北", "臺北", "象山", "大稻埕"], candidates: [.youtubeSearch("taipei live camera"), .youtubeSearch("taipei dadaocheng live camera")]),
        .init(id: "newyork", name: "纽约", keywords: ["new york", "times square", "nyc", "brooklyn"], candidates: [.youtubeSearch("new york times square live"), .youtubeSearch("new york brooklyn bridge live camera")]),
        .init(id: "losangeles", name: "洛杉矶", keywords: ["los angeles", "venice beach", "hollywood", "lax"], candidates: [.youtubeSearch("los angeles live cam"), .youtubeSearch("los angeles venice beach live camera")]),
        .init(id: "paris", name: "巴黎", keywords: ["paris", "eiffel", "montparnasse"], candidates: [.youtubeSearch("paris eiffel live cam"), .youtubeSearch("paris montparnasse live webcam")]),
        .init(id: "london", name: "伦敦", keywords: ["london", "abbey road"], candidates: [
            .jpeg("https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/00001.04502.jpg", "https://tfl.gov.uk/traffic/status/"),
            .jpeg("https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/00001.06502.jpg", "https://tfl.gov.uk/traffic/status/"), .youtubeSearch("london live camera")])
    ]
    static let defaults = ["beijing", "tokyo", "newyork", "london"]
    static var selected: [CameraCity] {
        let ids = WorldPreferences.shared.stringArray(forKey: "cameraCities") ?? defaults
        var seen = Set<String>()
        return ids.compactMap { id in seen.insert(id).inserted ? all.first { $0.id == id } : nil }.prefix(4).map { $0 }
    }
    static var interval: TimeInterval {
        get {
            let value = WorldPreferences.shared.double(forKey: "cameraInterval")
            return [300.0, 600, 900, 1800].contains(value) ? value : 600
        }
        set { WorldPreferences.shared.set(newValue, forKey: "cameraInterval") }
    }
}

func cameraRotationIndex(entry: Int, city: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((entry + city) % count + count) % count
}

func youtubeVideoIDs(_ html: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #""videoId"\s*:\s*"([A-Za-z0-9_-]{11})""#)
    var seen = Set<String>()
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
        guard let range = Range(match.range(at: 1), in: html) else { return nil }
        let id = String(html[range])
        return seen.insert(id).inserted ? id : nil
    }
}

func cityYouTubeIDs(_ html: String, city: CameraCity) -> [String] {
    cityYouTubeSources(html, city: city).map(\.id).map { String($0.dropFirst("youtube:".count)) }
}

func cityYouTubeSources(_ html: String, city: CameraCity) -> [CameraSource] {
    guard let marker = html.range(of: "ytInitialData = ") ?? html.range(of: "ytInitialData=", options: .literal) else { return [] }
    let suffix = html[marker.upperBound...]
    guard let end = suffix.range(of: ";</script>") ?? suffix.range(of: ";\n") else { return [] }
    guard let data = String(suffix[..<end.lowerBound]).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var allowed: [String: CameraSource] = [:]
    func visit(_ object: Any) {
        if let dict = object as? [String: Any] {
            if let video = dict["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String {
                let title = video["title"] as? [String: Any] ?? [:]
                let text = (title["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? title["simpleText"] as? String ?? ""
                let badges = String(data: (try? JSONSerialization.data(withJSONObject: video["badges"] ?? [])) ?? Data(), encoding: .utf8) ?? ""
                if badges.contains("LIVE_NOW"), !text.lowercased().contains("skylinewebcams"), youtubeSceneTitle(text, city: city) {
                    allowed[id] = .youtube(id, title: text)
                }
            } else { for value in dict.values { visit(value) } }
        } else if let array = object as? [Any] { for value in array { visit(value) } }
    }
    visit(object)
    return youtubeVideoIDs(html).compactMap { allowed[$0] }
}

func bilibiliKeyframe(_ data: Data) -> URL? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let info = root["data"] as? [String: Any], info["live_status"] as? Int == 1,
          let value = info["keyframe"] as? String, var url = URLComponents(string: value),
          ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
    url.scheme = "https"
    return url.url
}

func bilibiliRoomIDs(_ html: String) -> [Int] {
    let regex = try! NSRegularExpression(pattern: #"live\.bilibili\.com/(?:h5/)?([0-9]{3,12})"#)
    var seen = Set<Int>()
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
        guard let range = Range(match.range(at: 1), in: html), let id = Int(html[range]) else { return nil }
        return seen.insert(id).inserted ? id : nil
    }
}

func bilibiliTitle(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let info = root["data"] as? [String: Any] else { return nil }
    return info["title"] as? String
}

/// Search results mix in esports and chat rooms named after the city; keep only street or scenery cameras.
func bilibiliSceneTitle(_ title: String, city: CameraCity) -> Bool {
    let text = title.lowercased()
    let scene = ["街景", "实景", "實景", "慢直播", "窗外", "夜景", "江景", "实时", "風景", "风景", "镜头", "鏡頭"]
    let excluded = ["vs", "狼队", "王者", "游戏", "电竞", "点歌", "pk", "身高", "kpl", "聊天", "陪聊", "唱歌"]
    return ([city.name] + city.keywords).contains(where: text.contains) && scene.contains(where: text.contains) && !excluded.contains(where: text.contains)
}

struct CameraFrame: Codable, Identifiable, Sendable {
    var id: String { file }
    let file: String
    let sourceType: String
    let page: URL
    let imageURL: URL
    let fetchedAt: Date
    var sourceID: String? = nil
    var platform: CameraPlatform? = nil
}

struct CameraManifest: Codable, Sendable {
    let checkedAt: Date
    var fetchedAt: Date?
    var frames: [CameraFrame]
    var error: String?
}

struct CameraSnapshotStore: Sendable {
    let root: URL
    static var shared: CameraSnapshotStore {
        .init(root: NewsSnapshotStore.shared.fileURL.deletingLastPathComponent().appendingPathComponent("Cameras"))
    }
    func directory(_ city: String) -> URL { root.appendingPathComponent(city) }
    func read(_ city: String) -> CameraManifest? {
        guard let data = try? Data(contentsOf: directory(city).appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(CameraManifest.self, from: data)
    }
    func imageURL(city: String, frame: CameraFrame) -> URL { directory(city).appendingPathComponent(frame.file) }
    @discardableResult func write(_ manifest: CameraManifest, city: String) throws -> Bool {
        let folder = directory(city)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        if let previous = read(city), previous.checkedAt > manifest.checkedAt { return false }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        return true
    }
    func prune(_ city: String, now: Date = Date()) {
        let folder = directory(city)
        let current = Set(read(city)?.frames.map { $0.file.components(separatedBy: "/")[0] } ?? [])
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard !current.contains(item.lastPathComponent), let info = try? item.resourceValues(forKeys: keys), info.isDirectory == true,
                  let created = info.creationDate, now.timeIntervalSince(created) > 7200 else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }
}

func cameraJPEG(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
}

private struct VideoSearchCache: Codable {
    let fetchedAt: Date
    let ids: [String]
}

extension CameraSnapshotStore {
    func sources() -> [String: [CameraSource]] { readState("sources.json") ?? [:] }
    func health() -> [String: CameraHealth] { readState("health.json") ?? [:] }
    private func readState<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func writeState<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".state.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    func pool(_ city: CameraCity) -> [CameraSource] {
        var result = sources()[city.id] ?? []
        for source in city.fixedSources where !result.contains(where: { $0.id == source.id }) { result.append(source) }
        return result
    }
}

typealias CameraTransport = @Sendable (URL, TimeInterval) async throws -> (Data, HTTPURLResponse)

actor CameraService {
    static let shared = CameraService()
    private var running = false
    private var searches: [String: VideoSearchCache] = [:]
    private var pools: [String: [CameraSource]] = [:]
    private var health: [String: CameraHealth] = [:]
    private let store: CameraSnapshotStore
    private let request: CameraTransport
    init(store: CameraSnapshotStore = .shared, request: @escaping CameraTransport = { url, timeout in try await cameraRequest(url, timeout: timeout) }) {
        self.store = store; self.request = request
    }
    func refresh(cities: [CameraCity], limit: Int = 3, budget: TimeInterval? = nil, force: Bool = false,
                 resetCooldown: Bool = false, diagnostic: Bool = false) async -> Bool {
        guard !running else { return false }
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let descriptor = open(store.root.appendingPathComponent(".refresh.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return false }
        running = true
        defer { running = false; flock(descriptor, LOCK_UN); close(descriptor) }
        pools = store.sources(); health = store.health()
        if let data = try? Data(contentsOf: store.root.appendingPathComponent("searches.json")),
           let cached = try? JSONDecoder().decode([String: VideoSearchCache].self, from: data) { searches = cached }
        let due = cities.prefix(4).filter { city in
            force || store.read(city.id).map { Date().timeIntervalSince($0.checkedAt) >= CameraCity.interval } ?? true
        }
        if resetCooldown {
            for city in due { for source in store.pool(city) {
                health[source.id]?.cooldownUntil = nil
            } }
        }
        let deadline = budget.map { Date().addingTimeInterval($0) }
        var changed = false
        await withTaskGroup(of: Bool.self) { group in
            for city in due { group.addTask { await self.fetch(city, limit: min(3, max(1, limit)), deadline: deadline, diagnostic: diagnostic, recheck: resetCooldown) } }
            for await result in group { changed = changed || result }
        }
        do {
            try store.writeState(pools, name: "sources.json")
            try store.writeState(health, name: "health.json")
            try store.writeState(searches, name: "searches.json")
        } catch { NSLog("实景来源记录保存失败：%@", error.localizedDescription) }
        return changed
    }
    private func fetch(_ city: CameraCity, limit: Int, deadline: Date?, diagnostic: Bool, recheck: Bool) async -> Bool {
        let deadline = deadline ?? Date().addingTimeInterval(90)
        let began = Date(), generation = UUID().uuidString
        let folder = store.directory(city.id).appendingPathComponent(generation)
        let previous = store.read(city.id)
        var frames: [CameraFrame] = [], selected: [CameraSource] = [], attempted = Set<String>()
        var lastError = "暂无可用画面，来源可能未开播或处于冷却期"
        func remaining() -> TimeInterval { max(0, min(15, deadline.timeIntervalSinceNow)) }
        for source in city.fixedSources {
            if var cached = pools[city.id]?.first(where: { $0.id == source.id }) {
                if source.platform == .skyline || source.platform == .official {
                    cached.page = source.page; cached.imageURL = source.imageURL; cached.title = source.title
                }
                if source.platform == .youtube { cached.channel = source.channel }
                merge(cached, city: city.id)
            } else { merge(source, city: city.id) }
        }
        // Reuse the persisted pool first; only pay search latency when it cannot fill this round.
        var discovered = false
        while remaining() > 0.2 && !Task.isCancelled {
            let candidates = (pools[city.id] ?? []).filter { !attempted.contains($0.id) }
            let ranked = rankedCameraSources(candidates, health: health, disabled: CameraOptions.disabled,
                                             skyline: CameraOptions.skyline, selected: selected)
            guard let source = ranked.first else {
                if !discovered { discovered = true; await discover(city, deadline: deadline); continue }
                break
            }
            if frames.count >= limit && !diagnostic { break }
            attempted.insert(source.id)
            // App and Widget share a process lock and request timestamps. Skyline never bypasses the user interval.
            if let last = health[source.id]?.lastFetched, Date().timeIntervalSince(last) < CameraCity.interval,
               (!recheck && !diagnostic) || source.platform == .skyline {
                if let frame = previous?.frames.first(where: { $0.sourceID == source.id }),
                   [.live, .unverified].contains(health[source.id]?.state ?? .unverified) {
                    if frames.count < limit {
                        frames.append(.init(file: frame.file, sourceType: frame.sourceType, page: source.page,
                                            imageURL: frame.imageURL, fetchedAt: frame.fetchedAt, sourceID: frame.sourceID, platform: frame.platform))
                        selected.append(source)
                    }
                }
                continue
            }
            var pending = health[source.id] ?? CameraHealth()
            pending.lastFetched = Date(); health[source.id] = pending
            do { try store.writeState(health, name: "health.json") }
            catch { lastError = "无法保存来源检测记录"; break }
            do {
                let (resolved, data, response) = try await image(source, city: city, deadline: deadline)
                var record = source.platform == .youtube && resolved.page != source.page ? CameraHealth() : health[source.id] ?? CameraHealth()
                guard response.mimeType?.hasPrefix("image/") == true, let fingerprint = CameraFingerprint.make(data),
                      let jpeg = cameraJPEG(data) else { throw FeedError.invalid }
                record.observe(fingerprint, modified: cameraHTTPDate(response.value(forHTTPHeaderField: "Last-Modified")), now: Date())
                health[source.id] = record
                if diagnostic { print("  \(city.name) · \(resolved.platform.title) · \(source.id) · \(record.state.title) · \(data.count) bytes · Last-Modified: \(response.value(forHTTPHeaderField: "Last-Modified") ?? "无")") }
                guard [.live, .unverified].contains(record.state) else { lastError = record.reason ?? record.state.title; continue }
                guard source.platform != .youtube || !selected.contains(where: { $0.page == resolved.page }) else { continue }
                // A user can disable a source while its network request is in flight.
                guard !CameraOptions.disabled.contains(source.id), CameraOptions.skyline || source.platform != .skyline else { continue }
                merge(resolved, city: city.id)
                if frames.count < limit {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = "\(frames.count).jpg"
                    try jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
                    frames.append(.init(file: generation + "/" + name, sourceType: resolved.platform.title, page: resolved.page,
                                        imageURL: resolved.imageURL, fetchedAt: Date(), sourceID: source.id, platform: resolved.platform))
                    selected.append(resolved)
                }
            } catch {
                var record = health[source.id] ?? CameraHealth()
                if let offline = error as? CameraOffline { record.offline(now: Date(), reason: offline.reason) }
                else { record.fail(now: Date(), reason: cameraErrorDescription(error)) }
                health[source.id] = record; lastError = record.reason ?? "抓取失败"
                if diagnostic { print("  \(city.name) · \(source.platform.title) · \(source.id) · \(record.state.title) · \(lastError)") }
            }
        }
        // Low-health pools may refresh successful search caches every 30 minutes, even if three provisional images exist.
        if !discovered && remaining() > 0.2 { await discover(city, deadline: deadline) }
        let retained = previous?.frames.filter { frame in
            guard let id = frame.sourceID else { return CameraOptions.skyline || frame.platform != .skyline }
            return !CameraOptions.disabled.contains(id) && (CameraOptions.skyline || frame.platform != .skyline)
        } ?? []
        let manifest = CameraManifest(checkedAt: began, fetchedAt: frames.isEmpty ? previous?.fetchedAt : frames.map(\.fetchedAt).max(),
                                      frames: frames.isEmpty ? retained : frames, error: frames.isEmpty ? lastError : nil)
        do {
            let saved = try store.write(manifest, city: city.id)
            store.prune(city.id)
            return saved && !frames.isEmpty
        } catch { NSLog("实景缓存保存失败：%@ %@", city.name, error.localizedDescription); return false }
    }
    private func merge(_ source: CameraSource, city: String) {
        var sources = pools[city] ?? []
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source }
        else {
            if sources.count >= 48 {
                let fixed = Set(CameraCity.all.first { $0.id == city }?.fixedSources.map(\.id) ?? [])
                guard let index = sources.lastIndex(where: { !fixed.contains($0.id) && health[$0.id]?.state != .live }) else { return }
                sources.remove(at: index)
            }
            sources.append(source)
        }
        pools[city] = sources
    }
    private func image(_ source: CameraSource, city: CameraCity, deadline: Date?) async throws -> (CameraSource, Data, HTTPURLResponse) {
        func remaining() throws -> TimeInterval {
            let time = min(15, deadline.map { $0.timeIntervalSinceNow } ?? 15)
            guard time > 0.2 else { throw URLError(.timedOut) }; return time
        }
        var resolved = source
        if source.platform == .bilibili {
            let room = source.id.replacingOccurrences(of: "bilibili:", with: "")
            let (data, _) = try await request(URL(string: "https://api.live.bilibili.com/room/v1/Room/get_info?room_id=\(room)")!, try remaining())
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["code"] as? Int == 0,
                  let info = root["data"] as? [String: Any], let status = info["live_status"] as? Int else { throw FeedError.invalid }
            guard status == 1 else { throw CameraOffline(reason: "直播间当前未开播") }
            guard let url = bilibiliKeyframe(data) else { throw CameraOffline(reason: "直播间没有可用截图") }
            guard let title = bilibiliTitle(data), bilibiliSceneTitle(title, city: city) else { throw CameraOffline(reason: "直播间已更换为其他内容") }
            resolved.imageURL = url; resolved.title = title
        } else if source.platform == .youtube {
            var id = URLComponents(url: source.page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value ?? String(source.id.dropFirst("youtube:".count))
            let existing = try? await request(URL(string: "https://www.youtube.com/watch?v=\(id)")!, try remaining())
            var live = existing.flatMap { youtubeDeclaredLive(String(decoding: $0.0, as: UTF8.self)) }
            if let existing, let title = youtubePlayerTitle(String(decoding: existing.0, as: UTF8.self)) {
                guard ([city.name] + city.keywords).contains(where: title.lowercased().contains) else { throw CameraOffline(reason: "直播内容已不属于该城市") }
                resolved.title = title
            }
            // Multi-camera channels may redirect /live to a different city. Keep a known live camera; relocate only ended streams.
            if live != true, let channel = source.channel,
               let (data, _) = try? await request(channel, try remaining()),
               let current = youtubeLiveVideoID(String(decoding: data, as: UTF8.self)) {
                let (pageData, _) = try await request(URL(string: "https://www.youtube.com/watch?v=\(current)")!, try remaining())
                let html = String(decoding: pageData, as: UTF8.self)
                if let title = youtubePlayerTitle(html), youtubeSceneTitle(title, city: city) {
                    id = current; live = youtubeDeclaredLive(html); resolved.title = title
                }
            }
            guard let live else { throw FeedError.invalid }
            guard live else { throw CameraOffline(reason: "YouTube 当前未直播") }
            resolved.page = URL(string: "https://www.youtube.com/watch?v=\(id)")!
            resolved.imageURL = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault_live.jpg")!
        }

        do {
            let (data, response) = try await request(resolved.imageURL, try remaining())
            guard response.mimeType?.hasPrefix("image/") == true, CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw FeedError.invalid }
            return (resolved, data, response)
        } catch {
            guard source.platform == .youtube else { throw error }
            resolved.imageURL = URL(string: resolved.imageURL.absoluteString.replacingOccurrences(of: "hqdefault_live.jpg", with: "hqdefault.jpg"))!
            let (data, response) = try await request(resolved.imageURL, try remaining())
            return (resolved, data, response)
        }
    }
    private func discover(_ city: CameraCity, deadline: Date?) async {
        let lowHealth = (pools[city.id] ?? []).filter { source in
            health[source.id]?.state == .live && !CameraOptions.disabled.contains(source.id) &&
            (CameraOptions.skyline || source.platform != .skyline) && !(health[source.id]?.cooldownUntil.map { $0 > Date() } ?? false)
        }.count < 2
        let extra: [CameraCandidate] = city.candidates.isEmpty ? [] : ["街景", "实景", "慢直播", "夜景"].map { CameraCandidate.bilibiliSearch(city.name + " " + $0) }
        for candidate in city.candidates + extra {
            if Task.isCancelled { return }
            let timeout = min(10, deadline.map { $0.timeIntervalSinceNow } ?? 10)
            guard timeout > 0.2 else { return }
            let key: String, url: URL, youtube: Bool
            switch candidate {
            case .youtubeSearch(let query):
                key = "youtube:" + query; youtube = true
                var components = URLComponents(string: "https://www.youtube.com/results")!
                components.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "sp", value: "EgJAAQ==")]
                url = components.url!
            case .bilibiliSearch(let query):
                key = "bilibili:" + query; youtube = false
                var components = URLComponents(string: "https://search.bilibili.com/live")!
                components.queryItems = [URLQueryItem(name: "keyword", value: query)]; url = components.url!
            default: continue
            }
            if let cached = searches[key] {
                let age = Date().timeIntervalSince(cached.fetchedAt)
                let interval: TimeInterval = cached.ids.isEmpty ? 600 : lowHealth ? 1800 : 21600
                if age < interval { continue }
            }
            // Record attempts too: failures must not cause a search on every widget refresh.
            searches[key] = .init(fetchedAt: Date(), ids: [])
            do {
                let (data, _) = try await request(url, timeout)
                let html = String(decoding: data, as: UTF8.self)
                if youtube {
                    let ids = cityYouTubeIDs(html, city: city)
                    searches[key] = .init(fetchedAt: Date(), ids: ids)
                    for source in cityYouTubeSources(html, city: city).prefix(8) { merge(source, city: city.id) }
                } else {
                    var found: [String] = []
                    for room in bilibiliRoomIDs(html).prefix(8) {
                        let remaining = min(8, deadline.map { $0.timeIntervalSinceNow } ?? 8)
                        guard remaining > 0.2 else { break }
                        guard let info = try? await request(URL(string: "https://api.live.bilibili.com/room/v1/Room/get_info?room_id=\(room)")!, remaining).0,
                              let image = bilibiliKeyframe(info), let title = bilibiliTitle(info), bilibiliSceneTitle(title, city: city) else { continue }
                        let source = CameraSource.bilibili(room, title: title, image: image)
                        found.append(source.id); merge(source, city: city.id)
                    }
                    searches[key] = .init(fetchedAt: Date(), ids: found)
                }
            } catch { /* A persisted pool remains usable when discovery fails. */ }
        }
    }
}

private struct CameraOffline: Error { let reason: String }

private let cameraSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: configuration)
}()

func cameraRequest(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
    guard timeout > 0 else { throw URLError(.timedOut) }
    return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
        group.addTask {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("en", forHTTPHeaderField: "Accept-Language")
            let (data, response) = try await cameraSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 8_000_000 else { throw FeedError.invalid }
            return (data, http)
        }
        group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); throw URLError(.timedOut) }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
