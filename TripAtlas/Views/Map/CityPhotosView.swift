import SwiftUI
import SwiftData

/// Страница города: все фото оттуда, сгруппированные по поездкам.
/// Открывается нажатием на точку города на карте.
struct CityPhotosView: View {
    let zone: CityZone
    /// Поездки, в которых искать этот город (все — с общей карты, одна — со страницы поездки).
    let trips: [Trip]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(TripImporter.self) private var importer

    @State private var contentWidth: CGFloat = 0
    @State private var viewer: ViewerTarget?
    @State private var confirmRemove = false

    private struct ViewerTarget: Identifiable {
        let id = UUID()
        let trip: Trip
        let index: Int
    }

    private struct Visit: Identifiable {
        let trip: Trip
        let place: Place
        var id: String { trip.signature }
    }

    /// Поездки с этим городом и фото города в каждой из них (новые сверху).
    private var visits: [Visit] {
        trips
            .compactMap { trip in trip.places.first { $0.id == zone.id }.map { Visit(trip: trip, place: $0) } }
            .sorted { $0.trip.startDate > $1.trip.startDate }
    }

    private var photoCount: Int { visits.reduce(0) { $0 + ($1.place.assetIDs?.count ?? 0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header.padding(.horizontal, 20)

                ForEach(visits) { visit in
                    visitSection(visit.trip, place: visit.place)
                }

                if visits.isEmpty {
                    ContentUnavailableView("Город убран", systemImage: "mappin.slash",
                                           description: Text("В поездках больше нет фото из этого места."))
                }
            }
            .padding(.vertical, 20)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(zone.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Я здесь не был", systemImage: "mappin.slash", role: .destructive) {
                        confirmRemove = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .confirmationDialog("Убрать «\(zone.name)»?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Убрать из \(visits.count == 1 ? "поездки" : "всех поездок")", role: .destructive) {
                for visit in visits { visit.trip.removePlace(id: zone.id) }
                try? context.save()
                dismiss()
            }
        } message: {
            Text("Город пропадёт с карты и из статистики. Сами фото останутся в поездках.")
        }
        .fullScreenCover(item: $viewer) { target in
            PhotoViewer(assetIDs: target.trip.assetIdentifiers, index: target.index, trip: target.trip)
        }
        .task {
            for trip in trips where trip.places.contains(where: { $0.id == zone.id }) {
                await importer.backfillAssignments(trip, in: context)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(zone.name)
                .font(Theme.title(38))
            Text(subtitle)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let code = zone.countryCode, let name = zone.countryName { parts.append("\(Geo.flag(for: code)) \(name)") }
        parts.append(RU.photos(photoCount))
        if visits.count > 1 { parts.append(RU.count(visits.count, "визит", "визита", "визитов")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func visitSection(_ trip: Trip, place: Place) -> some View {
        let ids = place.assetIDs ?? []
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title)
                    .font(Theme.title(22))
                    .lineLimit(1)
                Text("\(dateText(place, trip)) · \(RU.photos(ids.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            if place.assetIDs == nil {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if contentWidth > 0 {
                PhotoMosaic(ids: ids, width: contentWidth - 24) { id in
                    if let index = trip.assetIdentifiers.firstIndex(of: id) {
                        viewer = ViewerTarget(trip: trip, index: index)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func dateText(_ place: Place, _ trip: Trip) -> String {
        let start = place.firstVisit ?? trip.startDate
        let end = place.lastVisit ?? trip.endDate
        return (start..<max(start, end)).formatted(.interval.day().month(.abbreviated).year())
    }
}
