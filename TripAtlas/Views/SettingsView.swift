import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(SettingsKeys.homeRadiusKm) private var homeRadiusKm: Double = 80
    @AppStorage(SettingsKeys.maxGapHours) private var maxGapHours: Double = 72
    @AppStorage(SettingsKeys.minPhotos) private var minPhotos: Int = 5
    @AppStorage(SettingsKeys.cityBoundaries) private var useBoundaries = true
    @AppStorage(SettingsKeys.hideUtilityPhotos) private var hideUtility = true

    @Environment(BoundaryStore.self) private var boundaryStore
    @State private var clearing = false

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
                    Toggle("Скрывать служебные фото", isOn: $hideUtility)
                } header: {
                    Text("Фото")
                } footer: {
                    Text("Чеки, документы, фото экранов и досок не попадают в поездки, карточки и видео. Распознаются на устройстве (Vision), скрытые фото можно вернуть на странице поездки. Скриншоты не учитываются никогда. Действует для новых поездок.")
                }

                Section {
                    Toggle("Границы городов", isOn: $useBoundaries)
                    if useBoundaries {
                        Button {
                            clearing = true
                            Task {
                                await boundaryStore.clear()
                                clearing = false
                            }
                        } label: {
                            HStack {
                                Text("Обновить границы")
                                Spacer()
                                if clearing { ProgressView() }
                            }
                        }
                        .disabled(clearing)
                    }
                } header: {
                    Text("Карта")
                } footer: {
                    Text("Настоящие границы городов загружаются с сервера TripAtlas (данные © участники OpenStreetMap) и сохраняются на устройстве. Для этого на сервер отправляются только координаты — средняя точка ваших фото в каждом городе. Если границу найти не удалось, город показывается пунктирным кругом.")
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
                    Label("Фото анализируются только на устройстве. Для названий городов (Apple) и их границ (сервер TripAtlas на данных OpenStreetMap) отправляются лишь координаты.", systemImage: "lock.shield")
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
