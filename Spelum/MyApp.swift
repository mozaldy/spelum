import SwiftData
import SwiftUI

@main
struct MyApp: App {
    private let modelContainer: ModelContainer?
    private let initializationError: String?

    init() {
        do {
            let container = try PresentationStore.makeModelContainer()
            let attemptStore = AttemptStore(modelContext: container.mainContext)
            _ = try? attemptStore.recoverUnfinishedAttempts()
            self.modelContainer = container
            self.initializationError = nil
        } catch {
            self.modelContainer = nil
            self.initializationError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                ContentView()
                    .modelContainer(modelContainer)
            } else {
                ContentUnavailableView(
                    "Storage Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(
                        initializationError ?? "Spelum could not open its local presentation library."
                    )
                )
            }
        }
    }
}
