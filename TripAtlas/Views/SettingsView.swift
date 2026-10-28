import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(SettingsKeys.homeRadiusKm) private var homeRadiusKm: Double = 80
    @AppStorage(SettingsKeys.maxGapHours) private var maxGapHours: Double = 72
    @AppStorage(SettingsKeys.minPhotos) private var minPhotos: Int = 5

    @Query private var dismissed: [DismissedSuggestion]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Радиус дома: \(Int(homeRadiusKm)) км", value: $homeRadiusKm, in: 20...500, step: 10)
                    Stepper("Разрыв в поездке: \(Int(maxGapHours)) ч", value: $maxGapHours, in: 24...240, step: 12)
                    Stepper("Минимум фото: \(minPhotos)", value: $minPhotos, in: 1...50)
                } header: {
                    Text("Распознавание поездок")
                } footer: {
                    Text("Поездкой считаются фото, снятые дальше радиуса от дома. Если между фото прошло больше указанного разрыва — это разные поездки. Изменения применяются при следующем сканировании.")
                }

                Section {
                    Button("Вернуть скрытые (\(dismissed.count))") {
                        try? context.delete(model: DismissedSuggestion.self)
                        try? context.save()
                    }
                    .disabled(dismissed.isEmpty)
                } footer: {
                    Text("Скрытые и удалённые поездки снова начнут предлагаться.")
                }

                Section {
                    Label("Фото анализируются только на устройстве. Для названий городов в Apple отправляются лишь координаты.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
