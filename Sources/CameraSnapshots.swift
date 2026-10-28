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
    guard let marker = html.range(of: "ytInitialData = ") ?? html.range(of: "ytInitialData=", options: .literal) else { return [] }
    let suffix = html[marker.upperBound...]
    guard let end = suffix.range(of: ";</script>") ?? suffix.range(of: ";\n") else { return [] }
    guard let data = String(suffix[..<end.lowerBound]).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var allowed = Set<String>()
    func visit(_ object: Any) {
        if let dict = object as? [String: Any] {
            if let video = dict["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String {
                let title = video["title"] as? [String: Any] ?? [:]
                let text = ((title["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? title["simpleText"] as? String ?? "").lowercased()
                let badges = String(data: (try? JSONSerialization.data(withJSONObject: video["badges"] ?? [])) ?? Data(), encoding: .utf8) ?? ""
                let excluded = ["skylinewebcams", "worldwide", "world live", "webcam tour", "protest", "news live", "walking", "walking tour", "travel music", "digest"]
                let cameraWords = ["cam", "webcam", "实景", "實景", "即時", "交差点", "crossing", "view live", "高清直播"]
                if badges.contains("LIVE_NOW"), city.keywords.contains(where: text.contains), cameraWords.contains(where: text.contains), !excluded.contains(where: text.contains) { allowed.insert(id) }
            } else { for value in dict.values { visit(value) } }
        } else if let array = object as? [Any] { for value in array { visit(value) } }
    }
    visit(object)
    return youtubeVideoIDs(html).filter { allowed.contains($0) }
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
    let excluded = ["vs", "狼队", "王者", "游戏", "电竞", "点歌", "pk", "身高", "kpl"]
    return city.keywords.contains(where: text.contains) && scene.contains(where: text.contains) && !excluded.contains(where: text.contains)
}

struct CameraFrame: Codable, Identifiable, Sendable {
    var id: String { file }
    let file: String
    let sourceType: String
    let page: URL
    let imageURL: URL
    let fetchedAt: Date
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
    guard data.count > 5000, let source = CGImageSourceCreateWithData(data as CFData, nil),
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
    var selectionVersion: Int? = nil
}

actor CameraService {
    static let shared = CameraService()
    private var running = false
    private var searches: [String: VideoSearchCache] = [:]
    private let store: CameraSnapshotStore
    init(store: CameraSnapshotStore = .shared) {
        self.store = store
        if let data = try? Data(contentsOf: store.root.appendingPathComponent("searches.json")),
           let cached = try? JSONDecoder().decode([String: VideoSearchCache].self, from: data) { searches = cached }
    }
    func refresh(cities: [CameraCity], limit: Int = 3, budget: TimeInterval? = nil, force: Bool = false) async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        let due = cities.prefix(4).filter { city in force || store.read(city.id)?.fetchedAt.map { Date().timeIntervalSince($0) >= CameraCity.interval } ?? true }
        let deadline = budget.map { Date().addingTimeInterval($0) }
        var changed = false
        await withTaskGroup(of: Bool.self) { group in
            for city in due { group.addTask { await self.fetch(city, limit: min(3, max(1, limit)), deadline: deadline) } }
            for await result in group { changed = changed || result }
        }
        return changed
    }
    private func fetch(_ city: CameraCity, limit: Int, deadline: Date?) async -> Bool {
        let began = Date(), generation = UUID().uuidString
        let folder = store.directory(city.id).appendingPathComponent(generation)
        var frames: [CameraFrame] = [], seen = Set<String>(), lastError = "暂无可用的城市实景镜头，将自动重试"
        func remaining() -> TimeInterval { min(15, deadline.map { $0.timeIntervalSinceNow } ?? 15) }
        func save(_ url: URL, page: URL, type: String) async throws {
            guard frames.count < limit, seen.insert(url.absoluteString).inserted, remaining() > 0.2 else { return }
            let (data, response) = try await cameraRequest(url, timeout: remaining())
            guard response.mimeType?.hasPrefix("image/") == true, let jpeg = cameraJPEG(data) else { throw FeedError.invalid }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(frames.count).jpg"
            try jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
            frames.append(CameraFrame(file: generation + "/" + name, sourceType: type, page: page, imageURL: url, fetchedAt: Date()))
        }
        func bilibili(_ room: Int) async throws {
            guard frames.count < limit, remaining() > 0.2 else { return }
            let (data, _) = try await cameraRequest(bilibiliInfoURL(room), timeout: remaining())
            if let url = bilibiliKeyframe(data) { try await save(url, page: URL(string: "https://live.bilibili.com/\(room)")!, type: "B站直播截图") }
        }
        for candidate in city.candidates {
            if frames.count >= limit || remaining() < 0.2 || Task.isCancelled { break }
            do {
                switch candidate {
                case .jpeg(let image, let page):
                    if let url = safeURL(image), let link = safeURL(page) { try await save(url, page: link, type: "官方摄像头") }
                case .bilibiliRoom(let room):
                    try await bilibili(room)
                case .bilibiliSearch(let keyword):
                    for room in try await bilibiliRooms(keyword, city: city, timeout: remaining()).prefix(3) {
                        if frames.count >= limit || remaining() < 0.2 { break }
                        try? await bilibili(room)
                    }
                case .youtubeSearch(let query):
                    let ids = try await videoIDs(query, city: city, timeout: remaining())
                    for id in ids.prefix(5) {
                        if frames.count >= limit || remaining() < 0.2 { break }
                        let page = URL(string: "https://www.youtube.com/watch?v=\(id)")!
                        do { try await save(URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault_live.jpg")!, page: page, type: "YouTube直播缩略图") }
                        catch { if remaining() > 0.2 { try? await save(URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!, page: page, type: "YouTube直播缩略图") } }
                    }
                }
            } catch { lastError = error.localizedDescription }
        }
        let previous = store.read(city.id)
        let manifest = CameraManifest(checkedAt: began, fetchedAt: frames.isEmpty ? previous?.fetchedAt : Date(),
                                      frames: frames.isEmpty ? previous?.frames ?? [] : frames, error: frames.isEmpty ? lastError : nil)
        do {
            let saved = try store.write(manifest, city: city.id)
            store.prune(city.id)
            return saved && !frames.isEmpty
        } catch { NSLog("实景缓存保存失败：%@ %@", city.name, error.localizedDescription); return false }
    }
    private func bilibiliInfoURL(_ room: Int) -> URL {
        URL(string: "https://api.live.bilibili.com/room/v1/Room/get_info?room_id=\(room)")!
    }
    private func bilibiliRooms(_ keyword: String, city: CameraCity, timeout: TimeInterval) async throws -> [Int] {
        let key = "bilibili:" + keyword
        if let cached = searches[key], cached.selectionVersion == 1, Date().timeIntervalSince(cached.fetchedAt) < 21600 { return cached.ids.compactMap { Int($0) } }
        var components = URLComponents(string: "https://search.bilibili.com/live")!
        components.queryItems = [URLQueryItem(name: "keyword", value: keyword)]
        let (data, _) = try await cameraRequest(components.url!, timeout: timeout)
        var rooms: [Int] = []
        // The search page lists room links; the public room API supplies title and live state for filtering.
        for room in bilibiliRoomIDs(String(decoding: data, as: UTF8.self)).prefix(8) {
            guard let info = try? await cameraRequest(bilibiliInfoURL(room), timeout: min(8, timeout)).0,
                  bilibiliKeyframe(info) != nil, let title = bilibiliTitle(info), bilibiliSceneTitle(title, city: city) else { continue }
            rooms.append(room)
        }
        remember(key, ids: rooms.map(String.init))
        return rooms
    }
    private func remember(_ key: String, ids: [String]) {
        // Empty searches retry after ten minutes; successful searches stay cached for six hours.
        searches[key] = VideoSearchCache(fetchedAt: ids.isEmpty ? Date().addingTimeInterval(-21000) : Date(), ids: ids, selectionVersion: 1)
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(searches) { try? encoded.write(to: store.root.appendingPathComponent("searches.json"), options: .atomic) }
    }
    private func videoIDs(_ query: String, city: CameraCity, timeout: TimeInterval) async throws -> [String] {
        if let cached = searches[query], cached.selectionVersion == 1, Date().timeIntervalSince(cached.fetchedAt) < 21600 { return cached.ids }
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "sp", value: "EgJAAQ%3D%3D")]
        let (data, _) = try await cameraRequest(components.url!, timeout: timeout)
        guard let html = String(data: data, encoding: .utf8) else { throw FeedError.invalid }
        let ids = cityYouTubeIDs(html, city: city)
        remember(query, ids: ids)
        return ids
    }
}

private let cameraSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: configuration)
}()

private func cameraRequest(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
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
