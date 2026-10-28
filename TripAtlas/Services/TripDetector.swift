import Foundation

/// Минимальные данные о фото, нужные для распознавания поездок.
struct PhotoSample: Hashable, Sendable {
    let id: String
    let date: Date
    let latitude: Double
    let longitude: Double

    var coordinate: Coordinate { .init(latitude: latitude, longitude: longitude) }

    func distanceKm(to c: Coordinate) -> Double {
        Geo.distanceKm(latitude, longitude, c.latitude, c.longitude)
    }

    func distanceKm(to s: PhotoSample) -> Double {
        Geo.distanceKm(latitude, longitude, s.latitude, s.longitude)
    }
}

/// Находит поездки в хронологическом потоке геотегированных фото.
///
/// Алгоритм:
/// 1. Определяем «дом» — ячейку сетки ~5×5 км, где снято больше всего *разных дней*.
///    Дом считается по каждому году отдельно (люди переезжают), с общим запасным вариантом.
/// 2. Фото дальше `homeRadiusKm` от дома — «в отъезде».
/// 3. Подряд идущие фото «в отъезде» склеиваются в поездку. Поездка обрывается, если
///    - между фото прошло больше `maxGapHours`, или
///    - между ними было фото «дома», и следующее «отъездное» фото снято позже чем через `homeReturnHours`
///      (одиночное фото дома посреди поездки — например, с неверной геометкой — поездку не рвёт).
/// 4. Поездки с числом фото меньше `minPhotos` отбрасываются.
struct TripDetector: Sendable {

    struct Config: Sendable, Equatable {
        var homeRadiusKm: Double = 80
        var maxGapHours: Double = 72
        var homeReturnHours: Double = 12
        var minPhotos: Int = 5
        var homeCellDegrees: Double = 0.05
        var minHomeDaysPerYear: Int = 15

        static func fromDefaults(_ d: UserDefaults = .standard) -> Config {
            var c = Config()
            if d.object(forKey: SettingsKeys.homeRadiusKm) != nil { c.homeRadiusKm = d.double(forKey: SettingsKeys.homeRadiusKm) }
            if d.object(forKey: SettingsKeys.maxGapHours) != nil { c.maxGapHours = d.double(forKey: SettingsKeys.maxGapHours) }
            if d.object(forKey: SettingsKeys.minPhotos) != nil { c.minPhotos = d.integer(forKey: SettingsKeys.minPhotos) }
            return c
        }
    }

    struct Candidate: Identifiable, Hashable, Sendable {
        let id: String
        let photos: [PhotoSample]
        let route: [PhotoSample]

        var start: Date { photos[0].date }
        var end: Date { photos[photos.count - 1].date }
        var cover: PhotoSample { photos[photos.count / 2] }
        var dayCount: Int { Date.dayCount(from: start, to: end) }
    }

    let config: Config

    init(config: Config = .init()) {
        self.config = config
    }

    func detect(_ samples: [PhotoSample]) -> [Candidate] {
        let sorted = samples.sorted { $0.date < $1.date }
        let homes = HomeResolver(samples: sorted, config: config)
        guard homes.hasAnyHome else { return [] }

        var result: [Candidate] = []
        var current: [PhotoSample] = []
        var lastHomeDate: Date?

        func flush() {
            if current.count >= config.minPhotos {
                result.append(Candidate(id: current[0].id, photos: current, route: Self.simplifiedRoute(current)))
            }
            current.removeAll()
        }

        for sample in sorted {
            guard let home = homes.home(for: sample.date) else { continue }
            let isAway = sample.distanceKm(to: home) > config.homeRadiusKm

            if isAway {
                if let last = current.last {
                    let gap = sample.date.timeIntervalSince(last.date)
                    let returnedHome = lastHomeDate.map {
                        $0 > last.date && sample.date.timeIntervalSince($0) > config.homeReturnHours * 3600
                    } ?? false
                    if gap > config.maxGapHours * 3600 || returnedHome { flush() }
                }
                current.append(sample)
            } else {
                lastHomeDate = sample.date
            }
        }
        flush()
        return result
    }

    // MARK: - Утилиты

    /// Прореживает маршрут: убирает точки ближе `minStepKm` к предыдущей и ограничивает количество.
    static func simplifiedRoute(_ photos: [PhotoSample], minStepKm: Double = 1, maxPoints: Int = 400) -> [PhotoSample] {
        var out: [PhotoSample] = []
        for p in photos {
            if let last = out.last, p.distanceKm(to: last) < minStepKm { continue }
            out.append(p)
        }
        if out.count > maxPoints {
            let step = Double(out.count) / Double(maxPoints)
            out = (0..<maxPoints).map { out[Int(Double($0) * step)] }
        }
        return out
    }

    /// Точки для геокодирования: не ближе `minSpacingKm` друг к другу, не больше `limit`.
    static func placeAnchors(_ photos: [PhotoSample], minSpacingKm: Double = 15, limit: Int = 25) -> [PhotoSample] {
        var anchors: [PhotoSample] = []
        for p in photos {
            guard !anchors.contains(where: { $0.distanceKm(to: p) < minSpacingKm }) else { continue }
            anchors.append(p)
            if anchors.count >= limit { break }
        }
        return anchors
    }
}

/// Определяет «дом» пользователя по годам.
struct HomeResolver {
    private var byYear: [Int: Coordinate] = [:]
    private var global: Coordinate?

    var hasAnyHome: Bool { global != nil }

    init(samples: [PhotoSample], config: TripDetector.Config) {
        global = Self.home(in: samples, cell: config.homeCellDegrees, minDays: 1)
        let groups = Dictionary(grouping: samples) { Calendar.current.component(.year, from: $0.date) }
        for (year, group) in groups {
            if let h = Self.home(in: group, cell: config.homeCellDegrees, minDays: config.minHomeDaysPerYear) {
                byYear[year] = h
            }
        }
    }

    func home(for date: Date) -> Coordinate? {
        byYear[Calendar.current.component(.year, from: date)] ?? global
    }

    private struct Cell: Hashable { let x: Int; let y: Int }
    private struct Accumulator { var days = Set<Int>(); var lat = 0.0; var lon = 0.0; var n = 0 }

    static func home(in samples: [PhotoSample], cell: Double, minDays: Int) -> Coordinate? {
        var cells: [Cell: Accumulator] = [:]
        for s in samples {
            let key = Cell(x: Int((s.latitude / cell).rounded(.down)), y: Int((s.longitude / cell).rounded(.down)))
            let day = Int(s.date.timeIntervalSinceReferenceDate / 86_400)
            var acc = cells[key, default: Accumulator()]
            acc.days.insert(day)
            acc.lat += s.latitude
            acc.lon += s.longitude
            acc.n += 1
            cells[key] = acc
        }
        guard let best = cells.values.max(by: { $0.days.count < $1.days.count }),
              best.days.count >= minDays, best.n > 0 else { return nil }
        return Coordinate(latitude: best.lat / Double(best.n), longitude: best.lon / Double(best.n))
    }
}

enum SettingsKeys {
    static let homeRadiusKm = "homeRadiusKm"
    static let maxGapHours = "maxGapHours"
    static let minPhotos = "minPhotos"
}
