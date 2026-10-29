import Foundation
import Darwin

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
    func station() -> [ISSPoint] { Array((read("iss", as: [ISSPoint].self)?.value ?? []).prefix(60)) }
}

actor MapLayerService {
    static let shared = MapLayerService()
    let store: MapLayerStore
    private var running = false
    init(store: MapLayerStore = .shared) { self.store = store }

    @discardableResult func refresh(cities: [CameraCity], minimumAge: TimeInterval = 1800, budget: TimeInterval = 90) async -> Bool {
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
        let changes = await (a, b, c)
        return changes.0 || changes.1 || changes.2
    }
    private func request(_ url: URL, deadline: Date) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.1, remaining))
        request.setValue("WorldWatch/2.7", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = max(0.1, remaining)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw FeedError.invalid }
        return data
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
        if let old, now.timeIntervalSince(old.checkedAt) < age { return false }
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
    let cyclones = WorldPreferences.enabled("mapCyclones")
    // City time and weather labels were removed from the map at the user's request; the map shows text-free markers.
    let weather = false
    let iss = WorldPreferences.enabled("mapISS")
}
