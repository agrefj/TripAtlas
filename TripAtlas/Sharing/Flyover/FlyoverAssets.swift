import MapKit
import UIKit

/// Снимок карты и прямоугольник, который он покрывает (в Меркаторе).
struct MapLayer {
    let image: UIImage
    let rect: CGRect
}

/// Всё, что нужно для отрисовки кадров. Загружается один раз до рендера.
struct FlyoverAssets {
    /// От крупного масштаба к мелкому: сначала обзор, потом детальные снимки.
    var layers: [MapLayer]
    var photos: [String: UIImage]
    var logo: UIImage?
    var plane: UIImage?
    var home: UIImage?
}

/// Текстовая часть ролика.
struct FlyoverInfo {
    let title: String
    let subtitle: String
    let flags: String
    let stats: [ShareStat]
}

@MainActor
enum FlyoverPreparation {

    /// Остановки ролика в хронологическом порядке. Если их слишком много —
    /// оставляем те, где больше всего фото.
    /// Остановки для итогов года с домом: дом → поездка → дом → … → дом.
    static func stops(for subject: ShareSubject, home: Coordinate?) async -> [FlyoverCity] {
        let visits = await stops(for: subject)
        guard case .year = subject.kind, let home else { return visits }

        let place = await GeocodingService.shared.place(latitude: home.latitude, longitude: home.longitude)
        let center = Mercator.project(home)
        let homeStop = FlyoverCity(
            name: place.city ?? "Дом",
            subtitle: "🏠 Дом",
            order: 0,
            center: center,
            rings: [],
            circles: [FlyoverCircle(center: center, radius: Mercator.units(km: 8, latitude: home.latitude))],
            photoIDs: [],
            photoDates: [],
            isHome: true
        )
        var result = [homeStop]
        for visit in visits {
            result.append(visit)
            result.append(homeStop)
        }
        return result
    }

    static func stops(for subject: ShareSubject) async -> [FlyoverCity] {
        let limit = subject.kind == .trip ? FlyoverScript.maxCities : FlyoverScript.maxTrips
        var stops = subject.stops.filter { !$0.places.isEmpty }
        if stops.count > limit {
            let ranked = stops.enumerated().sorted { $0.element.photoIDs.count > $1.element.photoIDs.count }
            let keep = Set(ranked.prefix(limit).map(\.offset))
            stops = stops.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }

        // Все границы разом: запросы идут по нескольку.
        let found = BoundaryStore.isEnabled
            ? await CityBoundaryService.boundaries(for: stops.flatMap(\.places).map {
                CityBoundaryService.Lookup(key: $0.id, latitude: $0.latitude, longitude: $0.longitude)
            })
            : [:]

        var result: [FlyoverCity] = []
        for (index, stop) in stops.enumerated() {
            var rings: [[CGPoint]] = []
            var circles: [FlyoverCircle] = []
            var weightedX = 0.0, weightedY = 0.0, weight = 0.0

            for place in stop.places {
                let center = Mercator.project(latitude: place.latitude, longitude: place.longitude)
                let w = Double(max(place.assetIDs?.count ?? place.photoCount ?? 1, 1))
                weightedX += Double(center.x) * w
                weightedY += Double(center.y) * w
                weight += w

                if case .found(let boundary) = found[place.id] {
                    for polygon in boundary.polygons {
                        rings.append(polygon.outer.map { Mercator.project($0) })
                        rings.append(contentsOf: polygon.holes.map { ring in ring.map { Mercator.project($0) } })
                    }
                } else {
                    circles.append(FlyoverCircle(center: center,
                                                 radius: Mercator.units(km: place.radiusKm ?? 3, latitude: place.latitude)))
                }
            }

            // Фото остановки: обложка города (или поездки) + равномерно по остальным.
            let first = stop.places.count == 1 ? stop.places[0].coverAssetID : nil
            let ids = ShareComposerModel.pickBest(stop.photoIDs, count: 3, scores: subject.scores, first: first)
            result.append(FlyoverCity(
                name: stop.name,
                subtitle: stop.subtitle,
                order: index + 1,
                center: CGPoint(x: weightedX / weight, y: weightedY / weight),
                rings: rings,
                circles: circles,
                photoIDs: ids,
                photoDates: ids.map { subject.assetDates[$0] }
            ))
        }
        return result
    }

    static func info(for subject: ShareSubject) -> FlyoverInfo {
        FlyoverInfo(title: subject.title, subtitle: subject.subtitle, flags: subject.flags, stats: subject.stats)
    }

    /// Снимки карты и фото. `progress` — от 0 до 1.
    static func assets(for script: FlyoverScript, loadPhotos: Bool,
                       progress: @escaping (Double) -> Void) async -> FlyoverAssets {
        // Обзор берём с запасом: камера отдаляется на перелётах и в финале.
        var plans: [(CGRect, CGSize)] = [(expand(script.overview.rect, by: 1.7), CGSize(width: 1620, height: 2880))]
        // Дом повторяется много раз, а перелёты «туда» и «обратно» совпадают — снимаем каждый один раз.
        var seen = Set<String>()
        func key(_ c: FlyoverCity) -> String { "\(c.center.x),\(c.center.y)" }
        for (i, city) in script.cities.enumerated() {
            if seen.insert(key(city)).inserted {
                plans.append((expand(city.camera.rect, by: 1.45), CGSize(width: 1512, height: 2688)))
            }
            if i > 0 {
                let previous = script.cities[i - 1]
                let pairKey = [key(previous), key(city)].sorted().joined(separator: "|")
                if seen.insert(pairKey).inserted {
                    let pair = previous.camera.rect.union(city.camera.rect)
                    plans.append((fit(pair, scale: 1.3), CGSize(width: 1080, height: 1920)))
                }
            }
        }

        let photoIDs: [String] = loadPhotos ? script.cities.flatMap(\.photoIDs) : []
        let total = Double(plans.count + photoIDs.count)
        var done = 0.0

        var layers: [MapLayer] = []
        for (rect, size) in plans {
            if let layer = await snapshot(rect, size: size) { layers.append(layer) }
            done += 1
            progress(done / total)
        }
        layers.sort { $0.rect.width > $1.rect.width }

        var photos: [String: UIImage] = [:]
        for id in photoIDs {
            if let image = await ImageLoader.shared.image(for: id, targetSize: CGSize(width: 640, height: 640)) {
                photos[id] = image
            }
            done += 1
            progress(done / total)
        }

        let plane = UIImage(systemName: "airplane",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .bold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let home = UIImage(systemName: "house.fill",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))?
            .withTintColor(UIColor(Theme.rose), renderingMode: .alwaysOriginal)
        return FlyoverAssets(layers: layers, photos: photos, logo: UIImage(named: "ShareLogo"), plane: plane, home: home)
    }

    // MARK: - Снимки

    private static func expand(_ rect: CGRect, by k: Double) -> CGRect {
        let w = Double(rect.width) * k, h = Double(rect.height) * k
        return CGRect(x: Double(rect.midX) - w / 2, y: Double(rect.midY) - h / 2, width: w, height: h)
    }

    /// Прямоугольник 9:16, в который `rect` помещается с запасом.
    private static func fit(_ rect: CGRect, scale: Double) -> CGRect {
        let w = max(Double(rect.width), Double(rect.height) / FlyCamera.aspect) * scale
        let h = w * FlyCamera.aspect
        return CGRect(x: Double(rect.midX) - w / 2, y: Double(rect.midY) - h / 2, width: w, height: h)
    }

    private static func snapshot(_ rect: CGRect, size: CGSize) async -> MapLayer? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0.02, width: 1, height: 0.96))
        guard !clamped.isNull, clamped.width > 0 else { return nil }

        let northWest = Mercator.unproject(CGPoint(x: clamped.minX, y: clamped.minY))
        let southEast = Mercator.unproject(CGPoint(x: clamped.maxX, y: clamped.maxY))
        let center = Mercator.unproject(CGPoint(x: clamped.midX, y: clamped.midY))

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
            span: MKCoordinateSpan(latitudeDelta: northWest.latitude - southEast.latitude,
                                   longitudeDelta: southEast.longitude - northWest.longitude))
        options.size = size
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = 1
        }
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        // MapKit может слегка подогнать регион — восстанавливаем точное соответствие
        // «Меркатор → пиксели» по двум известным точкам.
        let a = northWest, b = southEast
        let pa = snapshot.point(for: CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude))
        let pb = snapshot.point(for: CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude))
        let ma = Mercator.project(a), mb = Mercator.project(b)
        let sx = Double(pb.x - pa.x) / Double(mb.x - ma.x)
        let sy = Double(pb.y - pa.y) / Double(mb.y - ma.y)
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return nil }

        let minX = Double(ma.x) - Double(pa.x) / sx
        let minY = Double(ma.y) - Double(pa.y) / sy
        let rectOut = CGRect(x: minX, y: minY, width: Double(size.width) / sx, height: Double(size.height) / sy)
        return MapLayer(image: snapshot.image, rect: rectOut)
    }
}
