import XCTest
@testable import TripAtlas

final class SharingTests: XCTestCase {

    func testSilhouetteIsNormalizedToUnitSquare() {
        let ring = [Coordinate(latitude: 41.85, longitude: 12.45), Coordinate(latitude: 41.85, longitude: 12.65),
                    Coordinate(latitude: 41.95, longitude: 12.65), Coordinate(latitude: 41.95, longitude: 12.45)]
        let boundary = CityBoundary(osmID: "t/1", name: "Рим", polygons: [.init(outer: ring, holes: [])])
        let rings = SilhouetteBuilder.normalize(boundary)
        let points = rings.flatMap { $0 }

        XCTAssertEqual(rings.count, 1)
        XCTAssertTrue(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        // Широкий прямоугольник: заполняет всю ширину и центрирован по высоте.
        XCTAssertEqual(points.map(\.x).min() ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.x).max() ?? -1, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(points.map(\.y).min() ?? 0, 0.1)
    }

    @MainActor
    func testSpreadPicksCoverFirstAndEvenlyDistributes() {
        let ids = (0..<100).map { "p\($0)" }
        let picked = ShareComposerModel.spread(ids, count: 5, first: "p42")
        XCTAssertEqual(picked.count, 5)
        XCTAssertEqual(picked.first, "p42")
        XCTAssertEqual(Set(picked).count, 5)
        XCTAssertEqual(ShareComposerModel.spread(["a", "b"], count: 5, first: nil), ["a", "b"])
    }

    @MainActor
    func testYearSubjectAggregatesTripsOfThatYear() {
        let cal = Calendar.current
        func date(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 10))! }
        func place(_ city: String, _ code: String, _ ids: [String]) -> Place {
            var p = Place(city: city, country: nil, countryCode: code, latitude: 41.9, longitude: 12.5)
            p.assetIDs = ids
            return p
        }
        func trip(_ sig: String, _ start: Date, _ places: [Place]) -> Trip {
            let ids = places.flatMap { $0.assetIDs ?? [] }
            return Trip(signature: sig, title: sig, startDate: start, endDate: start.addingTimeInterval(2 * 86_400),
                        assetIdentifiers: ids, assetDates: ids.map { _ in start }, coverAssetIdentifier: ids.first,
                        route: [], places: places)
        }
        let trips = [
            trip("Рим", date(2026, 5), [place("Рим", "IT", ["a", "b"])]),
            trip("Снова Рим", date(2026, 9), [place("Рим", "IT", ["c"]), place("Ницца", "FR", ["d"])]),
            trip("Токио", date(2025, 4), [place("Токио", "JP", ["e"])]),
        ]

        XCTAssertEqual(ShareSubject.years(in: trips), [2026, 2025])

        let year = ShareSubject.year(2026, trips: trips)
        XCTAssertEqual(year.title, "2026")
        XCTAssertEqual(year.stops.map(\.name), ["Рим", "Снова Рим"])
        XCTAssertEqual(year.places.map(\.name), ["Рим", "Ницца"])          // Рим — одна зона
        XCTAssertEqual(year.places.first?.assetIDs, ["a", "b", "c"])
        XCTAssertEqual(year.stats.map(\.value), ["2", "2", "2", "6"])       // поездки, страны, города, дни
        XCTAssertEqual(year.place(containing: "d")?.name, "Ницца")
        XCTAssertFalse(year.timelineNumbered)
    }

    @MainActor
    func testPickBestTakesTopScoredPhotoFromEachSegment() {
        let ids = (0..<10).map { "p\($0)" }
        let scores: [String: Double] = ["p1": 0.9, "p3": -0.5, "p4": 0.2, "p8": 0.7, "p9": 0.1]
        XCTAssertEqual(ShareComposerModel.pickBest(ids, count: 2, scores: scores, first: nil), ["p1", "p8"])
        XCTAssertEqual(ShareComposerModel.pickBest(ids, count: 2, scores: scores, first: "p0").first, "p0")
    }

    @MainActor
    func testHideAndRestoreUtilityPhotos() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        var rome = Place(city: "Рим", country: "Италия", countryCode: "IT", latitude: 41.9, longitude: 12.5)
        rome.assetIDs = ["a", "receipt", "b"]
        rome.coverAssetID = "receipt"
        let trip = Trip(signature: "t", title: "Рим", startDate: day, endDate: day,
                        assetIdentifiers: ["a", "receipt", "b"],
                        assetDates: [day, day.addingTimeInterval(60), day.addingTimeInterval(120)],
                        coverAssetIdentifier: "receipt", route: [], places: [rome])
        trip.photoScores = ["a": 0.1, "b": 0.8]

        trip.hide(["receipt"])
        XCTAssertEqual(trip.assetIdentifiers, ["a", "b"])
        XCTAssertEqual(trip.coverAssetIdentifier, "b")                 // лучшее из оставшихся
        XCTAssertEqual(trip.places[0].assetIDs, ["a", "b"])
        XCTAssertEqual(trip.hiddenAssets.map(\.id), ["receipt"])

        trip.restore(["receipt"])
        XCTAssertEqual(trip.assetIdentifiers, ["a", "receipt", "b"])   // на своём месте по времени
        XCTAssertEqual(trip.places[0].assetIDs?.contains("receipt"), true)
        XCTAssertTrue(trip.hiddenAssets.isEmpty)
    }
}
