import XCTest
@testable import TripAtlas

final class CityBoundaryServiceTests: XCTestCase {

    // MARK: - Запрос

    /// nginx на сервере пропускает только format=jsonv2, zoom=10 и polygon_geojson=1 (Server/geo/nginx.conf).
    func testRequestIsExactlyWhatTheServerAllows() throws {
        let url = CityBoundaryService.requestURL(latitude: 41.902784, longitude: 12.496366)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "geo.agstatus.online")
        XCTAssertEqual(components.path, "/reverse")

        // nginx сверяет строку запроса целиком, по регулярному выражению, с этим порядком параметров.
        XCTAssertEqual(components.percentEncodedQuery,
                       "format=jsonv2&lat=41.90278&lon=12.49637&zoom=10&polygon_geojson=1&polygon_threshold=0.0005")
    }

    /// Те же граничные случаи, что разрешает регулярное выражение в nginx.conf: знак, три цифры долготы.
    func testRequestFormatsExtremeCoordinates() throws {
        let west = CityBoundaryService.requestURL(latitude: -33.868820, longitude: -151.209296)
        XCTAssertEqual(URLComponents(url: west, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "format=jsonv2&lat=-33.86882&lon=-151.20930&zoom=10&polygon_geojson=1&polygon_threshold=0.0005")
        let north = CityBoundaryService.requestURL(latitude: 78.2232, longitude: 15.6267)
        XCTAssertEqual(URLComponents(url: north, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "format=jsonv2&lat=78.22320&lon=15.62670&zoom=10&polygon_geojson=1&polygon_threshold=0.0005")
    }

    // MARK: - Какие ошибки включают паузу

    func testOfflineErrorsDoNotPauseTheServer() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
                     .callIsActive, .networkConnectionLost, .cancelled] {
            XCTAssertFalse(CityBoundaryService.isServerFailure(URLError(code)), "\(code)")
        }
    }

    func testServerSideErrorsPauseTheServer() {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost, .badServerResponse,
                     .secureConnectionFailed] {
            XCTAssertTrue(CityBoundaryService.isServerFailure(URLError(code)), "\(code)")
        }
    }

    func testUserAgentNamesTheApp() {
        XCTAssertTrue(CityBoundaryService.userAgent.hasPrefix("TripAtlas/"))
        XCTAssertTrue(CityBoundaryService.userAgent.hasSuffix("; iOS)"))
    }

    // MARK: - Пауза после ошибок

    func testPauseDoublesFromHalfAMinuteUpToAnHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var backoff = RetryBackoff()
        var pauses: [TimeInterval] = []
        for _ in 1...9 {
            backoff.recordFailure(at: now)
            pauses.append(backoff.resumeAt!.timeIntervalSince(now))
        }
        XCTAssertEqual(pauses, [30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
    }

    func testRequestsWaitForThePauseToEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var backoff = RetryBackoff()
        XCTAssertTrue(backoff.allows(at: now))

        backoff.recordFailure(at: now)
        XCTAssertFalse(backoff.allows(at: now.addingTimeInterval(29)))
        XCTAssertTrue(backoff.allows(at: now.addingTimeInterval(30)))
    }

    func testSuccessEndsThePause() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var backoff = RetryBackoff()
        backoff.recordFailure(at: now)
        backoff.recordFailure(at: now)
        backoff.recordSuccess()
        XCTAssertTrue(backoff.allows(at: now))
        XCTAssertEqual(backoff.failures, 0)

        backoff.recordFailure(at: now)   // счёт начинается заново
        XCTAssertEqual(backoff.resumeAt?.timeIntervalSince(now), 30)
    }

    func testRetryAfterCanLengthenThePauseButNotBeyondAnHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        var longer = RetryBackoff()
        longer.recordFailure(at: now, retryAfter: 600)
        XCTAssertEqual(longer.resumeAt?.timeIntervalSince(now), 600)

        var shorter = RetryBackoff()
        shorter.recordFailure(at: now, retryAfter: 5)
        XCTAssertEqual(shorter.resumeAt?.timeIntervalSince(now), 30)

        var huge = RetryBackoff()
        huge.recordFailure(at: now, retryAfter: 86_400)
        XCTAssertEqual(huge.resumeAt?.timeIntervalSince(now), 3600)

        var negative = RetryBackoff()
        negative.recordFailure(at: now, retryAfter: -10)
        XCTAssertEqual(negative.resumeAt?.timeIntervalSince(now), 30)
    }

    func testManyFailuresStayAtAnHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var backoff = RetryBackoff()
        for _ in 0..<200 { backoff.recordFailure(at: now) }
        XCTAssertEqual(backoff.resumeAt?.timeIntervalSince(now), 3600)
    }

    /// Запросы идут по три сразу: ошибки тех, что уже были в пути, когда началась пауза,
    /// не удлиняют её, а их запоздалая удача её не снимает.
    func testAnswersToRequestsSentBeforeThePauseDoNotChangeIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sent = now.addingTimeInterval(-0.2)
        var backoff = RetryBackoff()
        backoff.recordFailure(at: now, sentAt: sent)
        backoff.recordFailure(at: now.addingTimeInterval(0.05), sentAt: sent.addingTimeInterval(0.08))
        backoff.recordFailure(at: now.addingTimeInterval(0.1), sentAt: sent.addingTimeInterval(0.16))
        XCTAssertEqual(backoff.failures, 1)
        XCTAssertEqual(backoff.resumeAt?.timeIntervalSince(now), 30)

        backoff.recordSuccess(sentAt: sent.addingTimeInterval(0.1))
        XCTAssertFalse(backoff.allows(at: now.addingTimeInterval(1)))

        // Запрос, ушедший уже после паузы: его ошибка удваивает паузу, его удача снимает её.
        let later = now.addingTimeInterval(31)
        backoff.recordFailure(at: later.addingTimeInterval(0.1), sentAt: later)
        XCTAssertEqual(backoff.failures, 2)
        XCTAssertEqual(backoff.resumeAt?.timeIntervalSince(later.addingTimeInterval(0.1)), 60)

        let afterSecondPause = later.addingTimeInterval(61)
        backoff.recordSuccess(sentAt: afterSecondPause)
        XCTAssertTrue(backoff.allows(at: afterSecondPause))
        XCTAssertEqual(backoff.failures, 0)
    }

    func testLateRetryAfterStillLengthensThePause() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var backoff = RetryBackoff()
        backoff.recordFailure(at: now, sentAt: now.addingTimeInterval(-0.1))
        backoff.recordFailure(at: now.addingTimeInterval(0.05), retryAfter: 600, sentAt: now.addingTimeInterval(-0.05))
        XCTAssertEqual(backoff.failures, 1)
        XCTAssertEqual(backoff.resumeAt!.timeIntervalSince(now), 600.05, accuracy: 1e-6)
    }

    // MARK: - Темп запросов

    func testPacerSpacesStartsAndSavesNothingUpWhileIdle() {
        let now = ContinuousClock.now
        var pacer = RequestPacer(interval: .milliseconds(100))
        XCTAssertEqual(pacer.reserve(at: now), now)
        XCTAssertEqual(pacer.reserve(at: now), now + .milliseconds(100))
        XCTAssertEqual(pacer.reserve(at: now), now + .milliseconds(200))

        // После простоя следующий запрос уходит сразу, но всплеска из «накопленного» времени нет.
        let later = now + .seconds(10)
        XCTAssertEqual(pacer.reserve(at: later), later)
        XCTAssertEqual(pacer.reserve(at: later), later + .milliseconds(100))
    }

    /// Темп втрое выше прежних 4 запросов в секунду и вдвое ниже лимита nginx (30 в секунду
    /// с адреса, Server/geo/nginx.conf): два телефона в одной сети в него не упираются.
    func testClientPaceIsThreeTimesTheOldOneAndFitsTheServerLimit() {
        XCTAssertEqual(1 / CityBoundaryService.requestInterval, 12, accuracy: 1e-9)
        XCTAssertEqual(CityBoundaryService.maxConcurrentRequests, 3)
        XCTAssertLessThanOrEqual(2 / CityBoundaryService.requestInterval, 30)
    }

    // MARK: - Очередь запросов (сервер подменён)

    func testRequestsGoThreeAtATimeTwelvePerSecond() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TransportLog()
        let service = CityBoundaryService(transport: { request in
            await log.begin()
            try await Task.sleep(nanoseconds: 200_000_000)   // сервер отвечает за 0,2 с
            await log.end()
            return Self.reply(to: request, status: 200)
        }, directory: directory)

        let started = Date()
        let results = await CityBoundaryService.boundaries(for: Self.lookups(12), from: service)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(results.values.filter { if case .missing = $0 { true } else { false } }.count, 12)
        let maxInFlight = await log.maxInFlight
        XCTAssertLessThanOrEqual(maxInFlight, 3)
        XCTAssertGreaterThan(maxInFlight, 1)
        // Не чаще 12 в секунду: 12 запросов начинаются не быстрее чем за 11/12 с.
        let starts = await log.starts
        XCTAssertEqual(starts.count, 12)
        XCTAssertGreaterThanOrEqual(starts.last!.timeIntervalSince(starts.first!), 11.0 / 12 - 0.01)
        // Раньше — по одному раз в 0,25 с: 11 × 0,25 + 0,2 ≈ 2,95 с. Теперь 11/12 + 0,2 ≈ 1,1 с.
        XCTAssertLessThan(elapsed, 1.6)
    }

    func testTheSameCityAskedTwiceAtOnceIsFetchedOnce() async {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TransportLog()
        let service = CityBoundaryService(transport: { request in
            await log.begin()
            try await Task.sleep(nanoseconds: 100_000_000)
            await log.end()
            return Self.reply(to: request, status: 200)
        }, directory: directory)

        async let first = service.boundary(key: "rome", latitude: 41.9, longitude: 12.5)
        async let second = service.boundary(key: "rome", latitude: 41.9, longitude: 12.5)
        _ = await (first, second)
        let calls = await log.starts.count
        XCTAssertEqual(calls, 1)
    }

    /// Карта, предзагрузка и карточка могут просить границы одновременно: в пути всё равно не больше трёх.
    func testSeveralCallersTogetherStillGetThreeRequestsInFlight() async {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TransportLog()
        let service = CityBoundaryService(transport: { request in
            await log.begin()
            try await Task.sleep(nanoseconds: 500_000_000)   // дольше, чем 3 × 1/12 с: без лимита было бы 6 в пути
            await log.end()
            return Self.reply(to: request, status: 200)
        }, directory: directory)

        let all = Self.lookups(12)
        async let a = CityBoundaryService.boundaries(for: Array(all[0..<4]), from: service)
        async let b = CityBoundaryService.boundaries(for: Array(all[4..<8]), from: service)
        async let c = CityBoundaryService.boundaries(for: Array(all[8..<12]), from: service)
        let (ra, rb, rc) = await (a, b, c)

        XCTAssertEqual(ra.count + rb.count + rc.count, 12)
        let maxInFlight = await log.maxInFlight
        XCTAssertEqual(maxInFlight, 3)
        let calls = await log.starts.count
        XCTAssertEqual(calls, 12)
    }

    /// 429 от сервера ставит на паузу всю очередь, и тех, кто ждёт места: в сеть уходят только
    /// запросы, которые уже были в пути.
    func testAServerErrorPausesTheRestOfTheQueue() async {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TransportLog()
        let service = CityBoundaryService(transport: { request in
            await log.begin()
            try await Task.sleep(nanoseconds: 300_000_000)
            await log.end()
            return Self.reply(to: request, status: 429)
        }, directory: directory)

        let all = Self.lookups(12)
        async let a = CityBoundaryService.boundaries(for: Array(all[0..<6]), from: service)
        async let b = CityBoundaryService.boundaries(for: Array(all[6..<12]), from: service)
        let (ra, rb) = await (a, b)

        let failed = Array(ra.values) + Array(rb.values)
        XCTAssertEqual(failed.filter { if case .failed = $0 { true } else { false } }.count, 12)
        let calls = await log.starts.count
        XCTAssertEqual(calls, 3)
    }

    // MARK: - Помощники

    /// Ответ сервера для места без границы (только точка) — сервис запомнит его как «нет границы».
    private static func reply(to request: URLRequest, status: Int) -> (Data, URLResponse) {
        let body = #"{"osm_type":"node","osm_id":5,"geojson":{"type":"Point","coordinates":[12.5,41.9]}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    private static func lookups(_ count: Int) -> [CityBoundaryService.Lookup] {
        (0..<count).map { .init(key: "test-city-\($0)", latitude: 40 + Double($0) / 10, longitude: 12) }
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CityBoundaryServiceTests-\(UUID().uuidString)")
    }
}

/// Записывает, когда подменённый сервер получал запросы и сколько их было в пути одновременно.
private actor TransportLog {
    private(set) var starts: [Date] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0

    func begin() {
        starts.append(Date())
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func end() { inFlight -= 1 }
}
