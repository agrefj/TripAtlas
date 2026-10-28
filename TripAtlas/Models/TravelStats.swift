import Foundation

/// Сводная статистика для главного экрана.
struct TravelStats {
    let tripCount: Int
    let countryCodes: [String]
    let cityCount: Int
    let dayCount: Int
    let photoCount: Int
    let distanceKm: Double

    var countryCount: Int { countryCodes.count }

    init(trips: [Trip]) {
        tripCount = trips.count
        countryCodes = trips.flatMap(\.countryCodes).uniqued()
        cityCount = Set(trips.flatMap(\.cityKeys)).count
        dayCount = trips.reduce(0) { $0 + $1.dayCount }
        photoCount = trips.reduce(0) { $0 + $1.assetIdentifiers.count }
        distanceKm = trips.reduce(0) { $0 + $1.distanceKm }
    }
}

/// Генерация человекочитаемого названия поездки.
enum TripTitleBuilder {
    static func title(for places: [Place], start: Date) -> String {
        let countries = places.compactMap(\.countryCode).uniqued()
        let cities = places.compactMap(\.city).uniqued()

        if countries.count <= 1 {
            switch cities.count {
            case 0: return places.first?.country ?? fallback(start)
            case 1: return cities[0]
            case 2: return "\(cities[0]) и \(cities[1])"
            default: return "\(cities[0]), \(cities[1]) и ещё \(cities.count - 2)"
            }
        }

        let names = countries.map(Geo.countryName(for:))
        if names.count <= 3 { return names.joined(separator: " · ") }
        return names.prefix(2).joined(separator: " · ") + " и ещё \(names.count - 2)"
    }

    static func fallback(_ start: Date) -> String {
        "Поездка, " + start.formatted(.dateTime.month(.wide).year())
    }
}
