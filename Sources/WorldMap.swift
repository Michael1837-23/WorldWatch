import Foundation

enum WorldPreferences {
    static var shared: UserDefaults {
        let group = Bundle.main.object(forInfoDictionaryKey: "WorldWatchAppGroup") as? String
        return group.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static func enabled(_ key: String) -> Bool { enabled(key, in: shared) }
    static func enabled(_ key: String, in defaults: UserDefaults) -> Bool {
        if key == "mapConflicts", defaults.object(forKey: key) == nil {
            defaults.set(defaults.object(forKey: "mapHotspots") as? Bool ?? true, forKey: key)
        }
        return defaults.object(forKey: key) as? Bool ?? true
    }
}

struct MapCoordinate: Codable, Equatable, Sendable {
    var longitude: Double
    var latitude: Double
}

struct MapCountry: Sendable {
    let id: String
    let name: String
    let continent: String
    let rank: Int
    let label: MapCoordinate
    let rings: [[MapCoordinate]]
    var area: Double {
        rings.reduce(0) { total, ring in
            guard ring.count > 2 else { return total }
            return total + abs(zip(ring, Array(ring.dropFirst()) + [ring[0]]).reduce(0) {
                $0 + $1.0.longitude * $1.1.latitude - $1.1.longitude * $1.0.latitude
            }) / 2
        }
    }
}

/// Natural Earth's English names are formal ("People's Republic of China"); map labels and headline matching use common short forms.
private let shortCountryNames = [
    "CHN": "China", "USA": "United States", "COD": "DR Congo", "COG": "Congo", "CAF": "Central African Rep.",
    "ARE": "UAE", "DOM": "Dominican Rep.", "BIH": "Bosnia", "TTO": "Trinidad", "CYN": "N. Cyprus",
    "ATF": "French S. Lands", "GNQ": "Eq. Guinea"
]

enum WorldMap {
    static let countries: [MapCountry] = WorldMapData.encoded.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 7, let rank = Int(fields[3]), let x = Double(fields[4]), let y = Double(fields[5]) else { return nil }
        let rings = fields[6].split(separator: ";").map { ring -> [MapCoordinate] in
            let values = ring.split(separator: ",").compactMap { Double($0) }
            return stride(from: 0, to: values.count - 1, by: 2).map { MapCoordinate(longitude: values[$0] / 10, latitude: values[$0 + 1] / 10) }
        }
        return MapCountry(id: String(fields[0]), name: shortCountryNames[String(fields[0])] ?? String(fields[1]), continent: String(fields[2]), rank: rank,
                          label: MapCoordinate(longitude: x / 10, latitude: y / 10), rings: rings)
    }
    static let ranked: [MapCountry] = countries.filter { $0.id != "ATA" }.sorted {
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        return $0.area == $1.area ? $0.id < $1.id : $0.area > $1.area
    }
}

struct MapBounds: Equatable, Sendable {
    var west: Double
    var east: Double
    var south: Double
    var north: Double
    func fitting(_ size: CGSize) -> MapBounds {
        guard size.width > 0, size.height > 0 else { return self }
        let ratio = Double(size.width / size.height), width = east - west, height = north - south
        if width / height < ratio {
            let extra = (height * ratio - width) / 2
            return MapBounds(west: west - extra, east: east + extra, south: south, north: north)
        }
        let extra = (width / ratio - height) / 2
        return MapBounds(west: west, east: east, south: south - extra, north: north + extra)
    }
}

enum MapRegion: String, CaseIterable, Sendable {
    case world = "全球", asia = "亚洲", europe = "欧洲", northAmerica = "北美洲"
    case southAmerica = "南美洲", africa = "非洲", oceania = "大洋洲", middleEast = "中东"
    var bounds: MapBounds {
        switch self {
        case .world: return .init(west: -180, east: 180, south: -58, north: 82)
        case .asia: return .init(west: 25, east: 180, south: -12, north: 80)
        case .europe: return .init(west: -25, east: 50, south: 33, north: 72)
        case .northAmerica: return .init(west: -170, east: -48, south: 5, north: 82)
        case .southAmerica: return .init(west: -85, east: -32, south: -58, north: 14)
        case .africa: return .init(west: -20, east: 55, south: -36, north: 38)
        case .oceania: return .init(west: 110, east: 205, south: -52, north: 5)
        case .middleEast: return .init(west: 24, east: 65, south: 10, north: 43)
        }
    }
    static var selected: MapRegion {
        get { MapRegion(rawValue: WorldPreferences.shared.string(forKey: "mapRegion") ?? "") ?? .world }
        set { WorldPreferences.shared.set(newValue.rawValue, forKey: "mapRegion") }
    }
}

struct MapProjection {
    let bounds: MapBounds
    let size: CGSize
    init(bounds: MapBounds, size: CGSize, fit: Bool = true) {
        self.bounds = fit ? bounds.fitting(size) : bounds
        self.size = size
    }
    func point(_ coordinate: MapCoordinate) -> CGPoint {
        CGPoint(x: (coordinate.longitude - bounds.west) / (bounds.east - bounds.west) * Double(size.width),
                y: (bounds.north - coordinate.latitude) / (bounds.north - bounds.south) * Double(size.height))
    }
    func visible(_ coordinate: MapCoordinate) -> CGPoint {
        var wrapped = coordinate
        let center = (bounds.west + bounds.east) / 2
        wrapped.longitude += (360 * ((center - wrapped.longitude) / 360).rounded())
        return point(wrapped)
    }
}

struct MapLabel: Equatable {
    let countryID: String
    let text: String
    let rect: CGRect
}

func mapLabels(projection: MapProjection, reserved: [MapLabel] = []) -> [MapLabel] {
    var result = reserved
    let frame = CGRect(origin: .zero, size: projection.size)
    let limit = min(30, max(6, Int(projection.size.width * projection.size.height / 6000)))
    for country in WorldMap.ranked {
        let center = projection.visible(country.label)
        // ponytail: conservative glyph bounds, use measured CoreText widths if typography changes.
        let width = Double(country.name.count) * 5.6 + 10
        let rect = CGRect(x: center.x - width / 2, y: center.y - 7, width: width, height: 14)
        guard frame.contains(rect), !result.contains(where: { $0.rect.intersects(rect) }) else { continue }
        result.append(MapLabel(countryID: country.id, text: country.name, rect: rect))
        if result.count - reserved.count >= limit { break }
    }
    return result
}

func placeMapLabel(_ texts: [String], id: String, at center: CGPoint, projection: MapProjection, labels: inout [MapLabel], obstacles: [CGRect] = []) {
    let frame = CGRect(origin: .zero, size: projection.size)
    guard frame.contains(center) else { return }
    for text in texts {
        let width = Double(text.count) * 5.6 + 8
        for offset in [CGPoint(x: 9, y: -16), CGPoint(x: 9, y: 3), CGPoint(x: -width - 9, y: -16),
                       CGPoint(x: -width - 9, y: 3), CGPoint(x: -width / 2, y: -23), CGPoint(x: -width / 2, y: 10)] {
            let rect = CGRect(x: center.x + offset.x, y: center.y + offset.y, width: width, height: 14)
            if frame.contains(rect), !labels.contains(where: { $0.rect.intersects(rect) }), !obstacles.contains(where: { $0.intersects(rect) }) {
                labels.append(MapLabel(countryID: id, text: text, rect: rect)); return
            }
        }
    }
}

func solarPosition(at date: Date) -> MapCoordinate {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
    let minutes = date.timeIntervalSince(calendar.startOfDay(for: date)) / 60
    let b = 2 * Double.pi * (day - 81) / 364
    let equation = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)
    var longitude = 180 - (minutes + equation) / 4
    while longitude < -180 { longitude += 360 }
    while longitude > 180 { longitude -= 360 }
    return .init(longitude: longitude, latitude: 23.44 * sin(2 * .pi * (day - 80) / 365.2422))
}

func isNight(_ coordinate: MapCoordinate, sun: MapCoordinate) -> Bool {
    let lat = coordinate.latitude * .pi / 180, declination = sun.latitude * .pi / 180
    let hour = (coordinate.longitude - sun.longitude) * .pi / 180
    return sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hour) < 0
}

struct MapMarker: Equatable, Sendable {
    let coordinate: MapCoordinate
    let red: Bool
    let magnitude: Double?
    let earthquake: Bool
    let label: String
    let symbol: String?
}

func mapMarkers(_ events: [WorldEvent], now: Date = Date()) -> [MapMarker] {
    events.filter(\.disaster).compactMap { event in
        guard let lat = event.latitude, let lon = event.longitude, lat.isFinite, lon.isFinite,
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        let coordinate = MapCoordinate(longitude: lon, latitude: lat)
        if event.sourceID == "usgs" {
            guard let date = event.date, date <= now, date >= now.addingTimeInterval(-86400),
                  let magnitude = event.magnitude, magnitude.isFinite, magnitude >= 6 else { return nil }
            return MapMarker(coordinate: coordinate, red: true, magnitude: magnitude, earthquake: true,
                             label: String(format: "M%.1f", magnitude), symbol: nil)
        }
        guard event.sourceID == "gdacs", let type = event.eventType, !["DR", "TC", "EQ"].contains(type),
              ["红色预警", "橙色预警"].contains(event.severity ?? ""),
              let end = event.endDate ?? event.date, end >= now.addingTimeInterval(-3 * 86400),
              event.date.map({ $0 <= now }) ?? true else { return nil }
        let labels = ["FL": "Flood", "VO": "Volcano", "WF": "Wildfire", "TS": "Tsunami"]
        let symbols = ["FL": "drop.fill", "VO": "mountain.2.fill", "WF": "flame.fill", "TS": "water.waves"]
        return MapMarker(coordinate: coordinate, red: event.severity == "红色预警", magnitude: nil, earthquake: false,
                         label: labels[type] ?? "Alert", symbol: symbols[type] ?? "exclamationmark.triangle.fill")
    }.sorted {
        if $0.coordinate.latitude != $1.coordinate.latitude { return $0.coordinate.latitude < $1.coordinate.latitude }
        return $0.coordinate.longitude < $1.coordinate.longitude
    }
}

struct MapConflict: Equatable, Sendable {
    let countryID: String
    let score: Int
    var level: Int { conflictLevel(score) }
}

let conflictThresholds = [3, 8, 16, 30]
func conflictLevel(_ score: Int) -> Int { conflictThresholds.filter { score >= $0 }.count }

private let conflictPatterns = [
    #"(?i)\b(airstrikes?|missiles?|shelling|bombing|invasion|massacre)\b|空袭|空襲|导弹|導彈|炮击|炮擊|轰炸|轟炸|入侵"#,
    #"(?i)\b(war|fighting|clashes|offensive|drone strikes?|hostages?|troops)\b|战争|戰爭|交火|冲突|衝突|进攻|進攻|无人机袭击|無人機襲擊|人质|人質|军队|軍隊"#,
    #"(?i)\b(military|ceasefire|sanctions|tensions|truce)\b|军事|軍事|停火|制裁|紧张局势|緊張局勢"#
].map { try! NSRegularExpression(pattern: $0) }
// Casualty words alone also describe accidents (a train crash "kills 64"); they only raise a headline
// to the top weight when it also has a conflict word or an attack context.
private let casualtyPattern = try! NSRegularExpression(pattern: #"(?i)\b(killed|dead|casualties|death toll)\b|死亡|遇难|遇難|伤亡|傷亡"#)
private let attackPattern = try! NSRegularExpression(pattern: #"(?i)\b(attacks?|attacked|soldiers|militants|gunmen|army)\b|袭击|襲擊|士兵|武装|武裝"#)

func conflictWeight(_ title: String) -> Int {
    func has(_ regex: NSRegularExpression) -> Bool { regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil }
    let tier = conflictPatterns.firstIndex(where: has).map { 3 - $0 } ?? 0
    if has(casualtyPattern), tier > 0 || has(attackPattern) { return 3 }
    return tier
}

private let countryAliases: [String: [String]] = [
    "CHN": ["中国", "中國"], "USA": ["美国", "美國", "United States", "U.S.", "USA"],
    "GBR": ["英国", "英國", "UK", "Britain", "British"], "RUS": ["俄罗斯", "俄羅斯", "Russia"],
    "ISR": ["以色列", "Israeli"], "IRN": ["伊朗", "Iran"], "UKR": ["乌克兰", "烏克蘭"],
    "JPN": ["日本"], "TWN": ["台湾", "台灣"], "PRK": ["朝鲜", "朝鮮", "North Korea"],
    "KOR": ["韩国", "韓國", "South Korea"], "FRA": ["法国", "法國", "French"],
    "DEU": ["德国", "德國", "German"], "IND": ["印度"], "PAK": ["巴基斯坦"],
    "AFG": ["阿富汗"], "IRQ": ["伊拉克"], "SYR": ["叙利亚", "敘利亞", "Syria"],
    "LBN": ["黎巴嫩"], "PSE": ["巴勒斯坦", "Palestine", "Gaza", "加沙"],
    "SAU": ["沙特", "沙烏地", "Saudi"], "YEM": ["也门", "葉門", "也門"],
    "TUR": ["土耳其", "Turkey", "Türkiye"], "EGY": ["埃及"], "JOR": ["约旦", "約旦"],
    "ARE": ["阿联酋", "阿聯酋", "UAE"], "QAT": ["卡塔尔", "卡達", "卡塔爾"],
    "CAN": ["加拿大"], "MEX": ["墨西哥"], "BRA": ["巴西"], "ARG": ["阿根廷"],
    "COL": ["哥伦比亚", "哥倫比亞"], "VEN": ["委内瑞拉", "委內瑞拉"], "CHL": ["智利"],
    "PER": ["秘鲁", "秘魯"], "AUS": ["澳大利亚", "澳洲"], "NZL": ["新西兰", "紐西蘭"],
    "IDN": ["印尼", "印度尼西亚"], "MYS": ["马来西亚", "馬來西亞"], "SGP": ["新加坡"],
    "THA": ["泰国", "泰國"], "VNM": ["越南", "Vietnam"], "PHL": ["菲律宾", "菲律賓"],
    "MMR": ["缅甸", "緬甸", "Burma"], "BGD": ["孟加拉"], "NPL": ["尼泊尔", "尼泊爾"],
    "ITA": ["意大利", "義大利"], "ESP": ["西班牙"], "PRT": ["葡萄牙"],
    "POL": ["波兰", "波蘭"], "NLD": ["荷兰", "荷蘭"], "BEL": ["比利时", "比利時"],
    "SWE": ["瑞典"], "NOR": ["挪威"], "FIN": ["芬兰", "芬蘭"], "DNK": ["丹麦", "丹麥"],
    "CHE": ["瑞士"], "AUT": ["奥地利", "奧地利"], "GRC": ["希腊", "希臘"],
    "IRL": ["爱尔兰", "愛爾蘭"], "ZAF": ["南非"], "NGA": ["尼日利亚", "奈及利亞"],
    "KEN": ["肯尼亚", "肯亞"], "ETH": ["埃塞俄比亚", "衣索比亞"], "SDN": ["苏丹", "蘇丹"],
    "SOM": ["索马里", "索馬利亞"], "LBY": ["利比亚", "利比亞"], "MAR": ["摩洛哥"]
]

private let countryMatchers: [(MapCountry, NSRegularExpression)] = WorldMap.countries.compactMap { country in
    var aliases = [country.name] + (countryAliases[country.id] ?? [])
    if country.id == "USA" { aliases.append("US") }
    let patterns = aliases.map { alias -> String in
        let escaped = NSRegularExpression.escapedPattern(for: alias)
        if alias == "US" || alias == "UK" { return "(?<![A-Za-z])" + escaped + "(?![A-Za-z])" }
        return "(?i:(?<![A-Za-z])" + escaped + "(?![A-Za-z]))"
    }
    guard let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|")) else { return nil }
    return (country, regex)
}

func mapConflicts(_ events: [WorldEvent], now: Date = Date()) -> [MapConflict] {
    let recent = events.filter { !$0.disaster && !$0.isDomestic && $0.date.map { $0 <= now && $0 >= now.addingTimeInterval(-48 * 3600) } == true }
        .map { ($0.title, conflictWeight($0.title)) }.filter { $0.1 > 0 }
    return countryMatchers.compactMap { country, regex in
        let score = recent.reduce(0) { score, item in
            score + (regex.firstMatch(in: item.0, range: NSRange(item.0.startIndex..., in: item.0)) == nil ? 0 : item.1)
        }
        return conflictLevel(score) == 0 ? nil : MapConflict(countryID: country.id, score: score)
    }.sorted { $0.score == $1.score ? $0.countryID < $1.countryID : $0.score > $1.score }.prefix(15).map { $0 }
}
