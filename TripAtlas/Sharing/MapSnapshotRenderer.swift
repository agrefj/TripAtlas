import MapKit
import UIKit
import SwiftUI

/// Статичная картинка карты с зонами городов для карточек.
/// Живой `Map` не рендерится в `ImageRenderer`, поэтому снимаем карту через
/// `MKMapSnapshotter` и дорисовываем зоны сами.
enum MapSnapshotRenderer {

    struct Zone {
        let place: Place
        let boundary: CityBoundary?
        let order: Int
    }

    static func render(zones: [Zone], size: CGSize, dark: Bool, numbered: Bool = true,
                       scale: CGFloat = ShareConfig.renderScale) async -> UIImage? {
        guard !zones.isEmpty else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = region(for: zones, aspect: size.width / size.height)
        options.size = size
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.displayScale = scale
        }
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return await MainActor.run {
            draw(snapshot: snapshot, zones: zones, size: size, numbered: numbered, dark: dark, scale: scale)
        }
    }

    // MARK: - Регион

    private static func region(for zones: [Zone], aspect: CGFloat) -> MKCoordinateRegion {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for zone in zones {
            if let b = zone.boundary {
                minLat = min(minLat, b.minLatitude); maxLat = max(maxLat, b.maxLatitude)
                minLon = min(minLon, b.minLongitude); maxLon = max(maxLon, b.maxLongitude)
            } else {
                let r = (zone.place.radiusKm ?? 3) / 111
                let p = zone.place
                minLat = min(minLat, p.latitude - r); maxLat = max(maxLat, p.latitude + r)
                let rLon = r / max(cos(p.latitude * .pi / 180), 0.2)
                minLon = min(minLon, p.longitude - rLon); maxLon = max(maxLon, p.longitude + rLon)
            }
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        var latSpan = max((maxLat - minLat) * 1.5, 0.08)
        var lonSpan = max((maxLon - minLon) * 1.5, 0.08)

        // Подгоняем под пропорции картинки, чтобы ничего не обрезалось.
        let k = cos(center.latitude * .pi / 180)
        if lonSpan * k / latSpan < aspect { lonSpan = latSpan * aspect / k } else { latSpan = lonSpan * k / aspect }
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: min(latSpan, 170), longitudeDelta: min(lonSpan, 340)))
    }

    // MARK: - Рисование

    @MainActor
    private static func draw(snapshot: MKMapSnapshotter.Snapshot, zones: [Zone], size: CGSize, numbered: Bool,
                             dark: Bool, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let cg = context.cgContext

            for zone in zones {
                let color = UIColor(zoneColor(zone.order))
                let path = UIBezierPath()
                if let boundary = zone.boundary {
                    for polygon in boundary.polygons {
                        append(polygon.outer, to: path, snapshot: snapshot)
                        for hole in polygon.holes { append(hole, to: path, snapshot: snapshot) }
                    }
                    path.usesEvenOddFillRule = true
                } else {
                    let center = snapshot.point(for: zone.place.coordinate)
                    let edge = snapshot.point(for: CLLocationCoordinate2D(
                        latitude: zone.place.latitude + (zone.place.radiusKm ?? 3) / 111,
                        longitude: zone.place.longitude))
                    let r = max(abs(center.y - edge.y), 4)
                    path.append(UIBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)))
                }

                // Свечение + заливка + контур.
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: 10, color: color.withAlphaComponent(0.9).cgColor)
                color.withAlphaComponent(0.4).setFill()
                path.fill()
                cg.restoreGState()
                color.setStroke()
                path.lineWidth = 1.6
                path.lineJoinStyle = .round
                path.stroke()
            }

            // Номера городов поверх зон.
            for zone in zones where numbered {
                let p = snapshot.point(for: zone.place.coordinate)
                let r: CGFloat = 10
                let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.4).cgColor)
                UIColor(zoneColor(zone.order)).setFill()
                UIBezierPath(ovalIn: rect).fill()
                cg.restoreGState()
                UIColor.white.setStroke()
                let ring = UIBezierPath(ovalIn: rect)
                ring.lineWidth = 1.5
                ring.stroke()

                let text = "\(zone.order)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: UIColor.white,
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: p.x - textSize.width / 2, y: p.y - textSize.height / 2), withAttributes: attributes)
            }

            // Границы — данные OpenStreetMap (ODbL): на картинке с ними нужна подпись.
            if zones.contains(where: { $0.boundary != nil }) {
                drawAttribution(in: size, dark: dark)
            }
        }
    }

    static let attributionText = "© OpenStreetMap contributors"

    private static func drawAttribution(in size: CGSize, dark: Bool) {
        let shadow = NSShadow()
        shadow.shadowColor = (dark ? UIColor.black : UIColor.white).withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.7),
            .shadow: shadow,
        ]
        let text = attributionText as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: size.width - textSize.width - 6, y: size.height - textSize.height - 4),
                  withAttributes: attributes)
    }

    private static func append(_ ring: [Coordinate], to path: UIBezierPath, snapshot: MKMapSnapshotter.Snapshot) {
        guard let first = ring.first else { return }
        path.move(to: snapshot.point(for: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)))
        for c in ring.dropFirst() {
            path.addLine(to: snapshot.point(for: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)))
        }
        path.close()
    }

    /// Цвета зон по порядку посещения: коралл → роза → фиолет и снова.
    static func zoneColor(_ order: Int) -> Color {
        [Theme.coral, Theme.rose, Theme.violet][(max(order, 1) - 1) % 3]
    }
}
