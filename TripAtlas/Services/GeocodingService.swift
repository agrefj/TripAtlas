import Foundation
import CoreLocation

/// Обратное геокодирование с кэшем на диске и последовательной очередью.
///
/// Apple ограничивает частоту запросов CLGeocoder (порядка 50 в минуту),
/// поэтому запросы выполняются строго по одному с паузой между ними.
actor GeocodingService {
    static let shared = GeocodingService()

    private var cache: [String: Place] = [:]
    private var tail: Task<Void, Never>?
    private var lastRequest = Date.distantPast
    private let minInterval: TimeInterval = 1.3

    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("geocode-cache.json")
    }()

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Place].self, from: data) {
            cache = decoded
        }
    }

    private static func key(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.2f,%.2f", lat, lon)   // ~1 км
    }

    func place(latitude: Double, longitude: Double) async -> Place {
        if let cached = cache[Self.key(latitude, longitude)] { return cached }

        // Ставим запрос в очередь за предыдущим.
        let previous = tail
        let task = Task { () -> Place in
            await previous?.value
            return await self.lookup(latitude: latitude, longitude: longitude)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func lookup(latitude: Double, longitude: Double) async -> Place {
        let key = Self.key(latitude, longitude)
        if let cached = cache[key] { return cached }

        let wait = minInterval - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = Date()

        var place = Place(city: nil, country: nil, countryCode: nil, latitude: latitude, longitude: longitude)
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude),
                preferredLocale: Locale.current
            )
            if let mark = marks.first {
                place.city = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea
                place.country = mark.country
                place.countryCode = mark.isoCountryCode
            }
            cache[key] = place
            persist()
        } catch {
            // Сеть недоступна или превышен лимит — не кэшируем, попробуем позже.
        }
        return place
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
