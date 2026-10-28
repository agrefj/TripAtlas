import Foundation
import SwiftData
import CoreLocation

/// Точка маршрута поездки (взята из фото). Используется для подсчёта расстояния.
struct RoutePoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var date: Date
    var assetID: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var plain: Coordinate { .init(latitude: latitude, longitude: longitude) }
}

/// Город, в котором вы были во время поездки, и его «зона» на карте.
struct Place: Codable, Hashable, Identifiable {
    var city: String?
    var country: String?
    var countryCode: String?
    /// Центр зоны — среднее положение фото, снятых в этом городе.
    var latitude: Double
    var longitude: Double
    /// Радиус зоны: охватывает ~85% фото города.
    var radiusKm: Double?
    var photoCount: Int?
    var firstVisit: Date?
    var lastVisit: Date?
    var coverAssetID: String?
    /// Фото, отнесённые к этому городу. `nil` — у поездок, созданных до появления поля
    /// (заполняется при первом открытии, см. `TripImporter.backfillAssignments`).
    var assetIDs: [String]?

    var id: String { cityKey ?? "\(latitude),\(longitude)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// Ключ уникальности города: одноимённые города в разных странах различаются.
    var cityKey: String? { city.map { "\($0)|\(countryCode ?? "")" } }

    var name: String { city ?? country ?? "Без названия" }

    var displayName: String {
        [city, country].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Один день поездки — для группировки фото.
struct TripDay: Identifiable {
    let id: Date          // начало дня
    let index: Int        // «День N»
    let assetIDs: [String]
    let cities: [Place]
}

@Model
final class Trip {
    /// Идентификатор первого фото поездки — стабильная «подпись» найденной поездки.
    @Attribute(.unique) var signature: String
    var title: String
    var startDate: Date
    var endDate: Date
    var assetIdentifiers: [String]
    /// Даты фото, параллельно `assetIdentifiers`.
    var assetDates: [Date] = []
    var coverAssetIdentifier: String?
    var route: [RoutePoint]
    var places: [Place]
    var createdAt: Date

    init(signature: String,
         title: String,
         startDate: Date,
         endDate: Date,
         assetIdentifiers: [String],
         assetDates: [Date],
         coverAssetIdentifier: String?,
         route: [RoutePoint],
         places: [Place]) {
        self.signature = signature
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.assetIdentifiers = assetIdentifiers
        self.assetDates = assetDates
        self.coverAssetIdentifier = coverAssetIdentifier
        self.route = route
        self.places = places
        self.createdAt = .now
    }

    // MARK: - Производные значения (не хранятся)

    var countryCodes: [String] { places.compactMap(\.countryCode).uniqued() }
    var cityKeys: [String] { places.compactMap(\.cityKey).uniqued() }
    var dayCount: Int { Date.dayCount(from: startDate, to: endDate) }
    var distanceKm: Double { Geo.pathLengthKm(route.map(\.plain)) }
    var flags: String { countryCodes.map(Geo.flag(for:)).joined() }

    var dateRangeText: String {
        (startDate..<max(startDate, endDate))
            .formatted(.interval.day().month(.abbreviated).year())
    }

    /// Фото, сгруппированные по дням, с городами каждого дня.
    var days: [TripDay] {
        guard !assetDates.isEmpty, assetDates.count == assetIdentifiers.count else {
            return [TripDay(id: startDate.startOfDay, index: 1, assetIDs: assetIdentifiers, cities: places)]
        }
        let groups = Dictionary(grouping: zip(assetIdentifiers, assetDates)) { $0.1.startOfDay }
        return groups.keys.sorted().map { day in
            let ids = (groups[day] ?? []).sorted { $0.1 < $1.1 }.map(\.0)
            let cities = places.filter { place in
                guard let first = place.firstVisit, let last = place.lastVisit else { return false }
                return first.startOfDay <= day && day <= last.startOfDay
            }
            return TripDay(id: day, index: Date.dayCount(from: startDate, to: day), assetIDs: ids, cities: cities)
        }
    }
}

// MARK: - Исправление мест

extension Trip {
    /// Город, к которому отнесено фото.
    func place(containing assetID: String) -> Place? {
        places.first { $0.assetIDs?.contains(assetID) == true }
    }

    /// Удаляет места. Если название было сгенерировано автоматически — пересобирает его.
    func removePlaces(where shouldRemove: (Place) -> Bool) {
        let autoTitle = TripTitleBuilder.title(for: places, start: startDate)
        places.removeAll(where: shouldRemove)
        if title == autoTitle {
            title = TripTitleBuilder.title(for: places, start: startDate)
        }
    }

    func removePlace(id: String) { removePlaces { $0.id == id } }

    func removeCountry(_ code: String) { removePlaces { $0.countryCode == code } }

    /// Отвязывает фото от его города (фото остаётся в поездке).
    /// Если в городе не осталось фото — город удаляется из поездки.
    func unassign(_ assetID: String) {
        guard let index = places.firstIndex(where: { $0.assetIDs?.contains(assetID) == true }) else { return }
        var place = places[index]
        place.assetIDs?.removeAll { $0 == assetID }
        let remaining = place.assetIDs ?? []
        if remaining.isEmpty {
            removePlace(id: place.id)
            return
        }
        place.photoCount = remaining.count
        if place.coverAssetID == assetID { place.coverAssetID = remaining[remaining.count / 2] }
        places[index] = place
    }
}

/// Предложение, которое пользователь скрыл, — чтобы не показывать его снова.
@Model
final class DismissedSuggestion {
    @Attribute(.unique) var signature: String
    var dismissedAt: Date

    init(signature: String) {
        self.signature = signature
        self.dismissedAt = .now
    }
}
