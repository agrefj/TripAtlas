import XCTest
@testable import TripAtlas

final class ZoneBuilderTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(_ id: String, _ lat: Double, _ lon: Double, hour: Double) -> PhotoSample {
        PhotoSample(id: id, date: base.addingTimeInterval(hour * 3600), latitude: lat, longitude: lon)
    }

    private func place(_ city: String, _ lat: Double, _ lon: Double) -> Place {
        Place(city: city, country: "Италия", countryCode: "IT", latitude: lat, longitude: lon)
    }

    func testGroupsPhotosIntoCityZones() {
        // Рим: 8 фото в радиусе ~3 км, Флоренция: 5 фото.
        let rome = (0..<8).map { photo("r\($0)", 41.90 + Double($0) * 0.003, 12.49, hour: Double($0)) }
        let florence = (0..<5).map { photo("f\($0)", 43.77, 11.25 + Double($0) * 0.002, hour: 30 + Double($0)) }
        let photos = rome + florence

        let anchors = TripDetector.placeAnchors(photos, minSpacingKm: 10)
        let places: [Place?] = anchors.map { $0.id.hasPrefix("r") ? place("Рим", $0.latitude, $0.longitude)
                                                                  : place("Флоренция", $0.latitude, $0.longitude) }

        let zones = ZoneBuilder.zones(photos: photos, anchors: anchors, places: places)

        XCTAssertEqual(zones.map(\.name), ["Рим", "Флоренция"])          // в порядке посещения
        XCTAssertEqual(zones[0].photoCount, 8)
        XCTAssertEqual(zones[1].photoCount, 5)
        XCTAssertEqual(zones[0].radiusKm ?? 0, ZoneBuilder.minRadiusKm, accuracy: 2)
        XCTAssertLessThanOrEqual(zones[0].radiusKm ?? 0, ZoneBuilder.maxRadiusKm)
    }

    func testAggregateCountsRepeatVisits() {
        let p = Place(city: "Рим", country: "Италия", countryCode: "IT",
                      latitude: 41.9, longitude: 12.49, radiusKm: 4, photoCount: 10)
        func trip(_ sig: String) -> Trip {
            Trip(signature: sig, title: "Рим", startDate: base, endDate: base, assetIdentifiers: [],
                 assetDates: [], coverAssetIdentifier: nil, route: [], places: [p])
        }
        let zones = CityZone.aggregate([trip("a"), trip("b")])
        XCTAssertEqual(zones.count, 1)
        XCTAssertEqual(zones[0].visits, 2)
        XCTAssertEqual(zones[0].photoCount, 20)
    }

    func testDetectsInFlightPhotos() {
        // Москва → (2 фото из самолёта над Польшей) → Париж; полёт ~4 ч, ~2500 км.
        let photos = [
            photo("msk1", 55.75, 37.61, hour: 0),
            photo("msk2", 55.97, 37.41, hour: 1),          // аэропорт
            photo("air1", 52.20, 21.00, hour: 2.5),        // над Варшавой
            photo("air2", 50.90, 12.00, hour: 3.5),        // над Германией
            photo("par1", 49.00, 2.55, hour: 5),           // прилёт
            photo("par2", 48.86, 2.35, hour: 6),
        ]
        XCTAssertEqual(ZoneBuilder.inFlightIDs(photos), ["air1", "air2"])
    }

    func testUnassignRemovesEmptyPlace() {
        var warsaw = Place(city: "Варшава", country: "Польша", countryCode: "PL", latitude: 52.2, longitude: 21)
        warsaw.assetIDs = ["air1"]
        var paris = Place(city: "Париж", country: "Франция", countryCode: "FR", latitude: 48.86, longitude: 2.35)
        paris.assetIDs = ["p1", "p2"]
        let places = [warsaw, paris]
        let trip = Trip(signature: "t", title: TripTitleBuilder.title(for: places, start: base),
                        startDate: base, endDate: base, assetIdentifiers: ["air1", "p1", "p2"],
                        assetDates: [], coverAssetIdentifier: nil, route: [], places: places)

        trip.unassign("air1")

        XCTAssertEqual(trip.countryCodes, ["FR"])
        XCTAssertEqual(trip.title, "Париж")             // автоназвание пересобрано
        XCTAssertEqual(trip.assetIdentifiers.count, 3)  // фото остались в поездке
    }

    func testRussianPlural() {
        XCTAssertEqual(RU.cities(1), "1 город")
        XCTAssertEqual(RU.cities(3), "3 города")
        XCTAssertEqual(RU.cities(11), "11 городов")
        XCTAssertEqual(RU.cities(22), "22 города")
        XCTAssertEqual(RU.days(25), "25 дней")
    }
}
