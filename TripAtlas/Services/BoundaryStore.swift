import Foundation
import MapKit
import Observation

/// Границы городов для экранов: загружает их по мере появления на карте
/// и держит готовые `MKPolygon`, чтобы не пересоздавать их при каждой перерисовке.
@Observable
@MainActor
final class BoundaryStore {
    private(set) var boundaries: [String: CityBoundary] = [:]
    private(set) var polygons: [String: [MKPolygon]] = [:]
    /// Сколько городов ещё ждут загрузки (для индикатора).
    private(set) var pending = 0
    /// Увеличивается при очистке кэша — карты перезапрашивают границы.
    private(set) var generation = 0

    @ObservationIgnored private var requested = Set<String>()

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.cityBoundaries) as? Bool ?? true
    }

    /// Регион города: по границе, если она есть, иначе по кругу.
    func region(for zone: CityZone) -> MKCoordinateRegion {
        boundaries[zone.id]?.region ?? zone.region
    }

    /// Подгружает границы для зон, которых ещё нет. Порядок зон — порядок загрузки;
    /// запросы идут по нескольку сразу, каждая граница появляется, как только пришла.
    func load(_ zones: [CityZone]) async {
        guard Self.isEnabled else { return }
        var todo: [CityBoundaryService.Lookup] = []
        for zone in zones where requested.insert(zone.id).inserted {
            todo.append(.init(key: zone.id, latitude: zone.latitude, longitude: zone.longitude))
        }
        guard !todo.isEmpty else { return }
        pending += todo.count

        // Держим в работе столько запросов, сколько пускает сервис, новые — по порядку списка.
        // Тело группы — на главном потоке, как и весь BoundaryStore: здесь меняется состояние экранов.
        await withTaskGroup(of: (String, CityBoundaryService.Result).self) { group in
            var queue = todo.makeIterator()
            for _ in 0..<CityBoundaryService.maxConcurrentRequests {
                guard let lookup = queue.next() else { break }
                group.addTask { await CityBoundaryService.fetch(lookup) }
            }
            while let (id, result) = await group.next() {
                apply(result, for: id)
                if let lookup = queue.next() {
                    group.addTask { await CityBoundaryService.fetch(lookup) }
                }
            }
        }
    }

    private func apply(_ result: CityBoundaryService.Result, for id: String) {
        pending -= 1
        switch result {
        case .found(let boundary):
            boundaries[id] = boundary
            polygons[id] = boundary.makeMKPolygons()
        case .missing:
            break
        case .failed:
            requested.remove(id)   // повторим при следующем показе карты
        }
    }

    func clear() async {
        await CityBoundaryService.shared.clearCache()
        boundaries.removeAll()
        polygons.removeAll()
        requested.removeAll()
        generation += 1
    }

    /// Заранее скачивает границы городов новой поездки (в фоне, сразу после её создания).
    nonisolated static func prefetch(_ places: [Place]) {
        guard isEnabled else { return }
        let lookups = places.map { CityBoundaryService.Lookup(key: $0.id, latitude: $0.latitude, longitude: $0.longitude) }
        Task.detached(priority: .utility) {
            _ = await CityBoundaryService.boundaries(for: lookups)
        }
    }
}
