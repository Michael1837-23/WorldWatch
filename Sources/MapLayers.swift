import Foundation
import Darwin

struct OngoingConflictCountry: Codable, Equatable, Sendable {
    let countryID: String
    var events: Int
    var fatalities: Int
    var level: Int { [1, 25, 250, 1000].filter { fatalities >= $0 }.count }
}

struct OngoingConflictSnapshot: Codable, Equatable, Sendable {
    let version: String
    let periodStart: Date
    let periodEnd: Date
    let countries: [OngoingConflictCountry]
    static let source = URL(string: "https://ucdp.uu.se/downloads/index.html")!
    static let citation = "UCDP Candidate Events Dataset · Hegre et al. (2020) · CC BY 4.0"
    var monthLabel: String {
        let format = DateFormatter(); format.dateFormat = "yyyy年M月"; format.timeZone = TimeZone(secondsFromGMT: 0)
        return format.string(from: periodStart)
    }
    func isRecent(at date: Date) -> Bool { date >= periodEnd && date.timeIntervalSince(periodEnd) <= 120 * 86400 }
    // Generated from UCDP's official monthly CSV; updated downloads replace this small offline seed.
    static let initial = try! JSONDecoder().decode(Self.self, from: Data(bundledOngoingConflictJSON.utf8))
}

private let bundledOngoingConflictJSON = #"{"countries":[{"countryID":"UKR","events":238,"fatalities":6189},{"countryID":"YEM","events":188,"fatalities":1206},{"countryID":"PAK","events":121,"fatalities":603},{"countryID":"SOM","events":14,"fatalities":189},{"countryID":"ETH","events":27,"fatalities":179},{"countryID":"MMR","events":46,"fatalities":160},{"countryID":"SDN","events":32,"fatalities":159},{"countryID":"PSE","events":94,"fatalities":130},{"countryID":"MEX","events":52,"fatalities":72},{"countryID":"NGA","events":10,"fatalities":72},{"countryID":"MLI","events":16,"fatalities":70},{"countryID":"COD","events":13,"fatalities":62},{"countryID":"LBN","events":16,"fatalities":40},{"countryID":"RUS","events":11,"fatalities":30},{"countryID":"BFA","events":8,"fatalities":24},{"countryID":"CMR","events":12,"fatalities":20},{"countryID":"TCD","events":2,"fatalities":20},{"countryID":"HTI","events":4,"fatalities":13},{"countryID":"PHL","events":4,"fatalities":13},{"countryID":"MOZ","events":6,"fatalities":12},{"countryID":"AFG","events":3,"fatalities":11},{"countryID":"IRN","events":2,"fatalities":9},{"countryID":"IDN","events":2,"fatalities":7},{"countryID":"IRQ","events":3,"fatalities":5},{"countryID":"THA","events":2,"fatalities":4},{"countryID":"BRA","events":3,"fatalities":3},{"countryID":"IND","events":2,"fatalities":2},{"countryID":"CAF","events":1,"fatalities":1},{"countryID":"COL","events":1,"fatalities":1}],"periodEnd":812505600,"periodStart":809913600,"version":"26.0.9"}"#

func latestOngoingConflictVersion(_ data: Data, now: Date = Date()) throws -> String {
    guard let html = String(data: data, encoding: .utf8) else { throw FeedError.invalid }
    let regex = try NSRegularExpression(pattern: #"GEDEvent_v(\d{2})_0_(\d{1,2})\.csv"#)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let choices: [(Int, Int)] = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
        guard let y = Range(match.range(at: 1), in: html), let m = Range(match.range(at: 2), in: html),
              let year = Int(html[y]), let month = Int(html[m]), (1...12).contains(month),
              let start = calendar.date(from: DateComponents(year: 2000 + year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start), end <= now else { return nil }
        return (year, month)
    }
    guard let latest = choices.max(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) else { throw FeedError.invalid }
    return "\(latest.0).0.\(latest.1)"
}

func forEachConflictCSVRow(_ data: Data, visit: ([String]) throws -> Void) throws {
    guard data.count <= 8_000_000 else { throw FeedError.invalid }
    let bytes = Array(data)
    var field: [UInt8] = [], row: [String] = [], quoted = false, closed = false, count = 0
    var index = bytes.starts(with: [239, 187, 191]) ? 3 : 0
    func endField() throws {
        guard let value = String(bytes: field, encoding: .utf8) else { throw FeedError.invalid }
        row.append(value); field.removeAll(keepingCapacity: true); closed = false
    }
    func endRow() throws {
        try endField()
        if !row.allSatisfy(\.isEmpty) { count += 1; guard count <= 50_000 else { throw FeedError.invalid }; try visit(row) }
        row.removeAll(keepingCapacity: true)
    }
    while index < bytes.count {
        let byte = bytes[index]
        if quoted {
            if byte == 34 {
                if index + 1 < bytes.count, bytes[index + 1] == 34 { field.append(34); index += 1 }
                else { quoted = false; closed = true }
            } else { field.append(byte) }
        } else if byte == 44 { try endField() }
        else if byte == 10 || byte == 13 {
            try endRow()
            if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
        } else if byte == 34 {
            guard field.isEmpty, !closed else { throw FeedError.invalid }; quoted = true
        } else {
            guard !closed else { throw FeedError.invalid }; field.append(byte)
        }
        index += 1
    }
    guard !quoted else { throw FeedError.invalid }
    if !field.isEmpty || !row.isEmpty || closed { try endRow() }
}

func parseOngoingConflictCSV(_ data: Data, version: String, now: Date = Date()) throws -> OngoingConflictSnapshot {
    let rawParts = version.split(separator: ".", omittingEmptySubsequences: false)
    let parts = rawParts.compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard rawParts.count == 3, parts.count == 3, parts[1] == 0, (20...99).contains(parts[0]), (1...12).contains(parts[2]),
          let start = calendar.date(from: DateComponents(year: 2000 + parts[0], month: parts[2], day: 1)),
          let end = calendar.date(byAdding: .month, value: 1, to: start), end <= now, now.timeIntervalSince(end) <= 120 * 86400 else { throw FeedError.invalid }
    var header: [String] = [], columns: [String: Int] = [:], seen = Set<String>(), countries: [String: OngoingConflictCountry] = [:]
    let required = ["id", "active_year", "code_status", "type_of_violence", "country", "adm_1", "best", "date_start", "date_end"]
    try forEachConflictCSVRow(data) { row in
        if header.isEmpty {
            guard Set(row).count == row.count, required.allSatisfy(row.contains) else { throw FeedError.invalid }
            header = row; columns = Dictionary(uniqueKeysWithValues: row.enumerated().map { ($0.element, $0.offset) }); return
        }
        guard row.count == header.count else { throw FeedError.invalid }
        func value(_ key: String) -> String { row[columns[key]!] }
        guard ["1", "true"].contains(value("active_year").lowercased()), value("code_status").lowercased() == "clear",
              let kind = Int(value("type_of_violence")), (1...3).contains(kind),
              let deaths = Int(value("best")), deaths > 0, deaths <= 1_000_000,
              let first = parseDate(String(value("date_start").prefix(10)) + "T00:00:00Z"),
              let last = parseDate(String(value("date_end").prefix(10)) + "T00:00:00Z"),
              first >= start, last < end, first <= last,
              let country = ongoingCountryID(value("country"), administration: value("adm_1")), seen.insert(value("id")).inserted else { return }
        var record = countries[country] ?? OngoingConflictCountry(countryID: country, events: 0, fatalities: 0)
        record.events += 1; record.fatalities += deaths; countries[country] = record
    }
    guard !countries.isEmpty else { throw FeedError.invalid }
    return OngoingConflictSnapshot(version: version, periodStart: start, periodEnd: end,
        countries: countries.values.sorted { $0.fatalities == $1.fatalities ? $0.countryID < $1.countryID : $0.fatalities > $1.fatalities })
}

struct CycloneEvent: Sendable {
    let id: Int
    let name: String
    let red: Bool
    let end: Date
    let geometry: URL
}

struct MapCyclone: Codable, Sendable {
    let id: Int
    let name: String
    let red: Bool
    let end: Date
    let history: [MapCoordinate]
    let forecast: [MapCoordinate]
    var current: MapCoordinate? { history.last ?? forecast.first }
}

/// GDACS forecast lines carry no timestamps. History segments are roughly six-hourly advisories,
/// so twice the mean history step approximates twelve hours of travel along the forecast line.
func cycloneForecast(_ cyclone: MapCyclone, hours: Double = 12) -> [MapCoordinate] {
    func distance(_ a: MapCoordinate, _ b: MapCoordinate) -> Double {
        let dx = (b.longitude - a.longitude) * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return (dx * dx + pow(b.latitude - a.latitude, 2)).squareRoot()
    }
    let steps = zip(cyclone.history, cyclone.history.dropFirst()).map(distance)
    var budget = (steps.isEmpty ? 1.0 : steps.reduce(0, +) / Double(steps.count)) * hours / 6
    guard var previous = cyclone.forecast.first else { return [] }
    var result = [previous]
    for point in cyclone.forecast.dropFirst() {
        let length = distance(previous, point)
        if length >= budget {
            let t = length > 0 ? budget / length : 0
            result.append(.init(longitude: previous.longitude + (point.longitude - previous.longitude) * t,
                                latitude: previous.latitude + (point.latitude - previous.latitude) * t))
            return result
        }
        budget -= length; result.append(point); previous = point
    }
    return result
}

func cycloneName(_ name: String) -> String {
    name.replacingOccurrences(of: "(?i)^Tropical Cyclone\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "-\\d{2,4}$", with: "", options: .regularExpression)
}

func geoFeatures(_ data: Data) throws -> [[String: Any]] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let features = root["features"] as? [[String: Any]] else { throw FeedError.invalid }
    return features
}

func mapCoordinate(_ values: [Double]) -> MapCoordinate? {
    guard values.count >= 2, values[0].isFinite, values[1].isFinite,
          abs(values[0]) <= 180, abs(values[1]) <= 90 else { return nil }
    return .init(longitude: values[0], latitude: values[1])
}

func parseCycloneEvents(_ data: Data, now: Date = Date()) throws -> [CycloneEvent] {
    try geoFeatures(data).compactMap { feature in
        guard let p = feature["properties"] as? [String: Any], let id = p["eventid"] as? Int,
              let name = p["name"] as? String, let alert = p["alertlevel"] as? String,
              ["red", "orange"].contains(alert.lowercased()),
              let end = parseDate(p["todate"] as? String), end >= now.addingTimeInterval(-18 * 3600),
              let urls = p["url"] as? [String: String], let raw = urls["geometry"], let url = URL(string: raw),
              url.scheme == "https", url.host == "www.gdacs.org" else { return nil }
        return CycloneEvent(id: id, name: cycloneName(name), red: alert.lowercased() == "red", end: end, geometry: url)
    }.sorted { $0.end == $1.end ? $0.id < $1.id : $0.end > $1.end }.prefix(5).map { $0 }
}

func sampled<T>(_ points: [T], limit: Int) -> [T] {
    guard limit > 1 else { return Array(points.suffix(max(0, limit))) }
    guard points.count > limit else { return points }
    return (0..<limit).map { points[Int((Double($0) * Double(points.count - 1) / Double(limit - 1)).rounded())] }
}

// Segments arrive out of order; connect their directed endpoints before sampling.
func cycloneTrack(_ segments: [[MapCoordinate]], startingAt start: MapCoordinate? = nil) -> [MapCoordinate] {
    var pending = segments.filter { $0.count >= 2 }, result: [MapCoordinate] = []
    let first = start ?? pending.first(where: { candidate in !pending.contains { $0.last == candidate.first } })?.first
    if let first { result = [first] }
    while let last = result.last, let index = pending.firstIndex(where: { $0.first == last }) {
        result += pending.remove(at: index).dropFirst()
    }
    return result
}

func parseCycloneGeometry(_ data: Data, event: CycloneEvent) throws -> MapCyclone {
    var historical: [[MapCoordinate]] = [], predicted: [[MapCoordinate]] = []
    for feature in try geoFeatures(data) {
        guard let p = feature["properties"] as? [String: Any], let forecast = p["forecast"] as? Bool,
              let geometry = feature["geometry"] as? [String: Any], geometry["type"] as? String == "LineString",
              let values = geometry["coordinates"] as? [[Double]] else { continue }
        let points = values.compactMap(mapCoordinate)
        if forecast { predicted.append(points) } else { historical.append(points) }
    }
    let history = cycloneTrack(historical)
    let forecast = cycloneTrack(predicted, startingAt: history.last)
    guard history.count >= 2 || forecast.count >= 2 else { throw FeedError.invalid }
    let total = history.count + forecast.count
    let historyLimit = total <= 60 ? history.count : max(history.isEmpty ? 0 : 2, min(forecast.isEmpty ? 60 : 58, Int(60.0 * Double(history.count) / Double(total))))
    return MapCyclone(id: event.id, name: event.name, red: event.red, end: event.end,
                      history: sampled(history, limit: historyLimit), forecast: sampled(forecast, limit: 60 - historyLimit))
}

struct CityWeather: Codable, Sendable {
    let cityID: String
    let temperature: Double
    let observedAt: Date
}

func parseCityWeather(_ data: Data, cities: [CameraCity]) throws -> [CityWeather] {
    let object = try JSONSerialization.jsonObject(with: data)
    let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
    guard rows.count == cities.count else { throw FeedError.invalid }
    return zip(cities, rows).compactMap { city, row in
        guard let current = row["current"] as? [String: Any], let temperature = current["temperature_2m"] as? Double,
              temperature.isFinite, let time = current["time"] as? String, let date = parseDate(time.count == 16 ? time + ":00Z" : time + (time.hasSuffix("Z") ? "" : "Z")) else { return nil }
        return CityWeather(cityID: city.id, temperature: temperature, observedAt: date)
    }
}

func cityTime(_ city: CameraCity, at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: city.timeZoneID)
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func cityConditions(_ city: CameraCity, at date: Date, weather: [CityWeather]) -> String {
    let time = cityTime(city, at: date)
    guard let current = weather.first(where: { $0.cityID == city.id }),
          date.timeIntervalSince(current.observedAt) <= 3 * 3600,
          date.timeIntervalSince(current.observedAt) >= -3600 else { return time }
    return time + " · \(Int(current.temperature.rounded()))°"
}

struct ISSPoint: Codable, Equatable, Sendable {
    let date: Date
    let coordinate: MapCoordinate
}

func parseISS(_ data: Data) throws -> [ISSPoint] {
    let object = try JSONSerialization.jsonObject(with: data)
    let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
    let points = rows.compactMap { row -> ISSPoint? in
        guard let lat = row["latitude"] as? Double, let lon = row["longitude"] as? Double,
              let stamp = row["timestamp"] as? Double, stamp.isFinite,
              let coordinate = mapCoordinate([lon, lat]) else { return nil }
        return ISSPoint(date: Date(timeIntervalSince1970: stamp), coordinate: coordinate)
    }.sorted { $0.date < $1.date }
    guard !points.isEmpty, points.count == rows.count else { throw FeedError.invalid }
    return points
}

func issPosition(_ points: [ISSPoint], at date: Date) -> MapCoordinate? {
    guard let first = points.first, let last = points.last, date >= first.date, date <= last.date else { return nil }
    if date == last.date { return last.coordinate }
    for (a, b) in zip(points, points.dropFirst()) where a.date <= date && date < b.date {
        let fraction = date.timeIntervalSince(a.date) / b.date.timeIntervalSince(a.date)
        var delta = b.coordinate.longitude - a.coordinate.longitude
        delta -= 360 * (delta / 360).rounded()
        var lon = a.coordinate.longitude + fraction * delta
        if lon > 180 { lon -= 360 }; if lon < -180 { lon += 360 }
        return .init(longitude: lon, latitude: a.coordinate.latitude + fraction * (b.coordinate.latitude - a.coordinate.latitude))
    }
    return first.coordinate
}

func recentISSTrack(_ points: [ISSPoint], at date: Date) -> [ISSPoint] {
    guard let first = points.first, let last = points.last,
          first.date <= date, last.date >= date.addingTimeInterval(-1800) else { return [] }
    return points
}

func mapSegments(_ coordinates: [MapCoordinate]) -> [[MapCoordinate]] {
    var result: [[MapCoordinate]] = []
    for point in coordinates {
        if let previous = result.last?.last, abs(point.longitude - previous.longitude) <= 180 {
            result[result.count - 1].append(point)
        } else { result.append([point]) }
    }
    return result
}

struct MapLayerCache<Value: Codable & Sendable>: Codable, Sendable {
    let checkedAt: Date
    let fetchedAt: Date
    let value: Value
}

func issRefreshNeeded(_ cache: MapLayerCache<[ISSPoint]>?, at now: Date, minimumAge: TimeInterval) -> Bool {
    guard let cache else { return true }
    let interval = min(900, max(0, minimumAge))
    let failed = cache.checkedAt.timeIntervalSince(cache.fetchedAt) > 1
    let coversTimeline = issPosition(cache.value, at: now.addingTimeInterval(1800)) != nil
    let wait = failed || !coversTimeline ? min(300, interval) : interval
    return now.timeIntervalSince(cache.checkedAt) >= wait
}

struct MapLayerStore: Sendable {
    let root: URL
    static var shared: MapLayerStore {
        .init(root: NewsSnapshotStore.shared.fileURL.deletingLastPathComponent().appendingPathComponent("MapLayers"))
    }
    func read<T>(_ name: String, as type: T.Type) -> MapLayerCache<T>? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONDecoder().decode(MapLayerCache<T>.self, from: data)
    }
    func write<T>(_ cache: MapLayerCache<T>, name: String) throws {
        if let current = read(name, as: T.self), current.checkedAt > cache.checkedAt { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
    }
    func cyclones(at date: Date) -> [MapCyclone] {
        guard let cache = read("cyclones", as: [MapCyclone].self), date.timeIntervalSince(cache.fetchedAt) <= 86400 else { return [] }
        return Array(cache.value.filter { $0.end >= date.addingTimeInterval(-18 * 3600) }.prefix(5))
    }
    func weather() -> [CityWeather] { read("weather", as: [CityWeather].self)?.value ?? [] }
    func ongoing() -> OngoingConflictSnapshot {
        let seed = OngoingConflictSnapshot.initial
        guard let cache = read("ongoing-conflicts", as: OngoingConflictSnapshot.self), cache.value.periodEnd >= seed.periodEnd else { return seed }
        return cache.value
    }
    func station(at date: Date = Date()) -> [ISSPoint] { recentISSTrack(Array((read("iss", as: [ISSPoint].self)?.value ?? []).prefix(60)), at: date) }
}

actor MapLayerService {
    static let shared = MapLayerService()
    let store: MapLayerStore
    private var running = false
    init(store: MapLayerStore = .shared) { self.store = store }

    @discardableResult func refresh(cities: [CameraCity], minimumAge: TimeInterval = 1800, budget: TimeInterval = 90, includeOngoing: Bool = true) async -> Bool {
        guard !running else { return false }
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let descriptor = open(store.root.appendingPathComponent(".refresh.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return false }
        running = true
        defer { running = false; flock(descriptor, LOCK_UN); close(descriptor) }
        let deadline = Date().addingTimeInterval(budget), settings = MapSettingsForFetch()
        async let a = refreshCyclones(age: minimumAge, deadline: deadline, enabled: settings.cyclones)
        async let b = refreshWeather(cities: Array(cities.prefix(4)), age: minimumAge, deadline: deadline, enabled: settings.weather)
        async let c = refreshISS(age: minimumAge, deadline: deadline, enabled: settings.iss)
        async let d = refreshOngoing(deadline: deadline, enabled: settings.conflicts && includeOngoing && budget >= 30)
        let changes = await (a, b, c, d)
        return changes.0 || changes.1 || changes.2 || changes.3
    }
    private func request(_ url: URL, deadline: Date) async throws -> Data {
        for attempt in 0..<2 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.1, remaining))
            request.setValue("WorldWatch/2.9", forHTTPHeaderField: "User-Agent")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = max(0.1, remaining)
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw FeedError.invalid }
                guard (200..<300).contains(http.statusCode) else { throw FeedError.http(http.statusCode) }
                return data
            } catch let error as URLError where attempt == 0 && [.timedOut, .networkConnectionLost, .secureConnectionFailed].contains(error.code) {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch FeedError.http(let status) where attempt == 0 && [502, 503, 504].contains(status) {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw URLError(.cannotConnectToHost)
    }
    private func refreshOngoing(deadline: Date, enabled: Bool) async -> Bool {
        guard enabled else { return false }
        let old = store.read("ongoing-conflicts", as: OngoingConflictSnapshot.self), now = Date()
        if let old, now.timeIntervalSince(old.checkedAt) < 86400 { return false }
        let previous = store.ongoing()
        do {
            let index = try await request(OngoingConflictSnapshot.source, deadline: deadline)
            let version = try latestOngoingConflictVersion(index, now: now)
            if version == previous.version {
                try store.write(.init(checkedAt: now, fetchedAt: old?.fetchedAt ?? now, value: previous), name: "ongoing-conflicts")
                return old == nil
            }
            let url = URL(string: "https://ucdp.uu.se/downloads/candidateged/GEDEvent_v\(version.replacingOccurrences(of: ".", with: "_")).csv")!
            let data = try await request(url, deadline: deadline)
            let snapshot = try parseOngoingConflictCSV(data, version: version, now: now)
            guard snapshot.periodEnd > previous.periodEnd else { throw FeedError.invalid }
            try store.write(.init(checkedAt: now, fetchedAt: now, value: snapshot), name: "ongoing-conflicts")
            return true
        } catch {
            // Failed checks never erase the verified monthly baseline or reset its data month.
            try? store.write(.init(checkedAt: now, fetchedAt: old?.fetchedAt ?? .distantPast, value: previous), name: "ongoing-conflicts")
            NSLog("持续冲突数据检查失败，保留 %@：%@", previous.monthLabel, error.localizedDescription)
            return false
        }
    }
    private func refreshCyclones(age: TimeInterval, deadline: Date, enabled: Bool) async -> Bool {
        guard enabled else { return false }
        let old = store.read("cyclones", as: [MapCyclone].self), now = Date()
        if let old, now.timeIntervalSince(old.checkedAt) < age { return false }
        do {
            let data = try await request(URL(string: "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?eventlist=TC&alertlevel=Orange;Red")!, deadline: deadline)
            let events = try parseCycloneEvents(data, now: now)
            var tracks: [MapCyclone] = []
            for event in events {
                let geometry = try await request(event.geometry, deadline: deadline)
                tracks.append(try parseCycloneGeometry(geometry, event: event))
            }
            try store.write(.init(checkedAt: now, fetchedAt: now, value: tracks), name: "cyclones")
            return true
        } catch {
            saveFailure(old, name: "cyclones", at: now)
            NSLog("台风路径刷新失败：%@", error.localizedDescription); return false
        }
    }
    private func refreshWeather(cities: [CameraCity], age: TimeInterval, deadline: Date, enabled: Bool) async -> Bool {
        guard enabled, !cities.isEmpty else { return false }
        let old = store.read("weather", as: [CityWeather].self), now = Date()
        if let old, now.timeIntervalSince(old.checkedAt) < age,
           Set(old.value.map(\.cityID)) == Set(cities.map(\.id)) { return false }
        do {
            let lat = cities.map { String($0.coordinate.latitude) }.joined(separator: ",")
            let lon = cities.map { String($0.coordinate.longitude) }.joined(separator: ",")
            let data = try await request(URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day&timeformat=iso8601&timezone=GMT")!, deadline: deadline)
            let weather = try parseCityWeather(data, cities: cities)
            guard weather.count == cities.count else { throw FeedError.invalid }
            try store.write(.init(checkedAt: now, fetchedAt: now, value: weather), name: "weather"); return true
        } catch { saveFailure(old, name: "weather", at: now); NSLog("城市天气刷新失败：%@", error.localizedDescription); return false }
    }
    private func refreshISS(age: TimeInterval, deadline: Date, enabled: Bool) async -> Bool {
        guard enabled else { return false }
        let old = store.read("iss", as: [ISSPoint].self), now = Date()
        if !issRefreshNeeded(old, at: now, minimumAge: age) { return false }
        do {
            let data = try await request(URL(string: "https://api.wheretheiss.at/v1/satellites/25544")!, deadline: deadline)
            let current = try parseISS(data)[0]
            let stamps = stride(from: -2700, through: 2700, by: 300).map { Int(current.date.timeIntervalSince1970) + $0 }
            var points: [ISSPoint] = []
            for start in stride(from: 0, to: stamps.count, by: 10) {
                let batch = stamps.dropFirst(start).prefix(10).map(String.init).joined(separator: ",")
                let data = try await request(URL(string: "https://api.wheretheiss.at/v1/satellites/25544/positions?timestamps=\(batch)")!, deadline: deadline)
                points += try parseISS(data)
            }
            points.removeAll { $0.date == current.date }; points.append(current); points.sort { $0.date < $1.date }
            try store.write(.init(checkedAt: now, fetchedAt: now, value: sampled(points, limit: 60)), name: "iss"); return true
        } catch { saveFailure(old, name: "iss", at: now); NSLog("空间站轨迹刷新失败：%@", error.localizedDescription); return false }
    }
    private func saveFailure<T>(_ old: MapLayerCache<T>?, name: String, at date: Date) {
        if let old { try? store.write(.init(checkedAt: date, fetchedAt: old.fetchedAt, value: old.value), name: name) }
    }
}

private struct MapSettingsForFetch {
    let conflicts = WorldPreferences.enabled("mapConflicts")
    let cyclones = WorldPreferences.enabled("mapCyclones")
    // City time and weather labels were removed from the map at the user's request; the map shows text-free markers.
    let weather = false
    let iss = WorldPreferences.enabled("mapISS")
}
