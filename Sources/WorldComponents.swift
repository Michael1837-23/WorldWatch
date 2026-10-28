import SwiftUI
import AppKit
import ImageIO

struct MapSettings: Sendable {
    var region = MapRegion.selected
    var earthquakes = WorldPreferences.enabled("mapEarthquakes")
    var disasters = WorldPreferences.enabled("mapDisasters")
    var night = WorldPreferences.enabled("mapNight")
    var hotspots = WorldPreferences.enabled("mapHotspots")
}

struct WorldMapCanvas: View {
    let markers: [MapMarker]
    let hotspots: [MapHotspot]
    let sun: MapCoordinate
    var settings = MapSettings()
    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let projection = MapProjection(bounds: settings.region.bounds, size: size)
            let frame = CGRect(origin: .zero, size: size)
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
                context.stroke(path, with: .color(Color.primary.opacity(0.18)), lineWidth: 0.5)
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
                    context.fill(night, with: .color(.black.opacity(0.22)))
                }
            }
            if settings.hotspots {
                for hotspot in hotspots {
                    let center = projection.visible(hotspot.coordinate)
                    let radius = min(22, 4 + sqrt(Double(hotspot.count)) * 2.5)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.orange.opacity(0.28)))
                }
            }
            for marker in markers {
                guard marker.earthquake ? settings.earthquakes : settings.disasters else { continue }
                let center = projection.visible(marker.coordinate)
                let radius = marker.magnitude.map { max(2.5, min(8, $0 - 2)) } ?? 3.5
                let color: Color = marker.red ? .red : .orange
                if let magnitude = marker.magnitude, magnitude >= 6.5 {
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius - 4, y: center.y - radius - 4, width: radius * 2 + 8, height: radius * 2 + 8)), with: .color(color.opacity(0.18)))
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
            }
            for label in mapLabels(projection: projection) {
                context.draw(Text(label.text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary),
                             at: CGPoint(x: label.rect.midX, y: label.rect.midY))
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(settings.region.rawValue)地图")
        .accessibilityValue(settings.hotspots ? "新闻热点按新闻提及量估计，非核实的冲突数据" : "国家边界和灾害位置")
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
                Text(city.englishName).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
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
                            CameraTile(city: city, frame: images.isEmpty ? nil : images[cameraRotationIndex(entry: index, city: position, count: images.count)], maxPixel: maxPixel, store: store)
                        } else { Color.clear }
                    }
                }
            }
        }
    }
}
