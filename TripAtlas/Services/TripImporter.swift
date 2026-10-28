import Foundation
import SwiftData
import Observation

/// Сканирует медиатеку, предлагает новые поездки и создаёт из них страницы.
@Observable
@MainActor
final class TripImporter {

    enum Phase: Equatable {
        case idle, scanning, ready, denied
    }

    private(set) var phase: Phase = .idle
    private(set) var candidates: [TripDetector.Candidate] = []
    private(set) var creatingIDs: Set<String> = []
    private(set) var lastScan: Date?

    // MARK: - Сканирование

    func scan(existing: [Trip], dismissed: Set<String>) async {
        guard phase != .scanning else { return }

        var status = PhotoLibraryService.status
        if status == .notDetermined { status = await PhotoLibraryService.requestAccess() }
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }

        phase = .scanning
        let config = TripDetector.Config.fromDefaults()
        let found = await Task.detached(priority: .userInitiated) {
            TripDetector(config: config).detect(PhotoLibraryService.fetchGeotaggedSamples())
        }.value

        let existingRanges = existing.map { ($0.startDate, $0.endDate) }
        let existingSignatures = Set(existing.map(\.signature))

        candidates = found
            .filter { candidate in
                !dismissed.contains(candidate.id)
                && !existingSignatures.contains(candidate.id)
                && !existingRanges.contains { candidate.start <= $0.1 && candidate.end >= $0.0 }
            }
            .sorted { $0.start > $1.start }

        lastScan = .now
        phase = .ready
    }

    // MARK: - Действия с предложениями

    func createTrip(from candidate: TripDetector.Candidate, in context: ModelContext) async {
        guard !creatingIDs.contains(candidate.id) else { return }
        creatingIDs.insert(candidate.id)
        defer { creatingIDs.remove(candidate.id) }

        // 1. Геокодируем опорные точки (не ближе 10 км друг к другу).
        let anchors = TripDetector.placeAnchors(candidate.photos, minSpacingKm: 10, limit: 30)
        var anchorPlaces: [Place?] = []
        for anchor in anchors {
            let place = await GeocodingService.shared.place(latitude: anchor.latitude, longitude: anchor.longitude)
            anchorPlaces.append(place.city != nil || place.country != nil ? place : nil)
        }

        // 2. Раскладываем все фото по городам и строим зоны.
        let places = ZoneBuilder.zones(photos: candidate.photos, anchors: anchors, places: anchorPlaces)

        let trip = Trip(
            signature: candidate.id,
            title: TripTitleBuilder.title(for: places, start: candidate.start),
            startDate: candidate.start,
            endDate: candidate.end,
            assetIdentifiers: candidate.photos.map(\.id),
            assetDates: candidate.photos.map(\.date),
            coverAssetIdentifier: candidate.cover.id,
            route: candidate.route.map {
                RoutePoint(latitude: $0.latitude, longitude: $0.longitude, date: $0.date, assetID: $0.id)
            },
            places: places
        )
        context.insert(trip)
        try? context.save()
        candidates.removeAll { $0.id == candidate.id }
    }

    func createAll(in context: ModelContext) async {
        for candidate in candidates {
            await createTrip(from: candidate, in: context)
        }
    }

    func dismiss(_ candidate: TripDetector.Candidate, in context: ModelContext) {
        context.insert(DismissedSuggestion(signature: candidate.id))
        try? context.save()
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Для поездок из прошлой версии: раскладывает фото по городам, если это ещё не сделано.
    func backfillAssignments(_ trip: Trip, in context: ModelContext) async {
        guard !trip.places.isEmpty, trip.places.contains(where: { $0.assetIDs == nil }) else { return }
        let ids = trip.assetIdentifiers
        let samples = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.samples(for: ids)
        }.value
        trip.places = ZoneBuilder.assign(photos: samples, to: trip.places)
        try? context.save()
    }

    /// Убирает страну из всех поездок (например, если фото из самолёта определились неверно).
    func removeCountryEverywhere(_ code: String, trips: [Trip], in context: ModelContext) {
        for trip in trips where trip.countryCodes.contains(code) {
            trip.removeCountry(code)
        }
        try? context.save()
    }

    /// Удаляет поездку и запоминает её подпись, чтобы она не предлагалась снова.
    func delete(_ trip: Trip, in context: ModelContext) {
        context.insert(DismissedSuggestion(signature: trip.signature))
        context.delete(trip)
        try? context.save()
    }
}
