import SwiftUI

/// Карточка поездки в ленте: обложка на всю ширину, заголовок с засечками внизу.
struct TripCard: View {
    let trip: Trip

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoThumbnail(assetID: trip.coverAssetIdentifier, size: 520)
                .frame(height: 260)

            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Text(trip.title)
                    .font(Theme.title(28))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .overlay(alignment: .topLeading) {
            HStack {
                Text(trip.flags)
                    .font(.title3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassCapsule()
                Spacer()
                Label("\(trip.assetIdentifiers.count)", systemImage: "photo.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .glassCapsule()
            }
            .padding(14)
        }
        .frame(height: 260)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var subtitle: String {
        var parts = [trip.dateRangeText, RU.days(trip.dayCount)]
        if trip.cityKeys.count > 1 { parts.append(RU.cities(trip.cityKeys.count)) }
        return parts.joined(separator: " · ")
    }
}
