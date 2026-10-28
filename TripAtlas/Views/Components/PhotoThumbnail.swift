import SwiftUI
import Photos

/// Квадратное/заполняющее превью фото из медиатеки по localIdentifier.
struct PhotoThumbnail: View {
    let assetID: String?
    /// Желаемый размер в поинтах (по большей стороне).
    var size: CGFloat = 200

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: assetID) {
                guard let assetID else { return }
                let px = size * displayScale
                let loaded = await ImageLoader.shared.image(for: assetID, targetSize: CGSize(width: px, height: px))
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// Полноэкранный просмотр фото поездки.
/// Если передана поездка — внизу показывается место съёмки и можно убрать неверно
/// определённое место (например, фото из самолёта над чужой страной).
struct PhotoViewer: View {
    let assetIDs: [String]
    @State var index: Int
    var trip: Trip? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var confirmCountry: String?

    private var currentID: String? { assetIDs.indices.contains(index) ? assetIDs[index] : nil }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(assetIDs.enumerated()), id: \.offset) { offset, id in
                    FullPhoto(assetID: id).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Text("\(index + 1) / \(assetIDs.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white.opacity(0.25))
                }
            }
            .padding()
        }
        .overlay(alignment: .bottom) {
            if let trip, let id = currentID {
                placeBar(trip: trip, assetID: id)
                    .padding(.bottom, 12)
            }
        }
        .confirmationDialog(
            "Убрать \(confirmCountry.map(Geo.countryName(for:)) ?? "") из поездки?",
            isPresented: Binding(get: { confirmCountry != nil }, set: { if !$0 { confirmCountry = nil } }),
            titleVisibility: .visible
        ) {
            Button("Убрать страну", role: .destructive) {
                if let code = confirmCountry { trip?.removeCountry(code); save() }
            }
        } message: {
            Text("Все города этой страны пропадут из поездки. Фото останутся.")
        }
    }

    @ViewBuilder
    private func placeBar(trip: Trip, assetID: String) -> some View {
        let place = trip.place(containing: assetID)
        Menu {
            if let place {
                Button("Я здесь не был", systemImage: "mappin.slash") {
                    withAnimation { trip.unassign(assetID) }
                    save()
                }
                if let code = place.countryCode, let country = place.country {
                    Button("Убрать «\(country)» из поездки", systemImage: "flag.slash", role: .destructive) {
                        confirmCountry = code
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: place == nil ? "mappin.slash" : "mappin.and.ellipse")
                Text(place.map { "\(Geo.flag(for: $0.countryCode)) \($0.displayName)" } ?? "Не привязано к городу")
                    .lineLimit(1)
                if place != nil {
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCapsule()
        }
        .disabled(place == nil)
    }

    private func save() { try? context.save() }
}

private struct FullPhoto: View {
    let assetID: String
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: assetID) {
                let target = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                image = await ImageLoader.shared.image(for: assetID, targetSize: target, contentMode: .aspectFit)
            }
        }
    }
}
