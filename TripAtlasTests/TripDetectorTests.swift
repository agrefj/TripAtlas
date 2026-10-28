import XCTest
@testable import TripAtlas

final class TripDetectorTests: XCTestCase {

    private let moscow = (55.7558, 37.6173)
    private let paris = (48.8566, 2.3522)
    private let rome = (41.9028, 12.4964)
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ id: String, _ place: (Double, Double), dayOffset: Double, jitter: Double = 0) -> PhotoSample {
        PhotoSample(id: id, date: base.addingTimeInterval(dayOffset * 86_400),
                    latitude: place.0 + jitter, longitude: place.1 + jitter)
    }

    /// 40 дней дома с фото каждый день.
    private func homeDays(_ range: ClosedRange<Int>) -> [PhotoSample] {
        range.map { sample("home-\($0)", moscow, dayOffset: Double($0), jitter: Double($0 % 3) * 0.001) }
    }

    func testDetectsSingleTrip() {
        var photos = homeDays(0...19)
        photos += (0..<10).map { sample("paris-\($0)", paris, dayOffset: 20 + Double($0) * 0.4, jitter: Double($0) * 0.002) }
        photos += homeDays(25...40)

        let trips = TripDetector().detect(photos)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.photos.count, 10)
        XCTAssertEqual(trips.first?.id, "paris-0")
    }

    func testSplitsTripsSeparatedByHome() {
        var photos = homeDays(0...19)
        photos += (0..<6).map { sample("paris-\($0)", paris, dayOffset: 20 + Double($0) * 0.3) }
        photos += [sample("home-x", moscow, dayOffset: 22.5)]
        photos += (0..<6).map { sample("rome-\($0)", rome, dayOffset: 23.5 + Double($0) * 0.3) }
        photos += homeDays(26...40)

        let trips = TripDetector().detect(photos)
        XCTAssertEqual(trips.map(\.id), ["paris-0", "rome-0"])
    }

    func testIgnoresTooSmallTrips() {
        var photos = homeDays(0...19)
        photos += (0..<3).map { sample("paris-\($0)", paris, dayOffset: 20 + Double($0) * 0.1) }
        photos += homeDays(21...40)

        XCTAssertTrue(TripDetector().detect(photos).isEmpty)
    }

    func testPlaceAnchorsAreSpaced() {
        let photos = (0..<20).map { sample("p\($0)", paris, dayOffset: Double($0) * 0.01, jitter: Double($0) * 0.0005) }
        XCTAssertEqual(TripDetector.placeAnchors(photos).count, 1)
    }
}
