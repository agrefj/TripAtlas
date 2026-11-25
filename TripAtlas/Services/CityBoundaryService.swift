import Foundation
import CryptoKit

/// Загружает границы городов с нашего сервера и кэширует их на диске.
///
/// Сервер — свой Nominatim 5.3 на данных OpenStreetMap: только административные границы
/// и населённые пункты, без поиска и обновлений (см. `Server/geo/README.md`). Публичный
/// nominatim.openstreetmap.org не подходит: его лимит — 1 запрос в секунду на всё приложение.
/// Данные OSM — по лицензии ODbL: на картах и в видео с границами — подпись «© OpenStreetMap».
actor CityBoundaryService {
    static let shared = CityBoundaryService()

    static let endpoint = URL(string: "https://geo.agstatus.online/reverse")!
    static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "TripAtlas/\(version) (\(build); iOS)"
    }()

    /// Темп запросов с одного устройства: начинаются не чаще 12 раз в секунду, в пути — не больше
    /// трёх. Это втрое быстрее прежнего «по одному, раз в 0,25 с»; по одному так не выйдет —
    /// ответ сам идёт около 0,1 с. Сервер пускает 30 запросов в секунду с одного адреса
    /// (Server/geo/nginx.conf), так что запас остаётся и для двух телефонов в одной сети.
    static let requestInterval: TimeInterval = 1.0 / 12
    static let maxConcurrentRequests = 3

    /// Как запрос уходит в сеть; тесты подставляют свой.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Result: Sendable {
        case found(CityBoundary)
        /// Границы нет (у места только точка) — показываем круг.
        case missing
        /// Ошибка сети — попробуем позже, в кэш не пишем.
        case failed
    }

    private enum CacheEntry: Codable {
        case found(CityBoundary)
        case missing(Date)
    }

    /// Через сколько перепроверять места без границы.
    private let missingTTL: TimeInterval = 30 * 86_400

    private let transport: Transport
    private let directory: URL
    private var memory: [String: CacheEntry] = [:]
    /// Запросы в пути: второй вызов для того же города ждёт первый, а не шлёт свой.
    private var inFlight: [String: Task<Result, Never>] = [:]
    private var pacer = RequestPacer(interval: .seconds(CityBoundaryService.requestInterval))
    /// Сколько запросов заняли место: ждут своего времени или уже в сети.
    private var running = 0
    /// Кто ждёт места, в порядке очереди.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Пауза после ошибок сервера: пока она идёт, запросы не уходят в сеть.
    private var backoff = RetryBackoff()

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
         directory: URL? = nil) {
        self.transport = transport
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CityBoundaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    // MARK: - API

    /// Граница города `key` (ключ города), найденная по точке внутри него.
    func boundary(key: String, latitude: Double, longitude: Double) async -> Result {
        if let cached = cachedResult(for: key) { return cached }
        if let pending = inFlight[key] { return await pending.value }

        let task = Task { await self.fetchIfNeeded(key: key, latitude: latitude, longitude: longitude) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    func clearCache() {
        memory.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Кэш

    private func fileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    private func cachedResult(for key: String) -> Result? {
        if memory[key] == nil,
           let data = try? Data(contentsOf: fileURL(for: key)),
           let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            memory[key] = entry
        }
        switch memory[key] {
        case .found(let boundary): return .found(boundary)
        case .missing(let date) where Date().timeIntervalSince(date) < missingTTL: return .missing
        default: return nil
        }
    }

    private func store(_ entry: CacheEntry, for key: String) {
        memory[key] = entry
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: fileURL(for: key), options: .atomic)
        }
    }

    // MARK: - Сеть

    /// Запрос города по точке. nginx на сервере пропускает только эту строку запроса целиком —
    /// в этом порядке и с этими значениями (Server/geo/nginx.conf), так что менять её можно
    /// только вместе с настройкой сервера.
    static func requestURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "format", value: "jsonv2"),
            .init(name: "lat", value: String(format: "%.5f", latitude)),
            .init(name: "lon", value: String(format: "%.5f", longitude)),
            .init(name: "zoom", value: "10"),                  // уровень города
            .init(name: "polygon_geojson", value: "1"),
            .init(name: "polygon_threshold", value: "0.0005"), // упрощение на сервере (~50 м)
        ]
        return components.url!
    }

    private func fetchIfNeeded(key: String, latitude: Double, longitude: Double) async -> Result {
        if let cached = cachedResult(for: key) { return cached }
        // Сервер недавно не ответил — не дёргаем его: город пока покажется кругом,
        // а карта попросит границу снова при следующем показе.
        guard backoff.allows(at: Date()) else { return .failed }

        guard await acquireSlot() else { return .failed }

        var request = URLRequest(url: Self.requestURL(latitude: latitude, longitude: longitude), timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // Паузу отмечаем до того, как отдать место: следующий в очереди уже должен её видеть.
        let sentAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            if Self.isServerFailure(error) { backoff.recordFailure(at: Date(), sentAt: sentAt) }
            releaseSlot()
            return .failed
        }
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            backoff.recordFailure(at: Date(), retryAfter: retryAfter, sentAt: sentAt)
            releaseSlot()
            return .failed
        }
        backoff.recordSuccess(sentAt: sentAt)
        releaseSlot()

        do {
            if let boundary = try OSMBoundaryParser.parse(data) {
                store(.found(boundary), for: key)
                return .found(boundary)
            } else {
                store(.missing(Date()), for: key)
                return .missing
            }
        } catch {
            return .failed   // ответ не разобрался: сервер жив, паузу не включаем, в кэш не пишем
        }
    }

    // MARK: - Очередь

    /// Ждёт своей очереди: в пути не больше `maxConcurrentRequests` запросов, и начинаются они
    /// не чаще, чем раз в `requestInterval`. Места раздаются в порядке вызовов.
    /// `false` — пока ждали, ответ на другой запрос включил паузу; место тогда уже отдано.
    private func acquireSlot() async -> Bool {
        if running < Self.maxConcurrentRequests {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }   // место передаст releaseSlot
        }
        guard backoff.allows(at: Date()) else {
            releaseSlot()
            return false
        }
        let start = pacer.reserve(at: .now)
        if start > .now { try? await Task.sleep(until: start, clock: .continuous) }
        guard backoff.allows(at: Date()) else {
            releaseSlot()
            return false
        }
        return true
    }

    private func releaseSlot() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension CityBoundaryService {
    /// Включать ли паузу из-за этой ошибки. Нет: если запрос не ушёл с устройства (нет сети,
    /// авиарежим, роуминг, экономия трафика) или задачу отменили — сервер тут ни при чём,
    /// а пауза держала бы границы выключенными ещё долго после того, как сеть вернулась.
    static func isServerFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return true }
        if urlError.networkUnavailableReason != nil { return false }
        switch urlError.code {
        case .cancelled, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive, .networkConnectionLost:
            return false
        default:
            return true
        }
    }
}

extension CityBoundaryService {
    /// Город, для которого нужна граница.
    struct Lookup: Sendable {
        let key: String
        let latitude: Double
        let longitude: Double
    }

    /// Граница одного города — для задач группы: ключ и результат.
    static func fetch(_ lookup: Lookup, from service: CityBoundaryService = .shared) async -> (String, Result) {
        (lookup.key, await service.boundary(key: lookup.key, latitude: lookup.latitude, longitude: lookup.longitude))
    }

    /// Границы многих городов сразу: держит в работе столько запросов, сколько сервис пускает
    /// одновременно, добавляет следующие по порядку списка и возвращает все результаты по ключам.
    /// Экранам, которым граница нужна сразу по приходу, — `BoundaryStore.load`.
    static func boundaries(for lookups: [Lookup], from service: CityBoundaryService = .shared) async -> [String: Result] {
        await withTaskGroup(of: (String, Result).self) { group in
            var results: [String: Result] = [:]
            var queue = lookups.makeIterator()
            for _ in 0..<maxConcurrentRequests {
                guard let lookup = queue.next() else { break }
                group.addTask { await fetch(lookup, from: service) }
            }
            while let (key, result) = await group.next() {
                results[key] = result
                if let lookup = queue.next() {
                    group.addTask { await fetch(lookup, from: service) }
                }
            }
            return results
        }
    }
}

/// Темп запросов: каждый следующий начинается не раньше, чем через `interval` после предыдущего.
/// Часы монотонные: если на телефоне перевести время назад, очередь не встанет.
struct RequestPacer {
    let interval: Duration
    private(set) var nextStart: ContinuousClock.Instant?

    /// Когда можно начать запрос, готовый к отправке в `now`. Это время сразу занимается.
    mutating func reserve(at now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let start = nextStart.map { max(now, $0) } ?? now
        nextStart = start + interval
        return start
    }
}

/// Пауза после ошибок сервера границ: 30 с, затем 1, 2, 4… минуты, но не больше часа.
/// `Retry-After` из ответа может её удлинить (до того же часа). Удачный ответ сбрасывает паузу.
///
/// Запросы идут по нескольку сразу, поэтому ответы на те, что ушли до начала паузы (`sentAt`),
/// её не меняют: их ошибки — от той же причины и не удлиняют паузу, а удача ещё не значит,
/// что сервер снова в порядке. Без `sentAt` ответ считается свежим.
struct RetryBackoff {
    static let base: TimeInterval = 30
    static let cap: TimeInterval = 3600

    private(set) var failures = 0
    private(set) var resumeAt: Date?
    /// Когда началась текущая пауза.
    private(set) var pausedAt: Date?

    func allows(at now: Date) -> Bool { resumeAt.map { now >= $0 } ?? true }

    mutating func recordFailure(at now: Date, retryAfter: TimeInterval? = nil, sentAt: Date? = nil) {
        let requested = min(max(retryAfter ?? 0, 0), Self.cap)
        if isStale(sentAt) {
            // Пауза уже идёт из-за той же ошибки; просьбу сервера подождать дольше всё же учтём.
            if requested > 0, let resumeAt { self.resumeAt = max(resumeAt, now.addingTimeInterval(requested)) }
            return
        }
        failures += 1
        let delay = min(Self.base * pow(2, Double(min(failures - 1, 16))), Self.cap)
        pausedAt = now
        resumeAt = now.addingTimeInterval(max(delay, requested))
    }

    mutating func recordSuccess(sentAt: Date? = nil) {
        guard !isStale(sentAt) else { return }
        failures = 0
        resumeAt = nil
        pausedAt = nil
    }

    /// Запрос ушёл раньше, чем началась текущая пауза.
    private func isStale(_ sentAt: Date?) -> Bool {
        guard let sentAt, let pausedAt else { return false }
        return sentAt < pausedAt
    }
}
