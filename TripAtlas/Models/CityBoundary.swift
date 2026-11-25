import Foundation
import MapKit

/// Административная граница города из OpenStreetMap.
struct CityBoundary: Codable, Hashable, Sendable {
    struct Polygon: Codable, Hashable, Sendable {
        var outer: [Coordinate]
        var holes: [[Coordinate]]
    }

    /// Например, "relation/2555133".
    var osmID: String
    var name: String?
    var polygons: [Polygon]
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double
    var areaKm2: Double

    init(osmID: String, name: String?, polygons: [Polygon]) {
        self.osmID = osmID
        self.name = name
        self.polygons = polygons
        let all = polygons.flatMap(\.outer)
        minLatitude = all.map(\.latitude).min() ?? 0
        maxLatitude = all.map(\.latitude).max() ?? 0
        minLongitude = all.map(\.longitude).min() ?? 0
        maxLongitude = all.map(\.longitude).max() ?? 0
        areaKm2 = polygons.reduce(0) { sum, p in
            sum + GeoPolygon.areaKm2(p.outer) - p.holes.reduce(0) { $0 + GeoPolygon.areaKm2($1) }
        }
    }

    /// Регион карты, в который граница помещается с запасом.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: .init(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: .init(latitudeDelta: max((maxLatitude - minLatitude) * 1.3, 0.02),
                        longitudeDelta: max((maxLongitude - minLongitude) * 1.3, 0.02))
        )
    }

    func contains(_ c: Coordinate) -> Bool {
        polygons.contains { p in
            GeoPolygon.contains(p.outer, c) && !p.holes.contains { GeoPolygon.contains($0, c) }
        }
    }

    /// Полигоны для MapKit (с вырезами, если они есть).
    func makeMKPolygons() -> [MKPolygon] {
        polygons.map { p in
            let outer = p.outer.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let holes = p.holes.map { ring in
                let coords = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                return MKPolygon(coordinates: coords, count: coords.count)
            }
            return MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes)
        }
    }
}

// MARK: - Геометрия

enum GeoPolygon {
    /// Площадь кольца в км² (локальная равнопромежуточная проекция — точности хватает для городов).
    static func areaKm2(_ ring: [Coordinate]) -> Double {
        guard ring.count >= 3 else { return 0 }
        let lat0 = ring.map(\.latitude).reduce(0, +) / Double(ring.count) * .pi / 180
        let kx = 111.32 * cos(lat0), ky = 110.57
        var sum = 0.0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            sum += (a.longitude * kx) * (b.latitude * ky) - (b.longitude * kx) * (a.latitude * ky)
        }
        return abs(sum) / 2
    }

    /// Точка внутри кольца (метод луча).
    static func contains(_ ring: [Coordinate], _ p: Coordinate) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude),
               p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Упрощение линии (Дуглас — Пейкер) до не более чем `maxPoints` точек.
    static func simplify(_ ring: [Coordinate], maxPoints: Int) -> [Coordinate] {
        guard ring.count > maxPoints else { return ring }
        var epsilon = 0.0001   // ~10 м
        var result = ring
        while result.count > maxPoints && epsilon < 1 {
            result = douglasPeucker(ring, epsilon: epsilon)
            epsilon *= 2
        }
        return result
    }

    static func douglasPeucker(_ points: [Coordinate], epsilon: Double) -> [Coordinate] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]

        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDistance = 0.0, index = start
            for i in (start + 1)..<end {
                let d = perpendicularDistance(points[i], points[start], points[end])
                if d > maxDistance { maxDistance = d; index = i }
            }
            if maxDistance > epsilon {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func perpendicularDistance(_ p: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
        let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else {
            return ((p.longitude - a.longitude) * (p.longitude - a.longitude)
                  + (p.latitude - a.latitude) * (p.latitude - a.latitude)).squareRoot()
        }
        return abs(dy * p.longitude - dx * p.latitude + b.longitude * a.latitude - b.latitude * a.longitude) / length
    }
}

// MARK: - Разбор ответа Nominatim

/// Разбирает ответ `/reverse?...&polygon_geojson=1` сервиса Nominatim (наш сервер — тот же Nominatim).
enum OSMBoundaryParser {
    /// Больше — это уже регион или область, а не город.
    static let maxAreaKm2 = 15_000.0
    static let maxPointsPerRing = 700
    /// Отбрасываем крошечные острова и анклавы.
    static let minPolygonAreaKm2 = 0.05

    /// `nil` — у места нет полигональной границы (только точка) или она слишком велика.
    static func parse(_ data: Data) throws -> CityBoundary? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if json["error"] != nil { return nil }
        guard let geojson = json["geojson"] as? [String: Any],
              let type = geojson["type"] as? String else { return nil }

        let raw: [[[[Double]]]]
        switch type {
        case "Polygon":
            guard let c = geojson["coordinates"] as? [[[Double]]] else { return nil }
            raw = [c]
        case "MultiPolygon":
            guard let c = geojson["coordinates"] as? [[[[Double]]]] else { return nil }
            raw = c
        default:
            return nil   // Point, LineString — границы нет
        }

        func ring(_ r: [[Double]]) -> [Coordinate] {
            let coords = r.compactMap { $0.count >= 2 ? Coordinate(latitude: $0[1], longitude: $0[0]) : nil }
            return GeoPolygon.simplify(coords, maxPoints: maxPointsPerRing)
        }

        let polygons: [CityBoundary.Polygon] = raw.compactMap { rings in
            guard let first = rings.first else { return nil }
            let outer = ring(first)
            guard outer.count >= 3, GeoPolygon.areaKm2(outer) >= minPolygonAreaKm2 else { return nil }
            return .init(outer: outer, holes: rings.dropFirst().map(ring).filter { $0.count >= 3 })
        }
        guard !polygons.isEmpty else { return nil }

        let osmType = json["osm_type"] as? String ?? "osm"
        let osmID = (json["osm_id"] as? NSNumber)?.stringValue ?? "?"
        let boundary = CityBoundary(osmID: "\(osmType)/\(osmID)", name: json["name"] as? String, polygons: polygons)
        guard boundary.areaKm2 <= maxAreaKm2 else { return nil }
        return boundary
    }
}
