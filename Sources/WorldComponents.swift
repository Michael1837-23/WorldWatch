import SwiftUI
import AppKit
import ImageIO

struct MapSettings: Sendable {
    var region = MapRegion.selected
    var earthquakes = WorldPreferences.enabled("mapEarthquakes")
    var disasters = WorldPreferences.enabled("mapDisasters")
    var night = WorldPreferences.enabled("mapNight")
    var conflicts = WorldPreferences.enabled("mapConflicts")
    var cyclones = WorldPreferences.enabled("mapCyclones")
    var cityWeather = WorldPreferences.enabled("mapCityWeather")
    var iss = WorldPreferences.enabled("mapISS")
}

/// Tile order colors, shared by the map pins and the tile labels so each picture can be found on the map.
/// Red and orange stay reserved for earthquakes and disaster alerts.
let cameraAccents: [Color] = [Color(red: 0.25, green: 0.62, blue: 1.0), Color(red: 0.2, green: 0.82, blue: 0.55),
                              Color(red: 0.69, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.42, blue: 0.7)]

struct WorldMapCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let markers: [MapMarker]
    let conflicts: [MapConflict]
    let sun: MapCoordinate
    var settings = MapSettings()
    var cameras: [CameraCity] = []
    var date = Date()
    var cyclones: [MapCyclone] = []
    var weather: [CityWeather] = []
    var station: [ISSPoint] = []
    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let projection = MapProjection(bounds: settings.region.bounds, size: size)
            let frame = CGRect(origin: .zero, size: size)
            var boundaries = Path()
            var conflictAreas: [(Path, Int)] = []
            for country in WorldMap.countries where country.id != "ATA" {
                var path = Path()
                for ring in country.rings where !ring.isEmpty {
                    var unwrapped: [MapCoordinate] = []
                    var previous = ring[0].longitude
                    for coordinate in ring {
                        var point = coordinate
                        point.longitude += 360 * ((previous - point.longitude) / 360).rounded()
                        unwrapped.append(point); previous = point.longitude
                    }
                    let middle = unwrapped.map(\.longitude).reduce(0, +) / Double(unwrapped.count)
                    let shift = 360 * (((projection.bounds.west + projection.bounds.east) / 2 - middle) / 360).rounded()
                    for offset in [shift - 360, shift, shift + 360] {
                        var outline = Path()
                        for (index, point) in unwrapped.enumerated() {
                            let position = projection.point(.init(longitude: point.longitude + offset, latitude: point.latitude))
                            if index == 0 { outline.move(to: position) } else { outline.addLine(to: position) }
                        }
                        outline.closeSubpath()
                        if outline.boundingRect.intersects(frame) { path.addPath(outline) }
                    }
                }
                context.fill(path, with: .color(Color.primary.opacity(0.10)), style: FillStyle(eoFill: true))
                if settings.conflicts, let conflict = conflicts.first(where: { $0.countryID == country.id }), conflict.level > 0 {
                    conflictAreas.append((path, conflict.level))
                }
                boundaries.addPath(path)
            }
            if settings.night {
                // Shade the full frame height so the night side has no hard edge where the land data ends.
                let south = max(-90, projection.bounds.south), north = min(90, projection.bounds.north)
                let declination = sun.latitude * .pi / 180
                if south < north {
                    var night = Path()
                    let edge = declination >= 0 ? south : north
                    night.move(to: projection.point(.init(longitude: projection.bounds.west, latitude: edge)))
                    for x in stride(from: 0.0, through: Double(size.width) + 2, by: 2) {
                        let longitude = projection.bounds.west + min(x, Double(size.width)) / Double(size.width) * (projection.bounds.east - projection.bounds.west)
                        let hour = (longitude - sun.longitude) * .pi / 180
                        let latitude = atan(-cos(declination) * cos(hour) / (abs(sin(declination)) < 0.000001 ? 0.000001 : sin(declination))) * 180 / .pi
                        night.addLine(to: projection.point(.init(longitude: longitude, latitude: min(north, max(south, latitude)))))
                    }
                    night.addLine(to: projection.point(.init(longitude: projection.bounds.east, latitude: edge)))
                    night.closeSubpath()
                    context.fill(night, with: .color(.black.opacity(colorScheme == .dark ? 0.18 : 0.08)))
                }
            }
            // Alert colors stay above the night shade so low-level hotspots remain visible.
            for (path, level) in conflictAreas {
                context.fill(path, with: .color(.red.opacity([0.34, 0.50, 0.66, 0.80][level - 1])), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(.red.opacity(0.72)), lineWidth: level >= 3 ? 0.8 : 0.6)
            }
            context.stroke(boundaries, with: .color(Color.primary.opacity(0.16)), lineWidth: 0.45)
            let labels: [MapLabel] = []
            let visibleMarkers = markers.filter { $0.earthquake ? settings.earthquakes : settings.disasters }
            let visibleCyclones = settings.cyclones ? cyclones : []
            let orbit = settings.iss ? recentISSTrack(station, at: date) : []
            let position = issPosition(orbit, at: date)
            let anchors = visibleMarkers.map(\.coordinate) + visibleCyclones.compactMap(\.current) + cameras.map(\.coordinate) + (position.map { [$0] } ?? [])
            let obstacles = anchors.map { point -> CGRect in
                let center = projection.visible(point)
                return CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
            }
            func track(_ points: [MapCoordinate], color: Color, dashed: Bool, width: CGFloat = 1.2) {
                for segment in mapSegments(points) {
                    var path = Path()
                    var previous: CGPoint?
                    for point in segment {
                        let center = projection.visible(point)
                        if let previous, abs(center.x - previous.x) <= size.width / 2 { path.addLine(to: center) }
                        else { path.move(to: center) }
                        previous = center
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dashed ? [3, 3] : []))
                }
            }
            // Live layers stay text-free; the map labels countries and Africa.
            if orbit.count > 1 {
                track(orbit.map(\.coordinate), color: (colorScheme == .dark ? Color.cyan : .blue).opacity(0.38), dashed: true, width: 1)
            }
            if let position {
                let center = projection.visible(position), ink = Color.primary.opacity(0.85)
                // A tiny satellite: square body with a solar panel on each side.
                context.fill(Path(CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(ink))
                context.fill(Path(CGRect(x: center.x - 8, y: center.y - 1.5, width: 4.5, height: 3)), with: .color(ink))
                context.fill(Path(CGRect(x: center.x + 3.5, y: center.y - 1.5, width: 4.5, height: 3)), with: .color(ink))
            }
            for cyclone in visibleCyclones {
                let color: Color = cyclone.red ? .red : .orange
                track(cycloneForecast(cyclone), color: color.opacity(0.5), dashed: true, width: 1)
                if let point = cyclone.current {
                    var icon = context.resolve(Image(systemName: "hurricane"))
                    icon.shading = .color(color.opacity(0.85))
                    context.draw(icon, in: CGRect(x: projection.visible(point).x - 7, y: projection.visible(point).y - 7, width: 14, height: 14))
                }
            }
            for marker in visibleMarkers {
                let center = projection.visible(marker.coordinate)
                let radius = marker.magnitude.map { max(2.5, min(8, $0 - 2)) } ?? 4
                let color: Color = marker.red ? .red : .orange
                if let symbol = marker.symbol {
                    var icon = context.resolve(Image(systemName: symbol))
                    icon.shading = .color(color)
                    context.draw(icon, in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
            }
            for item in mapLabels(projection: projection, reserved: labels + obstacles.map { MapLabel(countryID: "obstacle", text: "", rect: $0) }) where !item.text.isEmpty {
                let dynamic = ["iss", "cyclone", "event"].contains(item.countryID) || item.countryID.hasPrefix("city:")
                let continent = item.countryID.hasPrefix("continent:")
                let text = Text(item.text).font(.system(size: 9.5, weight: continent ? .medium : .semibold)).foregroundColor(dynamic ? .primary : .primary.opacity(continent ? 0.60 : 0.72))
                if dynamic {
                    context.fill(Path(roundedRect: item.rect, cornerRadius: 2), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.82)))
                }
                context.draw(text, at: CGPoint(x: item.rect.midX, y: item.rect.midY))
            }
            for (index, city) in cameras.prefix(cameraAccents.count).enumerated() {
                let center = projection.visible(city.coordinate), color = cameraAccents[index]
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(color.opacity(0.25)))
                let dot = Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
                context.fill(dot, with: .color(color))
                context.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 0.6)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(settings.region.rawValue)地图")
        .accessibilityValue(settings.conflicts ? "按 48 小时新闻中冲突类报道的数量与严重程度估计，颜色越深越严重；非核实的冲突数据" : "国家边界和灾害位置")
    }
}

/// Decodes a stored frame at display size; widgets archive every image per timeline entry.
func cameraImage(_ url: URL, maxPixel: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}

struct CameraTile: View {
    let city: CameraCity
    let frame: CameraFrame?
    var accent: Color? = nil
    var maxPixel = 640
    var store = CameraSnapshotStore.shared
    var body: some View {
        Group {
            if let frame {
                Link(destination: frame.page) { picture }
            } else { picture }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(city.name)实景\(frame == nil ? "，暂无可用截图" : "，打开来源页面")")
    }
    var picture: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let frame, let image = cameraImage(store.imageURL(city: city.id, frame: frame), maxPixel: maxPixel) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Rectangle().fill(Color.primary.opacity(0.05))
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 4) {
                    if let accent { Circle().fill(accent).frame(width: 6, height: 6) }
                    Text(city.englishName).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule()).padding(6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct CameraGrid: View {
    var cities: [CameraCity]
    var frames: [String: [CameraFrame]]
    var index: Int
    var rows = 2
    var maxPixel = 640
    var store = CameraSnapshotStore.shared
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { column in
                        let position = row * 2 + column
                        if cities.indices.contains(position) {
                            let city = cities[position]
                            let images = frames[city.id] ?? []
                            CameraTile(city: city, frame: images.isEmpty ? nil : images[cameraRotationIndex(entry: index, city: position, count: images.count)],
                                       accent: cameraAccents[position % cameraAccents.count], maxPixel: maxPixel, store: store)
                        } else { Color.clear }
                    }
                }
            }
        }
    }
}
