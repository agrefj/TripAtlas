import SwiftUI

/// Мозаика фото: ряды по три, через ряд — крупное фото слева или справа.
struct PhotoMosaic: View {
    let ids: [String]
    let width: CGFloat
    var spacing: CGFloat = 3
    let onTap: (String) -> Void

    private var rows: [[String]] {
        stride(from: 0, to: ids.count, by: 3).map { Array(ids[$0..<min($0 + 3, ids.count)]) }
    }

    var body: some View {
        LazyVStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                rowView(row, featured: index % 2 == 0, flipped: index % 4 == 2)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: [String], featured: Bool, flipped: Bool) -> some View {
        let small = (width - 2 * spacing) / 3

        if featured && row.count == 3 {
            let big = small * 2 + spacing
            HStack(spacing: spacing) {
                if flipped {
                    column(row[1], row[2], side: small, total: big)
                    tile(row[0], width: big, height: big)
                } else {
                    tile(row[0], width: big, height: big)
                    column(row[1], row[2], side: small, total: big)
                }
            }
        } else {
            let count = CGFloat(row.count)
            let w = (width - spacing * (count - 1)) / count
            let h = row.count == 3 ? small : small * 1.4
            HStack(spacing: spacing) {
                ForEach(row, id: \.self) { tile($0, width: w, height: h) }
            }
        }
    }

    private func column(_ a: String, _ b: String, side: CGFloat, total: CGFloat) -> some View {
        VStack(spacing: spacing) {
            tile(a, width: side, height: (total - spacing) / 2)
            tile(b, width: side, height: (total - spacing) / 2)
        }
    }

    private func tile(_ id: String, width: CGFloat, height: CGFloat) -> some View {
        PhotoThumbnail(assetID: id, size: max(width, height))
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onTap(id) }
    }
}
