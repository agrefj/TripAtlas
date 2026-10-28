import SwiftUI

/// Визуальный стиль приложения: тёплая «закатная» палитра, редакционные заголовки
/// с засечками, округлые цифры и стеклянные панели (Liquid Glass на iOS 26).
enum Theme {
    static let coral  = Color(red: 1.00, green: 0.45, blue: 0.33)
    static let rose   = Color(red: 0.96, green: 0.29, blue: 0.48)
    static let violet = Color(red: 0.53, green: 0.32, blue: 0.95)
    static let sky    = Color(red: 0.25, green: 0.62, blue: 1.00)

    /// Цвет зоны по числу визитов: 1 — коралловый, 2 — розовый, 3+ — фиолетовый.
    static func zoneColor(visits: Int) -> Color {
        switch visits {
        case ...1: return coral
        case 2: return rose
        default: return violet
        }
    }

    static let sunset = LinearGradient(colors: [coral, rose, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .serif) }
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }

    static let cardRadius: CGFloat = 28
}

// MARK: - Стекло

extension View {
    /// Стеклянная подложка: Liquid Glass на iOS 26, материал на более ранних.
    @ViewBuilder
    func glass(cornerRadius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Карточка с мягкой тенью и скруглением.
    func card(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    /// Лёгкое уменьшение карточек у краёв экрана при прокрутке.
    func scrollFade() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                .opacity(phase.isIdentity ? 1 : 0.6)
        }
    }
}

// MARK: - Мелкие компоненты

struct SectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.title(26))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

// MARK: - Русские склонения

enum RU {
    /// plural(3, "город", "города", "городов") -> "города"
    static func word(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) \(word(n, one, few, many))"
    }

    static func cities(_ n: Int) -> String { count(n, "город", "города", "городов") }
    static func countries(_ n: Int) -> String { count(n, "страна", "страны", "стран") }
    static func photos(_ n: Int) -> String { count(n, "фото", "фото", "фото") }
    static func days(_ n: Int) -> String { count(n, "день", "дня", "дней") }
    static func trips(_ n: Int) -> String { count(n, "поездка", "поездки", "поездок") }
}
