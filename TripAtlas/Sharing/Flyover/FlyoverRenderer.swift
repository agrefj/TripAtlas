import UIKit

/// Рисует один кадр ролика 1080×1920. Контекст должен быть в координатах UIKit
/// (начало слева сверху) и установлен через `UIGraphicsPushContext`.
final class FlyoverRenderer {
    static let size = CGSize(width: 1080, height: 1920)
    private var W: CGFloat { Self.size.width }
    private var H: CGFloat { Self.size.height }

    let script: FlyoverScript
    let assets: FlyoverAssets
    let info: FlyoverInfo
    let showPhotos: Bool

    private let background = UIColor(red: 0.086, green: 0.063, blue: 0.122, alpha: 1)
    private let palette: [UIColor] = [UIColor(Theme.coral), UIColor(Theme.rose), UIColor(Theme.violet)]
    /// Дуги маршрута в Меркаторе: `routes[i]` — от города i-1 к городу i.
    private let routes: [[CGPoint]]

    init(script: FlyoverScript, assets: FlyoverAssets, info: FlyoverInfo, showPhotos: Bool) {
        self.script = script
        self.assets = assets
        self.info = info
        self.showPhotos = showPhotos
        var routes: [[CGPoint]] = [[]]
        for i in script.cities.indices.dropFirst() {
            // Дорога домой выгибается в другую сторону — туда и обратно не сливаются в одну дугу.
            routes.append(Self.arc(from: script.cities[i - 1].center, to: script.cities[i].center,
                                   bendDown: script.cities[i].isHome))
        }
        self.routes = routes
    }

    private func color(_ index: Int) -> UIColor { palette[index % palette.count] }

    // MARK: - Кадр

    func draw(time: Double, in ctx: CGContext) {
        ctx.interpolationQuality = .medium
        let view = script.camera(at: time).rect

        background.setFill()
        UIRectFill(CGRect(origin: .zero, size: Self.size))
        drawMap(view: view)
        UIColor.black.withAlphaComponent(0.12).setFill()
        UIRectFillUsingBlendMode(CGRect(origin: .zero, size: Self.size), .normal)

        drawRoutes(time: time, view: view, ctx: ctx)
        drawZones(time: time, view: view, ctx: ctx)
        drawMarkers(time: time, view: view)
        drawGradients(ctx: ctx)
        drawBrandPill()
        drawAttribution()

        drawIntro(time: time)
        for i in script.cities.indices {
            drawCityLabel(i, time: time)
            if showPhotos { drawPhotos(i, time: time, ctx: ctx) }
        }
        drawOutro(time: time)
    }

    // MARK: - Карта

    private func screen(_ p: CGPoint, _ view: CGRect) -> CGPoint {
        CGPoint(x: (p.x - view.minX) / view.width * W, y: (p.y - view.minY) / view.height * H)
    }

    private func drawMap(view: CGRect) {
        for (index, layer) in assets.layers.enumerated() {
            var alpha = 1.0
            if index > 0 {
                // Детальный снимок проявляется, когда камера приблизилась и кадр целиком внутри него.
                let ratio = Double(view.width / layer.rect.width)
                let zoomAlpha = 1 - Ease.step(0.72, 0.95, ratio)
                let margin = Double(min(view.minX - layer.rect.minX, layer.rect.maxX - view.maxX,
                                        view.minY - layer.rect.minY, layer.rect.maxY - view.maxY) / view.width)
                alpha = min(zoomAlpha, Ease.step(0, 0.05, margin))
            }
            guard alpha > 0.01 else { continue }
            let origin = screen(layer.rect.origin, view)
            let dest = CGRect(x: origin.x, y: origin.y,
                              width: layer.rect.width / view.width * W,
                              height: layer.rect.height / view.height * H)
            layer.image.draw(in: dest, blendMode: .normal, alpha: CGFloat(alpha))
        }
    }

    // MARK: - Маршрут

    private static func arc(from a: CGPoint, to b: CGPoint, bendDown: Bool = false, samples: Int = 64) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 1e-12)
        var normal = CGPoint(x: -dy / length, y: dx / length)
        // Дуга выгибается вверх (или вниз — для обратного пути).
        if (normal.y > 0) != bendDown { normal = CGPoint(x: -normal.x, y: -normal.y) }
        let control = CGPoint(x: (a.x + b.x) / 2 + normal.x * length * 0.22,
                              y: (a.y + b.y) / 2 + normal.y * length * 0.22)
        return (0...samples).map { k in
            let t = CGFloat(k) / CGFloat(samples)
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        }
    }

    private func drawRoutes(time: Double, view: CGRect, ctx: CGContext) {
        for i in routes.indices where i > 0 {
            let progress = script.routeProgress(to: i, at: time)
            guard progress > 0 else { continue }
            let route = routes[i]
            let count = max(2, Int(progress * Double(route.count - 1)) + 1)
            let points = route.prefix(count).map { screen($0, view) }

            let path = UIBezierPath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            path.lineWidth = 6
            path.lineCapStyle = .round
            path.setLineDash([2, 16], count: 2, phase: 0)

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 14, color: UIColor.white.withAlphaComponent(0.7).cgColor)
            UIColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
            ctx.restoreGState()

            // Самолётик на конце, пока летим.
            if progress < 1, points.count >= 2, let plane = assets.plane {
                let tip = points[points.count - 1], prev = points[points.count - 2]
                ctx.saveGState()
                ctx.translateBy(x: tip.x, y: tip.y)
                ctx.rotate(by: atan2(tip.y - prev.y, tip.x - prev.x))
                ctx.setShadow(offset: .zero, blur: 12, color: UIColor.black.withAlphaComponent(0.5).cgColor)
                plane.draw(in: CGRect(x: -30, y: -30, width: 60, height: 60))
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Зоны городов

    private func current(_ i: Int, time: Double) -> Bool {
        if case .stay(let city, _) = script.phase(at: time) { return city == i }
        return false
    }

    private func zonePath(_ city: FlyoverCity, view: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        for circle in city.circles {
            let c = screen(circle.center, view)
            let r = max(CGFloat(circle.radius) / view.width * W, 10)
            path.append(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
        }
        for ring in city.rings {
            guard let first = ring.first else { continue }
            path.move(to: screen(first, view))
            for p in ring.dropFirst() { path.addLine(to: screen(p, view)) }
            path.close()
        }
        path.usesEvenOddFillRule = true
        return path
    }

    private func drawZones(time: Double, view: CGRect, ctx: CGContext) {
        for (i, city) in script.cities.enumerated() where !city.isHome {
            let reveal = script.reveal(i, at: time)
            guard reveal > 0 else { continue }
            let tint = color(script.visitNumber(i).0 - 1)
            let emphasis: Double = current(i, time: time) ? 1 : 0.45
            let path = zonePath(city, view: view)
            path.lineWidth = 4
            path.lineJoinStyle = .round

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: CGFloat(30 * emphasis), color: tint.withAlphaComponent(CGFloat(0.9 * reveal)).cgColor)
            tint.withAlphaComponent(CGFloat(0.42 * reveal * (0.6 + 0.4 * emphasis))).setFill()
            path.fill()
            ctx.restoreGState()
            tint.withAlphaComponent(CGFloat(reveal)).setStroke()
            path.stroke()
        }
    }

    private func drawMarkers(time: Double, view: CGRect) {
        drawHomeMarker(view: view)
        for (i, city) in script.cities.enumerated() where !city.isHome {
            let reveal = script.reveal(i, at: time)
            guard reveal > 0 else { continue }
            let scale = CGFloat(Ease.outBack(min(1, reveal * 1.2)))
            let c = screen(city.center, view)
            let r = 24 * scale
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            color(script.visitNumber(i).0 - 1).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: rect)
            ring.lineWidth = 3.5
            ring.stroke()
            text("\(script.visitNumber(i).0)", font: Fonts.rounded(26 * scale, .bold),
                 at: CGPoint(x: c.x, y: c.y - 16 * scale), align: .center, maxWidth: 80, shadow: false)
        }
    }

    /// Домик: виден с самого начала, от него расходятся маршруты года.
    private func drawHomeMarker(view: CGRect) {
        guard let home = script.cities.first(where: \.isHome), let icon = assets.home else { return }
        let c = screen(home.center, view)
        let r: CGFloat = 30
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        ctx?.setShadow(offset: CGSize(width: 0, height: 3), blur: 14, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: rect).fill()
        ctx?.restoreGState()
        icon.draw(in: rect.insetBy(dx: 14, dy: 14))
    }

    // MARK: - Оформление

    private func drawGradients(ctx: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        let top = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0.6).cgColor,
                                                           UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(top, start: .zero, end: CGPoint(x: 0, y: 560), options: [])
        let bottom = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0).cgColor,
                                                              UIColor.black.withAlphaComponent(0.75).cgColor] as CFArray,
                                locations: [0, 1])!
        ctx.drawLinearGradient(bottom, start: CGPoint(x: 0, y: 1180), end: CGPoint(x: 0, y: H), options: [])
    }

    private func drawBrandPill() {
        let font = Fonts.system(34, .bold)
        let width = (ShareConfig.brandName as NSString).size(withAttributes: [.font: font]).width
        let pill = CGRect(x: 56, y: 110, width: width + 102, height: 76)
        UIColor.white.withAlphaComponent(0.18).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: 38).fill()
        if let logo = assets.logo {
            let logoRect = CGRect(x: pill.minX + 12, y: pill.minY + 12, width: 52, height: 52)
            UIGraphicsGetCurrentContext()?.saveGState()
            UIBezierPath(roundedRect: logoRect, cornerRadius: 13).addClip()
            logo.draw(in: logoRect)
            UIGraphicsGetCurrentContext()?.restoreGState()
        }
        text(ShareConfig.brandName, font: font, at: CGPoint(x: pill.minX + 78, y: pill.minY + 16), maxWidth: width + 10, shadow: false)
    }

    /// Подпись данных OpenStreetMap (ODbL) в правом нижнем углу — если в ролике есть настоящие границы.
    /// Ниже полароидов (последний кончается выше y ≈ 1850), поэтому ничего не перекрывает.
    private func drawAttribution() {
        guard script.cities.contains(where: { !$0.rings.isEmpty }) else { return }
        let font = Fonts.system(26, .medium)
        let label = MapSnapshotRenderer.attributionText
        let width = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        text(label, font: font, alpha: 0.6, at: CGPoint(x: W - 44 - width, y: H - 64), maxWidth: width + 4)
    }

    // MARK: - Вступление

    private func drawIntro(time: Double) {
        let fadeIn = Ease.step(0.05, 0.45, time)
        let fadeOut = 1 - Ease.step(script.intro - 0.15, script.intro + 0.35, time)
        let alpha = min(fadeIn, fadeOut)
        guard alpha > 0 else { return }
        let shift = CGFloat(1 - fadeIn) * 40

        var y: CGFloat = 1200 + shift
        y += text(info.flags, font: .systemFont(ofSize: 78), alpha: alpha, at: CGPoint(x: W / 2, y: y),
                  align: .center, maxWidth: 960).height + 14
        let titleSize: CGFloat = info.title.count <= 6 ? 220 : 112
        y += text(info.title, font: fitted(info.title, base: titleSize, min: 64, maxWidth: 940, serif: true), alpha: alpha,
                  at: CGPoint(x: W / 2, y: y), align: .center, maxWidth: 940).height + 14
        text(info.subtitle.uppercased(), font: Fonts.system(36, .semibold), alpha: alpha * 0.85,
             at: CGPoint(x: W / 2, y: y), align: .center, maxWidth: 960, kern: 3)
    }

    // MARK: - Город

    private func drawCityLabel(_ i: Int, time: Double) {
        let city = script.cities[i]
        // Дом подписываем только в начале — дальше это короткие пересадки.
        if city.isHome && i > 0 { return }
        let start = script.stayStart(i)
        let stay = script.stayDurations[i]
        let fadeIn = Ease.step(start - 0.3, start + min(0.25, stay / 3), time)
        let fadeOut = 1 - Ease.step(start + stay - min(0.4, stay / 3), start + stay - 0.05, time)
        let alpha = min(fadeIn, fadeOut)
        guard alpha > 0 else { return }

        let x: CGFloat = 60 - CGFloat(1 - fadeIn) * 40
        var y: CGFloat = 240
        let (number, total) = script.visitNumber(i)
        if !city.isHome && total > 1 {
            y += text("\(number) / \(total)", font: Fonts.rounded(34, .bold), alpha: alpha * 0.75,
                      at: CGPoint(x: x, y: y)).height + 2
        }
        y += text(city.name, font: fitted(city.name, base: 108, min: 56, maxWidth: 960, serif: true), alpha: alpha,
                  at: CGPoint(x: x, y: y)).height + 4
        if let subtitle = city.subtitle, !subtitle.isEmpty {
            text(subtitle, font: Fonts.system(40, .semibold), alpha: alpha * 0.9, at: CGPoint(x: x, y: y))
        }
    }

    private struct PhotoSlot { let center: CGPoint; let angle: CGFloat }
    private let slots = [
        PhotoSlot(center: CGPoint(x: 320, y: 1300), angle: -0.12),
        PhotoSlot(center: CGPoint(x: 760, y: 1370), angle: 0.1),
        PhotoSlot(center: CGPoint(x: 540, y: 1600), angle: -0.05),
    ]

    private func drawPhotos(_ i: Int, time: Double, ctx: CGContext) {
        let city = script.cities[i]
        guard !city.isHome else { return }
        let start = script.stayStart(i)
        let stay = script.stayDurations[i]
        let outTime = start + stay - 0.3
        let out = Ease.step(outTime - 0.05, outTime + 0.3, time)
        guard out < 1 else { return }

        var shown: [(Int, UIImage)] = []
        for (k, id) in city.photoIDs.enumerated() {
            if let image = assets.photos[id], shown.count < 3 { shown.append((k, image)) }
        }
        for (slotIndex, item) in shown.enumerated() {
            let (k, image) = item
            let appear = start + stay * (0.12 + 0.17 * Double(slotIndex))
            let p = min(max((time - appear) / 0.45, 0), 1)
            guard p > 0 else { continue }

            let scale = CGFloat(Ease.outBack(p)) * CGFloat(1 - 0.3 * out)
            let alpha = min(1, p * 2) * (1 - out)
            let slot = slots[slotIndex]
            let date = k < city.photoDates.count ? city.photoDates[k] : nil

            ctx.saveGState()
            ctx.setAlpha(CGFloat(alpha))
            ctx.translateBy(x: slot.center.x, y: slot.center.y)
            ctx.rotate(by: slot.angle)
            ctx.scaleBy(x: scale, y: scale)
            drawPolaroid(image, date: date, ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// Полароид с центром в (0, 0).
    private func drawPolaroid(_ image: UIImage, date: Date?, ctx: CGContext) {
        let side: CGFloat = 380, pad: CGFloat = 20, bottom: CGFloat = 74
        let frame = CGRect(x: -(side / 2 + pad), y: -(side + pad + bottom) / 2,
                           width: side + 2 * pad, height: side + pad + bottom)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 34, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        UIColor(white: 0.98, alpha: 1).setFill()
        UIBezierPath(rect: frame).fill()
        ctx.restoreGState()

        let photoRect = CGRect(x: frame.minX + pad, y: frame.minY + pad, width: side, height: side)
        ctx.saveGState()
        UIBezierPath(rect: photoRect).addClip()
        image.draw(in: aspectFill(image.size, in: photoRect))
        ctx.restoreGState()

        if let date {
            text(date.formatted(.dateTime.day().month(.wide)), font: Fonts.serif(30, .medium, italic: true),
                 color: UIColor(white: 0.3, alpha: 1), at: CGPoint(x: 0, y: photoRect.maxY + 16),
                 align: .center, maxWidth: side, shadow: false)
        }
    }

    private func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Финал

    private func drawOutro(time: Double) {
        let start = script.outroStart + script.outroFly * 0.55
        let alpha = Ease.step(start, start + 0.5, time)
        guard alpha > 0 else { return }
        let shift = CGFloat(1 - alpha) * 50

        var y: CGFloat = 1120 + shift
        let titleSize: CGFloat = info.title.count <= 6 ? 160 : 86
        y += text(info.title, font: fitted(info.title, base: titleSize, min: 52, maxWidth: 940, serif: true), alpha: alpha,
                  at: CGPoint(x: W / 2, y: y), align: .center, maxWidth: 940).height + 8
        y += text(info.subtitle, font: Fonts.system(34, .semibold), alpha: alpha * 0.8,
                  at: CGPoint(x: W / 2, y: y), align: .center, maxWidth: 960).height + 34

        // Цифры поездки.
        let items: [(String, String)] = info.stats.prefix(4).map { ($0.value, $0.label) }
        guard !items.isEmpty else { return }

        let panel = CGRect(x: 60, y: y, width: W - 120, height: 176)
        UIColor.white.withAlphaComponent(CGFloat(0.14 * alpha)).setFill()
        UIBezierPath(roundedRect: panel, cornerRadius: 44).fill()
        let column = panel.width / CGFloat(items.count)
        for (index, item) in items.enumerated() {
            let cx = panel.minX + column * (CGFloat(index) + 0.5)
            text(item.0, font: fitted(item.0, base: 64, min: 36, maxWidth: column - 16, rounded: true), alpha: alpha,
                 at: CGPoint(x: cx, y: panel.minY + 26), align: .center, maxWidth: column - 8, shadow: false)
            text(item.1, font: Fonts.system(28, .medium), alpha: alpha * 0.75,
                 at: CGPoint(x: cx, y: panel.minY + 112), align: .center, maxWidth: column - 8, shadow: false)
        }

        // Подпись приложения.
        let brandAlpha = Ease.step(start + 0.5, start + 1.0, time)
        guard brandAlpha > 0 else { return }
        let caption = "Сделано в \(ShareConfig.brandName)"
        let font = Fonts.system(38, .semibold)
        let width = (caption as NSString).size(withAttributes: [.font: font]).width
        let total = 72 + 18 + width
        let left = (W - total) / 2
        let top = panel.maxY + 70
        if let logo = assets.logo {
            let rect = CGRect(x: left, y: top, width: 72, height: 72)
            UIGraphicsGetCurrentContext()?.saveGState()
            UIGraphicsGetCurrentContext()?.setAlpha(CGFloat(brandAlpha))
            UIBezierPath(roundedRect: rect, cornerRadius: 18).addClip()
            logo.draw(in: rect)
            UIGraphicsGetCurrentContext()?.restoreGState()
        }
        text(caption, font: font, alpha: brandAlpha, at: CGPoint(x: left + 90, y: top + 14), maxWidth: width + 10)
    }

    // MARK: - Текст

    @discardableResult
    private func text(_ string: String, font: UIFont, color: UIColor = .white, alpha: Double = 1, at point: CGPoint,
                      align: NSTextAlignment = .left, maxWidth: CGFloat = 960, shadow: Bool = true, kern: CGFloat = 0) -> CGSize {
        guard alpha > 0.001, !string.isEmpty else { return .zero }
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(CGFloat(alpha)),
            .paragraphStyle: style,
            .kern: kern,
        ]
        if shadow {
            let s = NSShadow()
            s.shadowColor = UIColor.black.withAlphaComponent(CGFloat(0.45 * alpha))
            s.shadowBlurRadius = 18
            s.shadowOffset = CGSize(width: 0, height: 4)
            attributes[.shadow] = s
        }
        let string = NSAttributedString(string: string, attributes: attributes)
        let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let x = align == .center ? point.x - maxWidth / 2 : point.x
        string.draw(with: CGRect(x: x, y: point.y, width: maxWidth, height: ceil(bounds.height)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// Шрифт, уменьшенный так, чтобы строка поместилась максимум в две строки по ширине.
    private func fitted(_ string: String, base: CGFloat, min minSize: CGFloat, maxWidth: CGFloat,
                        serif: Bool = false, rounded: Bool = false) -> UIFont {
        var size = base
        while size > minSize {
            let font = serif ? Fonts.serif(size, .bold) : rounded ? Fonts.rounded(size, .bold) : Fonts.system(size, .bold)
            let width = (string as NSString).size(withAttributes: [.font: font]).width
            if width <= maxWidth * (serif ? 2 : 1) { return font }
            size -= 6
        }
        return serif ? Fonts.serif(minSize, .bold) : rounded ? Fonts.rounded(minSize, .bold) : Fonts.system(minSize, .bold)
    }
}

enum Fonts {
    static func system(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont { .systemFont(ofSize: size, weight: weight) }

    static func serif(_ size: CGFloat, _ weight: UIFont.Weight, italic: Bool = false) -> UIFont {
        design(.serif, size, weight, italic: italic)
    }

    static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont { design(.rounded, size, weight) }

    private static func design(_ design: UIFontDescriptor.SystemDesign, _ size: CGFloat, _ weight: UIFont.Weight,
                               italic: Bool = false) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        descriptor = descriptor.withDesign(design) ?? descriptor
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor }
        return UIFont(descriptor: descriptor, size: size)
    }
}
