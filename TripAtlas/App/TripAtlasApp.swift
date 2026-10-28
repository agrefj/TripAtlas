import SwiftUI
import SwiftData

@main
struct TripAtlasApp: App {
    @State private var importer = TripImporter()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(importer)
        }
        .modelContainer(for: [Trip.self, DismissedSuggestion.self])
    }
}
