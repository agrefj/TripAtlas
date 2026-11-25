import SwiftUI
import Observation

/// Состояние экрана «Поделиться поездкой»: выбранный шаблон, фото, опции
/// и заранее загруженные картинки для карточек.
@Observable
@MainActor
final class ShareComposerModel {
    let subject: ShareSubject

    var template: ShareTemplate = .poster
    var options = ShareOptions()
    /// Выбранные фото по порядку; первое — обложка.
    private(set) var selectedIDs: [String] = []
    /// Фото, из которых можно выбирать (равномерно по поездке).
    let candidateIDs: [String]

    private(set) var images: [String: UIImage] = [:]
    private(set) var mapImage: UIImage?
    private(set) var silhouettes: [ShareSilhouette] = []
    private(set) var isPreparing = true

    static let maxSelection = 5

    init(subject: ShareSubject) {
        self.subject = subject
        candidateIDs = Self.pickBest(subject.assetIDs, count: 40, scores: subject.scores, first: subject.coverID)
        selectedIDs = Self.pickBest(candidateIDs, count: Self.maxSelection, scores: subject.scores, first: subject.coverID)
    }

    // MARK: - Данные для карточки

    var data: ShareCardData {
        let photos: [UIImage] = selectedIDs.compactMap { images[$0] }
        let captions: [String] = selectedIDs.filter { images[$0] != nil }.map { subject.place(containing: $0)?.name ?? "" }
        return ShareCardData(
            title: subject.title,
            dateText: subject.subtitle,
            flags: subject.flags,
            stats: subject.stats,
            timeline: subject.timeline,
            timelineNumbered: subject.timelineNumbered,
            photos: photos,
            captions: captions,
            map: mapImage,
            silhouettes: silhouettes
        )
    }

    // MARK: - Выбор фото

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }
    func position(of id: String) -> Int? { selectedIDs.firstIndex(of: id).map { $0 + 1 } }

    func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) {
            guard selectedIDs.count > 1 else { return }   // хотя бы одно фото остаётся
            selectedIDs.remove(at: index)
        } else {
            if selectedIDs.count >= Self.maxSelection { selectedIDs.removeLast() }
            selectedIDs.append(id)
            Task { await loadPhoto(id) }
        }
    }

    /// Делает фото обложкой (первым).
    func makeCover(_ id: String) {
        selectedIDs.removeAll { $0 == id }
        selectedIDs.insert(id, at: 0)
        if selectedIDs.count > Self.maxSelection { selectedIDs.removeLast() }
        Task { await loadPhoto(id) }
    }

    // MARK: - Загрузка

    func prepare() async {
        isPreparing = true
        async let photos: Void = loadSelectedPhotos()
        async let map: Void = loadMapAndSilhouettes()
        _ = await (photos, map)
        isPreparing = false
    }

    private func loadSelectedPhotos() async {
        for id in selectedIDs { await loadPhoto(id) }
    }

    private func loadPhoto(_ id: String) async {
        guard images[id] == nil else { return }
        // Обложка постера — на весь экран 1080×1920, остальным хватит поменьше.
        let side: CGFloat = id == selectedIDs.first ? 1920 : 900
        if let image = await ImageLoader.shared.image(for: id, targetSize: CGSize(width: side, height: side)) {
            images[id] = image
        }
    }

    private func loadMapAndSilhouettes() async {
        var zones: [MapSnapshotRenderer.Zone] = []
        var shapes: [ShareSilhouette] = []
        // Силуэты — у городов, где больше всего фото (для года их может быть много).
        let silhouetteIDs = Set(subject.places
            .sorted { ($0.assetIDs?.count ?? 0) > ($1.assetIDs?.count ?? 0) }
            .prefix(4).map(\.id))

        // Все границы разом: запросы идут по нескольку.
        let found = BoundaryStore.isEnabled
            ? await CityBoundaryService.boundaries(for: subject.places.map {
                CityBoundaryService.Lookup(key: $0.id, latitude: $0.latitude, longitude: $0.longitude)
            })
            : [:]
        for (index, place) in subject.places.enumerated() {
            var boundary: CityBoundary?
            if case .found(let b) = found[place.id] {
                boundary = b
                if silhouetteIDs.contains(place.id) {
                    let rings = SilhouetteBuilder.normalize(b)
                    if !rings.isEmpty { shapes.append(ShareSilhouette(id: place.id, name: place.name, rings: rings)) }
                }
            }
            zones.append(.init(place: place, boundary: boundary, order: index + 1))
        }
        silhouettes = shapes
        mapImage = await MapSnapshotRenderer.render(zones: zones, size: CGSize(width: 312, height: 300), dark: true,
                                                    numbered: subject.timelineNumbered)
    }

    // MARK: - Утилиты

    /// Лучшие кадры, равномерно по времени: массив делится на `count` отрезков,
    /// из каждого берётся фото с наибольшей оценкой. Без оценок — как `spread`.
    static func pickBest(_ ids: [String], count: Int, scores: [String: Double], first: String?) -> [String] {
        guard !scores.isEmpty, ids.count > count else { return spread(ids, count: count, first: first) }
        var result: [String] = []
        if let first, ids.contains(first) { result.append(first) }
        let slots = count - result.count
        guard slots > 0 else { return result }
        let size = Double(ids.count) / Double(slots)
        for slot in 0..<slots {
            let lower = Int((Double(slot) * size).rounded(.down))
            let upper = min(ids.count, Int((Double(slot + 1) * size).rounded(.down)))
            guard lower < upper else { continue }
            let chunk = ids[lower..<upper].filter { !result.contains($0) }
            if let best = chunk.max(by: { (scores[$0] ?? -2) < (scores[$1] ?? -2) }) { result.append(best) }
        }
        return result
    }

    /// `count` элементов, равномерно разбросанных по массиву; `first` — в начало.
    static func spread(_ ids: [String], count: Int, first: String?) -> [String] {
        guard !ids.isEmpty else { return [] }
        var result: [String] = []
        if let first, ids.contains(first) { result.append(first) }
        let step = max(1, Double(ids.count) / Double(count))
        var position = 0.0
        while result.count < count && Int(position) < ids.count {
            let id = ids[Int(position)]
            if !result.contains(id) { result.append(id) }
            position += step
        }
        return result
    }
}
