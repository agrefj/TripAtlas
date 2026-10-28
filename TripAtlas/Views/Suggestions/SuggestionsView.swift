import SwiftUI
import SwiftData

/// Найденные поездки: создать страницу или скрыть.
struct SuggestionsView: View {
    @Environment(TripImporter.self) private var importer
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var creatingAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Я просмотрел ваши фото и нашёл поездки. Создайте для них страницы — с картой городов и фотографиями по дням.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(importer.candidates) { candidate in
                        CandidateCard(
                            candidate: candidate,
                            isCreating: importer.creatingIDs.contains(candidate.id),
                            onCreate: { Task { await importer.createTrip(from: candidate, in: context) } },
                            onDismiss: { withAnimation(.snappy) { importer.dismiss(candidate, in: context) } }
                        )
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
                        .scrollFade()
                    }
                }
                .padding(20)
                .animation(.snappy, value: importer.candidates.map(\.id))
            }
            .overlay {
                if importer.candidates.isEmpty {
                    ContentUnavailableView("Всё разобрано", systemImage: "checkmark.seal",
                                           description: Text("Новые поездки появятся здесь после следующего сканирования."))
                }
            }
            .navigationTitle("Новые поездки")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if creatingAll {
                        ProgressView()
                    } else {
                        Button("Создать все") {
                            creatingAll = true
                            Task {
                                await importer.createAll(in: context)
                                creatingAll = false
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(importer.candidates.isEmpty)
                    }
                }
            }
        }
    }
}

private struct CandidateCard: View {
    let candidate: TripDetector.Candidate
    let isCreating: Bool
    let onCreate: () -> Void
    let onDismiss: () -> Void

    @State private var placeName: String?
    @State private var flag = ""

    private var previewIDs: [String] {
        let p = candidate.photos
        guard p.count > 3 else { return p.map(\.id) }
        return [p[p.count / 2].id, p[0].id, p[p.count - 1].id]
    }

    private var dateText: String {
        (candidate.start..<max(candidate.start, candidate.end))
            .formatted(.interval.day().month(.abbreviated).year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collage
                .frame(height: 190)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(placeName.map { "\(flag) \($0)" } ?? "Определяю место…")
                        .font(Theme.title(22))
                        .lineLimit(1)
                        .redacted(reason: placeName == nil ? .placeholder : [])
                    Text("\(dateText) · \(RU.days(candidate.dayCount)) · \(RU.photos(candidate.photos.count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button(action: onCreate) {
                        Group {
                            if isCreating {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("Определяю города…")
                                }
                            } else {
                                Label("Создать страницу", systemImage: "plus")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Theme.sunset, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)

                    Button(action: onDismiss) {
                        Image(systemName: "eye.slash")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 46, height: 46)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                    .accessibilityLabel("Скрыть")
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .card(cornerRadius: 26)
        .task(id: candidate.id) {
            let c = candidate.cover
            let place = await GeocodingService.shared.place(latitude: c.latitude, longitude: c.longitude)
            flag = place.countryCode.map(Geo.flag(for:)) ?? ""
            placeName = place.displayName.isEmpty ? "Поездка" : place.displayName
        }
    }

    /// Крупное фото слева и два маленьких справа.
    private var collage: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let ids = previewIDs
            HStack(spacing: spacing) {
                PhotoThumbnail(assetID: ids.first, size: 400)
                    .frame(width: ids.count > 1 ? geo.size.width * 0.64 : geo.size.width)
                if ids.count > 1 {
                    VStack(spacing: spacing) {
                        ForEach(ids.dropFirst(), id: \.self) { id in
                            PhotoThumbnail(assetID: id, size: 220)
                        }
                    }
                }
            }
        }
    }
}
