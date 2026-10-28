import Foundation
import CoreLocation
import MapKit

/// Зона города для отображения на карте.
/// На главной карте один и тот же город из разных поездок сливается в одну зону.
struct CityZone: Identifiable, Hashable {
    let id: String
    let name: String
    let countryCode: String?
    var latitude: Double
    var longitude: Double
    var radiusKm: Double
    var visits: Int
    var photoCount: Int
    var coverAssetID: String?
    var firstVisit: Date?
    /// Порядковый номер в поездке (для страницы поездки).
    var order: Int?

    var center: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var radiusMeters: CLLocationDistance { radiusKm * 1000 }

    /// Регион, в который зона помещается с запасом.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: center,
                           latitudinalMeters: radiusMeters * 3.2,
                           longitudinalMeters: radiusMeters * 3.2)
    }

    var countryName: String? { countryCode.map(Geo.countryName(for:)) }

    // Идентичность — только по городу (важно для навигации).
    static func == (a: CityZone, b: CityZone) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(place: Place, order: Int? = nil) {
        id = place.id
        name = place.name
        countryCode = place.countryCode
        latitude = place.latitude
        longitude = place.longitude
        radiusKm = place.radiusKm ?? 3
        visits = 1
        photoCount = place.assetIDs?.count ?? place.photoCount ?? 0
        coverAssetID = place.coverAssetID
        firstVisit = place.firstVisit
        self.order = order
    }

    /// Зоны одной поездки, пронумерованные в порядке посещения.
    static func forTrip(_ trip: Trip) -> [CityZone] {
        trip.places.enumerated().map { CityZone(place: $1, order: $0 + 1) }
    }

    /// Все города всех поездок; повторные визиты увеличивают `visits`.
    static func aggregate(_ trips: [Trip]) -> [CityZone] {
        var byID: [String: CityZone] = [:]
        var order: [String] = []
        for trip in trips {
            for place in trip.places {
                let incoming = CityZone(place: place)
                guard var existing = byID[incoming.id] else {
                    byID[incoming.id] = incoming
                    order.append(incoming.id)
                    continue
                }
                // Центр — взвешенное среднее по количеству фото.
                let w1 = Double(max(existing.photoCount, 1)), w2 = Double(max(incoming.photoCount, 1))
                existing.latitude = (existing.latitude * w1 + incoming.latitude * w2) / (w1 + w2)
                existing.longitude = (existing.longitude * w1 + incoming.longitude * w2) / (w1 + w2)
                existing.radiusKm = max(existing.radiusKm, incoming.radiusKm)
                existing.visits += 1
                existing.photoCount += incoming.photoCount
                byID[incoming.id] = existing
            }
        }
        return order.compactMap { byID[$0] }
    }
}
