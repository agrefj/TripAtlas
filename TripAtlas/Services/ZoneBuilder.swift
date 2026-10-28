import Foundation

/// Строит «зоны» городов из фото поездки.
///
/// Каждое фото относится к ближайшей геокодированной опорной точке, точки с одинаковым
/// городом объединяются. Центр зоны — среднее положение фото, радиус охватывает ~85% фото
/// (выбросы вроде снимка из такси по дороге из аэропорта не раздувают зону).
enum ZoneBuilder {

    static let minRadiusKm = 1.5
    static let maxRadiusKm = 25.0
    /// Фото дальше этого расстояния от любой опорной точки в зоны не попадают.
    static let maxAssignKm = 60.0

    static func zones(photos: [PhotoSample], anchors: [PhotoSample], places: [Place?]) -> [Place] {
        guard !anchors.isEmpty, anchors.count == places.count else { return [] }

        let inFlight = inFlightIDs(photos)
        var groups: [String: (base: Place, photos: [PhotoSample])] = [:]
        for photo in photos where !inFlight.contains(photo.id) {
            var bestIndex = 0
            var bestDistance = Double.infinity
            for (i, anchor) in anchors.enumerated() {
                let d = photo.distanceKm(to: anchor)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            guard bestDistance <= maxAssignKm, let base = places[bestIndex] else { continue }
            groups[base.id, default: (base: base, photos: [])].photos.append(photo)
        }

        return groups.values
            .map { makeZone(base: $0.base, photos: $0.photos.sorted { $0.date < $1.date }) }
            .sorted { ($0.firstVisit ?? .distantFuture) < ($1.firstVisit ?? .distantFuture) }
    }

    static func makeZone(base: Place, photos: [PhotoSample]) -> Place {
        var zone = base
        guard !photos.isEmpty else { return zone }

        let n = Double(photos.count)
        let center = Coordinate(latitude: photos.reduce(0) { $0 + $1.latitude } / n,
                                longitude: photos.reduce(0) { $0 + $1.longitude } / n)
        let distances = photos.map { $0.distanceKm(to: center) }.sorted()
        let p85 = distances[min(distances.count - 1, Int(Double(distances.count) * 0.85))]

        zone.latitude = center.latitude
        zone.longitude = center.longitude
        zone.radiusKm = min(max(p85 * 1.25, minRadiusKm), maxRadiusKm)
        zone.photoCount = photos.count
        zone.firstVisit = photos.first?.date
        zone.lastVisit = photos.last?.date
        zone.coverAssetID = photos[photos.count / 2].id
        zone.assetIDs = photos.map(\.id)
        return zone
    }

    // MARK: - Фото из самолёта

    /// Фото, снятые в движении со скоростью самолёта: и от предыдущего «далёкого» фото,
    /// и до следующего вы перемещались быстрее `minSpeedKmh`. Такие фото не относятся
    /// ни к одному городу — иначе в поездке появятся страны, над которыми вы пролетали.
    ///
    /// Проверка с обеих сторон важна: первое фото после прилёта быстрое только «слева».
    static func inFlightIDs(_ photos: [PhotoSample],
                            minSpeedKmh: Double = 350,
                            minDistanceKm: Double = 30,
                            windowHours: Double = 12) -> Set<String> {
        let sorted = photos.sorted { $0.date < $1.date }
        guard sorted.count >= 3 else { return [] }

        func isFast(_ a: PhotoSample, _ b: PhotoSample) -> Bool {
            let distance = a.distanceKm(to: b)
            let hours = max(abs(b.date.timeIntervalSince(a.date)) / 3600, 1.0 / 60)
            return distance / hours >= minSpeedKmh
        }

        /// Ближайшее по времени фото в заданную сторону, снятое дальше `minDistanceKm`.
        func farNeighbor(of i: Int, step: Int) -> PhotoSample? {
            var j = i + step
            while j >= 0, j < sorted.count {
                if abs(sorted[j].date.timeIntervalSince(sorted[i].date)) > windowHours * 3600 { return nil }
                if sorted[j].distanceKm(to: sorted[i]) >= minDistanceKm { return sorted[j] }
                j += step
            }
            return nil
        }

        var result = Set<String>()
        for i in sorted.indices {
            guard let prev = farNeighbor(of: i, step: -1), isFast(prev, sorted[i]),
                  let next = farNeighbor(of: i, step: 1), isFast(sorted[i], next) else { continue }
            result.insert(sorted[i].id)
        }
        return result
    }

    /// Раскладывает фото по уже известным городам (для поездок, созданных до появления `assetIDs`).
    static func assign(photos: [PhotoSample], to places: [Place]) -> [Place] {
        let inFlight = inFlightIDs(photos)
        var buckets: [String: [String]] = [:]
        for photo in photos.sorted(by: { $0.date < $1.date }) where !inFlight.contains(photo.id) {
            let nearest = places.min { photo.distanceKm(to: Coordinate(latitude: $0.latitude, longitude: $0.longitude))
                                     < photo.distanceKm(to: Coordinate(latitude: $1.latitude, longitude: $1.longitude)) }
            guard let nearest,
                  photo.distanceKm(to: Coordinate(latitude: nearest.latitude, longitude: nearest.longitude)) <= maxAssignKm
            else { continue }
            buckets[nearest.id, default: []].append(photo.id)
        }
        return places.map { place in
            var p = place
            p.assetIDs = buckets[place.id] ?? []
            return p
        }
    }
}
