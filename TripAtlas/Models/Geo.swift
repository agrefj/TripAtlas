import Foundation

/// Простая координата без зависимостей от CoreLocation — удобно для логики и тестов.
struct Coordinate: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double
}

enum Geo {
    /// Расстояние по большому кругу (формула гаверсинусов), км.
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    static func pathLengthKm(_ coords: [Coordinate]) -> Double {
        zip(coords, coords.dropFirst()).reduce(0) { sum, pair in
            sum + distanceKm(pair.0.latitude, pair.0.longitude, pair.1.latitude, pair.1.longitude)
        }
    }

    /// "FR" -> 🇫🇷
    static func flag(for countryCode: String?) -> String {
        guard let code = countryCode, code.count == 2 else { return "🏳️" }
        var result = ""
        for scalar in code.uppercased().unicodeScalars {
            if let flagScalar = UnicodeScalar(127397 + scalar.value) {
                result.unicodeScalars.append(flagScalar)
            }
        }
        return result
    }

    static func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

extension Sequence where Element: Hashable {
    /// Убирает дубликаты, сохраняя порядок.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    /// Количество календарных дней между датами включительно.
    static func dayCount(from start: Date, to end: Date) -> Int {
        let days = Calendar.current.dateComponents([.day], from: start.startOfDay, to: end.startOfDay).day ?? 0
        return max(1, days + 1)
    }
}
