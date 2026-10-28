import SwiftUI
import SwiftData
import MapKit

struct TripDetailView: View {
    @Bindable var trip: Trip

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(TripImporter.self) private var importer

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var focusedZone: String?
    @State private var showFullMap = false
    @State private var viewerStart: PhotoSelection?
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var confirmDelete = false
    @State private var contentWidth: CGFloat = 0
    @State private var openedZone: CityZone?
    @State private var removeCandidate: RemovalTarget?

    private enum RemovalTarget: Identifiable {
        case city(CityZone), country(String)
        var id: String {
            switch self {
            case .city(let z): "city-" + z.id
            case .country(let c): "country-" + c
            }
        }
        var title: String {
            switch self {
            case .city(let z): "Убрать «\(z.name)» из поездки?"
            case .country(let c): "Убрать \(Geo.flag(for: c)) \(Geo.countryName(for: c)) из поездки?"
            }
        }
    }

    private let heroHeight: CGFloat = 460
    private var zones: [CityZone] { CityZone.forTrip(trip) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                VStack(alignment: .leading, spacing: 34) {
                    statsPanel
                        .padding(.top, -50)

                    if !zones.isEmpty {
                        mapSection
                        citiesSection
                    }
                    if !trip.countryCodes.isEmpty {
                        countriesSection
                    }
                }
                .padding(.horizontal, 20)

                photosSection
                    .padding(.top, 34)
                    .padding(.bottom, 40)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { menu }
        .fullScreenCover(item: $viewerStart) { selection in
            PhotoViewer(assetIDs: trip.assetIdentifiers, index: selection.id, trip: trip)
        }
        .fullScreenCover(isPresented: $showFullMap) {
            TripFullMap(title: trip.title, zones: zones) { zone in
                // Открываем город после закрытия полноэкранной карты.
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    openedZone = zone
                }
            }
        }
        .navigationDestination(item: $openedZone) { zone in
            CityPhotosView(zone: zone, trips: [trip])
        }
        .confirmationDialog(removeCandidate?.title ?? "", isPresented: Binding(
            get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } }
        ), titleVisibility: .visible, presenting: removeCandidate) { target in
            Button("Убрать", role: .destructive) {
                withAnimation(.snappy) {
                    switch target {
                    case .city(let zone): trip.removePlace(id: zone.id)
                    case .country(let code): trip.removeCountry(code)
                    }
                }
                if focusedZone != nil { focusedZone = nil; mapPosition = .automatic }
                try? context.save()
            }
        } message: { _ in
            Text("Пропадёт с карты и из статистики. Фото останутся в поездке.")
        }
        .task { await importer.backfillAssignments(trip, in: context) }
        .alert("Название поездки", isPresented: $isRenaming) {
            TextField("Название", text: $draftTitle)
            Button("Сохранить") {
                let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { trip.title = trimmed }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить поездку?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                // Сначала уходим с экрана, потом удаляем — чтобы не рендерить удалённую модель.
                let trip = trip
                dismiss()
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    importer.delete(trip, in: context)
                }
            }
        } message: {
            Text("Фотографии в медиатеке останутся. Поездка больше не будет предлагаться.")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoThumbnail(assetID: trip.coverAssetIdentifier, size: 700)
                .frame(height: heroHeight)
                .clipped()
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView).minY
                    return content
                        .scaleEffect(y > 0 ? 1 + y / 460 : 1, anchor: .bottom)   // растягивание
                        .offset(y: y < 0 ? -y * 0.35 : 0)                         // параллакс
                }

            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(trip.flags).font(.title)
                Text(trip.title)
                    .font(Theme.title(40))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                Text(trip.dateRangeText)
                    .font(.headline)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 74)
        }
        .frame(height: heroHeight)
        // Обрезаем только снизу: вверх фото может растягиваться при оттягивании.
        .mask(alignment: .bottom) {
            Rectangle().frame(height: heroHeight + 2000)
        }
    }

    // MARK: - Статистика

    private var statsPanel: some View {
        HStack(spacing: 0) {
            stat(trip.dayCount, RU.word(trip.dayCount, "день", "дня", "дней"))
            stat(trip.assetIdentifiers.count, "фото")
            stat(trip.cityKeys.count, RU.word(trip.cityKeys.count, "город", "города", "городов"))
            stat(Int(trip.distanceKm.rounded()), "км")
        }
        .padding(.vertical, 18)
        .glass(cornerRadius: 26)
        .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted())
                .font(Theme.number(26))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Карта зон

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Где я был", trailing: RU.cities(zones.count))

            ZoneMap(zones: zones, position: $mapPosition,
                    onSelect: { openedZone = $0 }, labelDistance: 1_500_000)
                .frame(height: 340)
                .card()
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 8) {
                        mapButton("arrow.up.left.and.arrow.down.right") { showFullMap = true }
                        if focusedZone != nil {
                            mapButton("scope") {
                                focusedZone = nil
                                withAnimation(.smooth(duration: 0.8)) { mapPosition = .automatic }
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(12)
                }
        }
    }

    private func mapButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .glass(cornerRadius: 19)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Города

    private var citiesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Города")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(zones) { zone in
                        CityCard(zone: zone, isFocused: focusedZone == zone.id)
                            .onTapGesture { focus(zone) }
                            .contextMenu {
                                Button("Фото из города", systemImage: "photo.on.rectangle") { openedZone = zone }
                                Button("Показать на карте", systemImage: "map") { focus(zone) }
                                Divider()
                                Button("Я здесь не был", systemImage: "mappin.slash", role: .destructive) {
                                    removeCandidate = .city(zone)
                                }
                            }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Страны

    private var countriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Страны")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(trip.countryCodes, id: \.self) { code in
                        Chip(text: "\(Geo.flag(for: code))  \(Geo.countryName(for: code))")
                            .contextMenu {
                                Button("Я не был в этой стране", systemImage: "flag.slash", role: .destructive) {
                                    removeCandidate = .country(code)
                                }
                            }
                    }
                }
            }
            .scrollClipDisabled()
            Text("Удерживайте город или страну, чтобы убрать ошибочно определённое место — например, фото из самолёта.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func focus(_ zone: CityZone) {
        withAnimation(.smooth(duration: 0.8)) {
            focusedZone = zone.id
            mapPosition = .region(zone.region)
        }
    }

    // MARK: - Фото по дням

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 30) {
            SectionTitle(title: "Фотографии", trailing: RU.photos(trip.assetIdentifiers.count))
                .padding(.horizontal, 20)

            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(trip.days) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        DayHeader(day: day).padding(.horizontal, 20)
                        if contentWidth > 0 {
                            PhotoMosaic(ids: day.assetIDs, width: contentWidth - 24) { id in
                                if let index = trip.assetIdentifiers.firstIndex(of: id) {
                                    viewerStart = PhotoSelection(id: index)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Меню

    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Переименовать", systemImage: "pencil") {
                    draftTitle = trip.title
                    isRenaming = true
                }
                Button("Удалить поездку", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

struct PhotoSelection: Identifiable {
    let id: Int
}

// MARK: - Компоненты

private struct CityCard: View {
    let zone: CityZone
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotoThumbnail(assetID: zone.coverAssetID, size: 320)
                .frame(width: 168, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let order = zone.order {
                        Text("\(order)")
                            .font(Theme.number(14))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Theme.zoneColor(visits: zone.visits), in: Circle())
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.coral, lineWidth: isFocused ? 3 : 0)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(Geo.flag(for: zone.countryCode)) \(RU.photos(zone.photoCount))\(visitText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 168)
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(.spring(duration: 0.35), value: isFocused)
        .contentShape(Rectangle())
    }

    private var visitText: String {
        guard let date = zone.firstVisit else { return "" }
        return " · " + date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct DayHeader: View {
    let day: TripDay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("День \(day.index)")
                    .font(Theme.title(22))
                Text(day.id.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !day.cities.isEmpty {
                Label(day.cities.map(\.name).joined(separator: " → "), systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.coral)
            }
        }
    }
}

/// Полноэкранная карта зон поездки.
private struct TripFullMap: View {
    let title: String
    let zones: [CityZone]
    var onSelect: (CityZone) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZoneMap(zones: zones, position: $position,
                onSelect: { zone in dismiss(); onSelect(zone) },
                labelDistance: 1_500_000)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCapsule()
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 42, height: 42)
                            .glass(cornerRadius: 21)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
    }
}
