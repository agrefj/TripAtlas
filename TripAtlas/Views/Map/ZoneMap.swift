import SwiftUI
import MapKit

/// Содержимое карты: полупрозрачные зоны городов.
///
/// Издалека зоны в несколько километров не видны, поэтому при отдалении поверх них
/// рисуются светящиеся точки фиксированного размера, а при приближении — подписи
/// с названием города и обложкой.
struct ZoneMapContent: MapContent {
    let zones: [CityZone]
    let showLabels: Bool
    var onSelect: ((CityZone) -> Void)? = nil

    var body: some MapContent {
        ForEach(zones) { zone in
            let color = Theme.zoneColor(visits: zone.visits)
            MapCircle(center: zone.center, radius: zone.radiusMeters)
                .foregroundStyle(color.opacity(0.22))
                .stroke(color.opacity(0.9), lineWidth: 1.5)
        }

        ForEach(showLabels ? [] : zones) { zone in
            Annotation(zone.name, coordinate: zone.center, anchor: .center) {
                ZoneHalo(color: Theme.zoneColor(visits: zone.visits))
                    .padding(8)                       // увеличенная зона нажатия
                    .contentShape(Circle())
                    .onTapGesture { onSelect?(zone) }
            }
            .annotationTitles(.hidden)
        }

        ForEach(showLabels ? zones : []) { zone in
            Annotation(zone.name, coordinate: zone.center, anchor: .center) {
                ZoneLabel(zone: zone)
                    .contentShape(Capsule())
                    .onTapGesture { onSelect?(zone) }
            }
            .annotationTitles(.hidden)
        }
    }
}

/// Карта зон с автоматическим переключением точек/подписей по масштабу.
struct ZoneMap: View {
    let zones: [CityZone]
    @Binding var position: MapCameraPosition
    var interactive = true
    /// Нажатие на точку или подпись города.
    var onSelect: ((CityZone) -> Void)? = nil
    /// Подписи появляются, когда камера ближе этого расстояния (м).
    var labelDistance: CLLocationDistance = 450_000

    @State private var cameraDistance: CLLocationDistance = .greatestFiniteMagnitude

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            ZoneMapContent(zones: zones,
                           showLabels: cameraDistance < labelDistance || zones.count <= 3,
                           onSelect: onSelect)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraDistance = context.camera.distance
        }
    }
}

// MARK: - Элементы карты

private struct ZoneHalo: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.25)).frame(width: 26, height: 26)
            Circle().fill(color).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: color.opacity(0.8), radius: 6)
        }
    }
}

private struct ZoneLabel: View {
    let zone: CityZone

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                PhotoThumbnail(assetID: zone.coverAssetID, size: 40)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                if let order = zone.order {
                    Text("\(order)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Theme.zoneColor(visits: zone.visits), in: Circle())
                        .offset(x: 10, y: -10)
                }
            }
            Text(zone.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(3)
        .padding(.trailing, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.zoneColor(visits: zone.visits).opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// Легенда «сколько раз был в городе».
struct ZoneLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(1, "1 раз")
            item(2, "2 раза")
            item(3, "3+")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCapsule()
    }

    private func item(_ visits: Int, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.zoneColor(visits: visits)).frame(width: 9, height: 9)
            Text(label)
        }
    }
}

/// Полноэкранная карта всех городов. Нажатие на город открывает его фотографии.
struct WorldMapView: View {
    let trips: [Trip]
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: CityZone?

    private var zones: [CityZone] { CityZone.aggregate(trips) }

    var body: some View {
        ZoneMap(zones: zones, position: $position, onSelect: { selected = $0 })
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    Text("Нажмите на город, чтобы открыть фото")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ZoneLegend()
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(RU.cities(zones.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(item: $selected) { zone in
                CityPhotosView(zone: zone, trips: trips)
            }
    }
}
