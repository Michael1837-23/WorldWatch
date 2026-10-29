import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

enum CameraPlatform: String, Codable, Sendable {
    case youtube, bilibili, skyline, official
    var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .bilibili: return "B 站"
        case .skyline: return "SkylineWebcams"
        case .official: return "官方"
        }
    }
}

struct CameraSource: Identifiable, Codable, Sendable {
    let id: String
    let platform: CameraPlatform
    var title: String
    var imageURL: URL
    var page: URL
    var channel: URL? = nil
    static func youtube(_ id: String, title: String, channel: String? = nil) -> CameraSource {
        .init(id: "youtube:" + id, platform: .youtube, title: title,
              imageURL: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault_live.jpg")!,
              page: URL(string: "https://www.youtube.com/watch?v=\(id)")!, channel: channel.flatMap(URL.init(string:)))
    }
    static func bilibili(_ room: Int, title: String, image: URL? = nil) -> CameraSource {
        .init(id: "bilibili:\(room)", platform: .bilibili, title: title,
              imageURL: image ?? URL(string: "https://api.live.bilibili.com/room/v1/Room/get_info?room_id=\(room)")!,
              page: URL(string: "https://live.bilibili.com/\(room)")!)
    }
    static func skyline(_ id: Int, title: String, path: String) -> CameraSource {
        .init(id: "skyline:\(id)", platform: .skyline, title: title,
              imageURL: URL(string: "https://cdn.skylinewebcams.com/live\(id).jpg")!,
              page: URL(string: "https://www.skylinewebcams.com" + path)!)
    }
}

enum CameraSourceState: String, Codable, Sendable {
    case live, unverified, staticCover, offline, failing
    var title: String {
        switch self {
        case .live: return "实时"
        case .unverified: return "待验证"
        case .staticCover: return "静态封面"
        case .offline: return "未开播"
        case .failing: return "失败"
        }
    }
}

enum CameraThresholds {
    static let comparisonInterval: TimeInterval = 240
    static let maximumImageAge: TimeInterval = 7200
    static let staticCooldown: TimeInterval = 21600
    static let offlineCooldown: TimeInterval = 3600
    static let failureBackoff: [TimeInterval] = [600, 1800, 7200, 21600]
    static let minimumBytes = 5000
    static let minimumDimension = 200
    static let minimumDeviation = 3.0
    static let hashDistance = 2
    static let unchangedLimit = 2
}

struct CameraFingerprint: Sendable {
    let hash: UInt64
    let sha256: String
    let deviation: Double
    let longestSide: Int
    let bytes: Int
    // 32×32 intensity samples distinguish small scene changes that an 8-row dHash can miss.
    let samples: Data
    static func make(_ data: Data) -> CameraFingerprint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        guard let hashPixels = grayscale(image, width: 9, height: 8),
              let pixels = grayscale(image, width: 32, height: 32) else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 {
            if hashPixels[y * 9 + x] > hashPixels[y * 9 + x + 1] { hash |= UInt64(1) << (y * 8 + x) }
        } }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        let variance = pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(pixels.count)
        return .init(hash: hash, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     deviation: sqrt(variance), longestSide: max(image.width, image.height), bytes: data.count, samples: Data(pixels))
    }
    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }
}

struct CameraHealth: Codable, Sendable {
    var lastFetched: Date? = nil
    var lastChanged: Date? = nil
    var fingerprint: UInt64? = nil
    var sha256: String? = nil
    var unchangedCount = 0
    var failures = 0
    var state: CameraSourceState = .unverified
    var cooldownUntil: Date? = nil
    var lastComparedAt: Date? = nil
    var samples: Data? = nil
    var bytes: Int? = nil
    var lastModified: Date? = nil
    var reason: String? = nil

    mutating func fail(now: Date, reason: String) {
        lastFetched = now; failures += 1; state = .failing; self.reason = reason
        cooldownUntil = now.addingTimeInterval(CameraThresholds.failureBackoff[min(failures - 1, CameraThresholds.failureBackoff.count - 1)])
    }
    mutating func offline(now: Date, reason: String) {
        lastFetched = now; failures = 0; state = .offline; self.reason = reason
        cooldownUntil = now.addingTimeInterval(CameraThresholds.offlineCooldown)
    }
    mutating func observe(_ image: CameraFingerprint, modified: Date?, etag: String? = nil, now: Date) {
        let previousModified = lastModified
        lastFetched = now; bytes = image.bytes; lastModified = modified; failures = 0
        if image.longestSide < CameraThresholds.minimumDimension || image.bytes < CameraThresholds.minimumBytes {
            offline(now: now, reason: "图片过小，可能为离线占位"); return
        }
        if image.deviation < CameraThresholds.minimumDeviation {
            offline(now: now, reason: "画面接近纯色"); return
        }
        if let modified, now.timeIntervalSince(modified) > CameraThresholds.maximumImageAge {
            offline(now: now, reason: "上游图片超过两小时未更新"); return
        }
        // i.ytimg.com tags uploaded custom thumbnails with their Unix upload time; auto-refreshed live frames carry small counters.
        if let uploaded = cameraUploadDate(etag: etag), now.timeIntervalSince(uploaded) > CameraThresholds.maximumImageAge {
            state = .staticCover; reason = "缩略图为直播封面，不是实时画面"; unchangedCount = CameraThresholds.unchangedLimit
            cooldownUntil = now.addingTimeInterval(CameraThresholds.staticCooldown); return
        }
        cooldownUntil = nil; reason = nil
        guard let previous = fingerprint, let compared = lastComparedAt else {
            fingerprint = image.hash; sha256 = image.sha256; samples = image.samples; lastComparedAt = now
            state = .unverified; return
        }
        guard now.timeIntervalSince(compared) >= CameraThresholds.comparisonInterval else { return }
        // Same Last-Modified means the CDN served its cached copy (Skyline caches 18 minutes), not that the scene froze.
        if let modified, modified == previousModified { return }
        let distance = (previous ^ image.hash).nonzeroBitCount
        // A changed byte digest alone can be JPEG metadata. Require actual pixel noise when dHash barely moves.
        let pixelChange: Bool = samples.map { old in
            guard old.count == image.samples.count else { return false }
            let changed = zip(old, image.samples).filter { abs(Int($0) - Int($1)) >= 2 }.count
            return changed >= 4 && changed < image.samples.count
        } ?? false
        let unchanged = sha256 == image.sha256 || (distance <= CameraThresholds.hashDistance && !pixelChange)
        fingerprint = image.hash; sha256 = image.sha256; samples = image.samples; lastComparedAt = now
        if unchanged {
            unchangedCount += 1
            if unchangedCount >= CameraThresholds.unchangedLimit {
                state = .staticCover; reason = "连续两次比较未发现画面变化"
                cooldownUntil = now.addingTimeInterval(CameraThresholds.staticCooldown)
            } else if state != .live { state = .unverified }
        } else {
            unchangedCount = 0; lastChanged = now; state = .live
        }
    }
}

func rankedCameraSources(_ sources: [CameraSource], health: [String: CameraHealth], disabled: Set<String> = [],
                         skyline: Bool = true, now: Date = Date(), selected: [CameraSource] = []) -> [CameraSource] {
    let available = sources.filter { source in
        !disabled.contains(source.id) && (skyline || source.platform != .skyline) &&
        !(health[source.id]?.cooldownUntil.map { $0 > now } ?? false)
    }.sorted { a, b in
        // Usable cameras rotate: the one fetched longest ago goes first, so each round shows a different set
        // and newly found sources get checked. Covers, offline and failing sources whose cooldown ended retry last.
        let left = health[a.id] ?? CameraHealth(), right = health[b.id] ?? CameraHealth()
        let leftRank = [.live, .unverified].contains(left.state) ? 0 : 1
        let rightRank = [.live, .unverified].contains(right.state) ? 0 : 1
        if leftRank != rightRank { return leftRank < rightRank }
        if left.lastFetched != right.lastFetched { return (left.lastFetched ?? .distantPast) < (right.lastFetched ?? .distantPast) }
        return a.id < b.id
    }
    guard let platform = selected.first?.platform, selected.filter({ $0.platform == platform }).count >= 2,
          available.contains(where: { $0.platform != platform }) else { return available }
    return available.filter { $0.platform != platform } + available.filter { $0.platform == platform }
}

func cameraUploadDate(etag: String?) -> Date? {
    guard let digits = etag?.trimmingCharacters(in: CharacterSet(charactersIn: "W/\" ")), digits.count == 10,
          let seconds = TimeInterval(digits), seconds > 1_000_000_000 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

func cameraHTTPDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

func cameraErrorDescription(_ error: Error) -> String {
    if let url = error as? URLError {
        switch url.code {
        case .timedOut: return "连接超时，将稍后重试"
        case .notConnectedToInternet, .networkConnectionLost: return "网络连接不可用"
        case .cancelled: return "本轮检测已取消"
        default: return "无法连接来源，将稍后重试"
        }
    }
    return "来源返回的内容无效，将稍后重试"
}

func youtubeLiveVideoID(_ html: String) -> String? {
    // Canonical and player details identify this stream; recommendations contain unrelated videoIds.
    let patterns = [#"<link\b[^>]*rel=["']canonical["'][^>]*href=["']https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})"#,
                    #"<link\b[^>]*href=["']https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})[^>]*rel=["']canonical"#,
                    #""videoDetails"\s*:\s*\{\s*"videoId"\s*:\s*"([A-Za-z0-9_-]{11})""#]
    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) { return String(html[range]) }
    }
    return nil
}

func youtubeDeclaredLive(_ html: String) -> Bool? {
    let regex = try! NSRegularExpression(pattern: #""isLiveNow"\s*:\s*(true|false)"#)
    if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
       let range = Range(match.range(at: 1), in: html) { return html[range] == "true" }
    if html.contains("BADGE_STYLE_TYPE_LIVE_NOW") { return true }
    return nil
}

func youtubePlayerTitle(_ html: String) -> String? {
    let pattern = #""videoDetails"\s*:\s*\{[\s\S]*?"title"\s*:\s*("(?:[^"\\]|\\.)*")"#
    let regex = try! NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
          let range = Range(match.range(at: 1), in: html) else { return nil }
    return try? JSONDecoder().decode(String.self, from: Data(html[range].utf8))
}

func youtubeSceneTitle(_ title: String, city: CameraCity) -> Bool {
    let text = title.lowercased()
    let camera = ["cam", "webcam", "实景", "實景", "即時", "交差点", "crossing", "view live", "高清直播", "ライブカメラ"]
    let excluded = ["worldwide", "world live", "webcam tour", "protest", "news live", "walking", "travel music", "digest"]
    return ([city.name] + city.keywords).contains(where: text.contains) && camera.contains(where: text.contains) && !excluded.contains(where: text.contains)
}

func skylineSources(_ html: String) -> [CameraSource] {
    let pattern = #"<a\b[^>]*href=["']((?:https://www\.skylinewebcams\.com)?/?en/webcam/[^"']+/[^"']+/[^"']+/[^"']+\.html)["'][^>]*>([\s\S]*?)</a>"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let image = try! NSRegularExpression(pattern: #"(?:https?:)?//cdn\.skylinewebcams\.com/live([0-9]+)\.(?:jpg|webp)"#)
    var seen = Set<String>()
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
        guard let link = Range(match.range(at: 1), in: html), let body = Range(match.range(at: 2), in: html) else { return nil }
        let content = String(html[body])
        guard let photo = image.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let number = Range(photo.range(at: 1), in: content), let id = Int(content[number]), seen.insert(String(id)).inserted else { return nil }
        let title = content.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let relative = String(html[link]).replacingOccurrences(of: "https://www.skylinewebcams.com", with: "")
        let path = relative.hasPrefix("/") ? relative : "/" + relative
        return .skyline(id, title: title.isEmpty ? "城市镜头 \(id)" : title, path: path)
    }
}

enum CameraOptions {
    static func allows(_ frame: CameraFrame) -> Bool {
        (frame.sourceID.map { !disabled.contains($0) } ?? true) && (skyline || frame.platform != .skyline)
    }
    static var disabled: Set<String> {
        get { Set(WorldPreferences.shared.stringArray(forKey: "disabledCameras") ?? []) }
        set { WorldPreferences.shared.set(Array(newValue), forKey: "disabledCameras") }
    }
    static var skyline: Bool {
        get { WorldPreferences.enabled("cameraSkyline") }
        set { WorldPreferences.shared.set(newValue, forKey: "cameraSkyline") }
    }
}

// Fixed candidates are verified public pages; health is always determined from current images.
extension CameraCity {
    var fixedSources: [CameraSource] {
        guard !candidates.isEmpty else { return [] }
        var sources = CameraFixedSources.byCity[id] ?? []
        for candidate in candidates {
            switch candidate {
            case .jpeg(let image, let page):
                if let imageURL = safeURL(image), let link = safeURL(page) {
                    sources.append(.init(id: "official:" + imageURL.lastPathComponent, platform: .official,
                        title: name + (id == "london" ? " TfL 道路镜头 " + imageURL.deletingPathExtension().lastPathComponent : " 天文台维港"), imageURL: imageURL, page: link))
                }
            case .bilibiliRoom(let room): sources.append(.bilibili(room, title: name + "窗外街景"))
            default: break
            }
        }
        return sources
    }
}

private enum CameraFixedSources {
    static let byCity: [String: [CameraSource]] = [
        "beijing": [],
        "shanghai": [
            .youtube("mizy6R7JGdM", title: "🔴【上海即時影像】東方明珠 24小時高清直播｜黃浦江與外白渡橋全景｜Shanghai Live Stream", channel: "https://www.youtube.com/channel/UCWtgtd5245OHw4I2wL9K8jA/live"),
            .skyline(5216, title: "Skyline of Shanghai", path: "/en/webcam/china/shanghai/shanghai/skyline-of-shanghai.html")
        ],
        "hongkong": [
            .init(id: "official:hko-hko", platform: .official, title: "香港天文台 · 尖沙咀向东", imageURL: URL(string: "https://www.hko.gov.hk/wxinfo/aws/hko_mica/hko/latest_HKO.jpg")!, page: URL(string: "https://www.hko.gov.hk/en/wxinfo/ts/index_webcam.htm")!),
            .init(id: "official:hko-cp1", platform: .official, title: "香港天文台 · 中环维多利亚港", imageURL: URL(string: "https://www.hko.gov.hk/wxinfo/aws/hko_mica/cp1/latest_CP1.jpg")!, page: URL(string: "https://www.hko.gov.hk/en/wxinfo/ts/index_webcam.htm")!),
            .init(id: "official:hko-vpb", platform: .official, title: "香港天文台 · 太平山向东北", imageURL: URL(string: "https://www.hko.gov.hk/wxinfo/aws/hko_mica/vpb/latest_VPB.jpg")!, page: URL(string: "https://www.hko.gov.hk/en/wxinfo/ts/index_webcam.htm")!),
            .youtube("ScBtCcGZMDk", title: "🔴 HONGKONG LIVE 24/7 | 香港即時直播", channel: "https://www.youtube.com/channel/UCXot04MO0C8-csVPqFOjAtQ/live"),
            .youtube("6YYmUo2TgJ0", title: "香港維多利亞港東面直播 Live cam of Victoria Harbour – Eastern Side in Hong Kong", channel: "https://www.youtube.com/channel/UCAyQys2w6IkGrqkJyHe-4sQ/live"),
            .youtube("rOUKaSPbG7c", title: "🔴【LIVE】 Hong Kong&#39;s ONLY 24/7 LIVE camera from The Peak with Relaxing Music BGM 24/7 實景直播 抒情背景音樂🎧", channel: "https://www.youtube.com/channel/UCNcY1o1xGgTX_19w0cXes9g/live"),
            .skyline(6117, title: "Hong Kong - Kwai Tsing Container Terminal", path: "/en/webcam/china/hong-kong/hong-kong/kwai-tsing-container-terminal.html"),
            .skyline(5729, title: "Panorama of Hong Kong", path: "/en/webcam/china/hong-kong/hong-kong/panorama.html")
        ],
        "chongqing": [],
        "tokyo": [
            .youtube("GLQhbRGv5qU", title: "【LIVE】Tokyo Shinjuku JR Live Cam東京 新宿 鉄道 ライブカメラ OmoideYokocho 2024", channel: "https://www.youtube.com/channel/UC1kDVgEX2DsE295Bkum_K9Q/live"),
            .youtube("6dp-bvQ7RWo", title: "【LIVE】2024 Tokyo Shinjuku 新宿 大ガード交差点 Live Ch", channel: "https://www.youtube.com/channel/UCpk2ftN35L3xfoV2S5xLN2A/live"),
            .init(id: "official:tokyo-iwabuchi", platform: .official, title: "国土交通省 · 东京荒川岩渊水门", imageURL: URL(string: "https://www.ktr.mlit.go.jp/arage/live-camera/iwabuchikami.jpg")!, page: URL(string: "https://www.ktr.mlit.go.jp/arage/arage00563.html")!),
            .youtube("dfVK7ld38Ys", title: "【ライブ】いまの渋谷・スクランブル交差点　ライブカメラ　Shibuya Scramble Crossing - Tokyo, Japan　 Live Cam", channel: "https://www.youtube.com/channel/UCoQBJMzcwmXrRSHBFAlTsIw/live"),
            .youtube("5B4LmH4JbnY", title: "【ライブ】渋谷スクランブル交差点 / Shibuya Scramble Crossing Live Camera【LIVE】ANN/テレ朝", channel: "https://www.youtube.com/channel/UCGCZAYq5Xxojl_tSXcVJhiQ/live"),
            .youtube("_k-5U7IeK8g", title: "Tokyo Live Camera 東京ライブカメラ Tokyo Bay 4K with Lofi and soft Jazz BGM in 4K UHD", channel: "https://www.youtube.com/channel/UCaaSp7JYkACHR-Sr-p3OHeQ/live")
        ],
        "taipei": [
            .youtube("z_fY1pj1VBw", title: "【Taipei Live Cam】象山看台北 - 4K即時影像 | Overlooking Taipei at the top of Xiangshan | 象山から望む台北 | Taipei 101", channel: "https://www.youtube.com/channel/UCJLjpq7pTJRbP3vtx0LxB9Q/live"),
            .youtube("Ndo_8RuefH4", title: "【Taipei Live Cam】大稻埕碼頭 - 4K即時影像 | Taipei Dadaocheng Wharf | 台北大稲埕埠頭", channel: "https://www.youtube.com/channel/UCJLjpq7pTJRbP3vtx0LxB9Q/live"),
            .youtube("pmM2CeSAx0I", title: "Live Cam Taiwan Taipei City 台湾、台北のライブカメラ川岸の夜景 給大家放鬆的畫面和音樂,", channel: "https://www.youtube.com/channel/UCk-EAKT8Q5O2tm_TlhTmgOw/live")
        ],
        "newyork": [
            .youtube("VGnFLdQW39A", title: "🔴 24/7 NYC Live Cam | Times Square, skyline, streets, more", channel: "https://www.youtube.com/channel/UCIjSUWHWp6KohfnR5OQTXnQ/live"),
            .youtube("VXo0VqVcbK4", title: "Times Square: 1560 Broadway View Live", channel: "https://www.youtube.com/channel/UC1Rp_0bp86QEUt9TlMN5tlQ/live"),
            .youtube("KHy_n-EMWY8", title: "EarthCam Live:  Times Square Crossroads (New York City, NY)", channel: "https://www.youtube.com/channel/UC6qrG3W8SMK0jior2olka3g/live"),
            .skyline(538, title: "New York - Times Square", path: "/en/webcam/united-states/new-york/new-york/times-square.html"),
            .skyline(790, title: "New York City Skyline", path: "/en/webcam/united-states/new-york/new-york/new-york-skyline.html"),
            .skyline(6127, title: "New York - Empire State Building", path: "/en/webcam/united-states/new-york/new-york/empire-state-building.html"),
            .skyline(846, title: "New York City - Broadway Billboards", path: "/en/webcam/united-states/new-york/new-york/new-york-city.html"),
            .skyline(544, title: "Ball Drop Times Square - New York", path: "/en/webcam/united-states/new-york/new-york/ball-drop-times-square.html")
        ],
        "losangeles": [
            .youtube("8ucy5a4oQ2g", title: "🔴 Skid Row - Los Angeles - Live Cam", channel: "https://www.youtube.com/channel/UCNXQo1QN9bCkGEzu1X4G8vQ/live"),
            .youtube("3aRsjJylNM8", title: "Skid Row Cam1 Los Angeles, CA.", channel: "https://www.youtube.com/channel/UCQ1awPPNFA4AxnJ6dQyXfbg/live"),
            .youtube("EO_1LWqsCNE", title: "🔴 Los Angeles Live Cam · Venice Beach · Venice V Hotel · Live Camera Stream", channel: "https://www.youtube.com/channel/UCegzBUd6-PYoO_v7gjJgufg/live"),
            .youtube("FNXBYz_iKpY", title: "Skid Row Cam2 - Weingart Center. Los Angeles, CA.", channel: "https://www.youtube.com/channel/UCQ1awPPNFA4AxnJ6dQyXfbg/live"),
            .youtube("lzwkQptMHX8", title: "🔴 LIVE: Downtown Los Angeles | DTLA Skyline Cam (10/27/26)", channel: "https://www.youtube.com/channel/UCuGJHbJLvVW2JqKNzhBSu6g/live"),
            .skyline(2806, title: "Venice Beach - Los Angeles", path: "/en/webcam/united-states/california/los-angeles/venice-beach.html"),
            .skyline(6233, title: "Los Angeles - Hollywood Boulevard", path: "/en/webcam/united-states/california/los-angeles/hollywood-boulevard.html")
        ],
        "paris": [
            .youtube("YkKGantlWH0", title: "🔴 **PARIS EN DIRECT – TOUR EIFFEL LIVE 24/7 | EIFFEL TOWER LIVE CAMERA 【4K】ULTRA-HD", channel: "https://www.youtube.com/channel/UCpoZWK1NFFs3_LOZKwEJM9w/live"),
            .youtube("QI-PPEW2Bgc", title: "Live Webcam - Vue de Paris avec la Tour Eiffel et la Tour Montparnasse", channel: "https://www.youtube.com/channel/UC5VvzLNELVAwuPiMWsr2cvQ/live"),
            .youtube("-xzg3wujOVM", title: "Sacré-Cœur de Montmartre - Live Webcam 24/7 | PARIS TV", channel: "https://www.youtube.com/channel/UCjgiKi29C--6aW3pgn0l5JA/live"),
            .skyline(955, title: "Eiffel Tower", path: "/en/webcam/france/ile-de-france/paris/tour-eiffel.html"),
            .skyline(2490, title: "Paris - Tour Eiffel", path: "/en/webcam/france/ile-de-france/paris/paris-tour-eiffel.html"),
            .skyline(3002, title: "Paris - Sacré-Cœur", path: "/en/webcam/france/ile-de-france/paris/le-sacre-coeur-de-montmartre.html")
        ],
        "london": [
            .youtube("cf9uxEFIDtI", title: "🔴LIVE Notting Hill Gate Station - London 4K Webcam", channel: "https://www.youtube.com/channel/UC4-aIBtpNAPqEcMhAyFN6iQ/live"),
            .youtube("zMCea32gpmg", title: "EarthCam Live:  Abbey Road Crossing (London, England)", channel: "https://www.youtube.com/channel/UC6qrG3W8SMK0jior2olka3g/live"),
            .skyline(1207, title: "London - Abbey Road", path: "/en/webcam/united-kingdom/england/london/london-abbey-road.html")
        ],
    ]
}
