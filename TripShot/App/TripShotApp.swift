import SwiftUI
import SwiftData

@main
struct TripShotApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([Preset.self, FormatPreset.self, ShotTemplate.self, ShortsProject.self, Clip.self, MusicTrack.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData 컨테이너 생성 실패: \(error)")
        }
        Seed.runIfNeeded(context: ModelContext(container))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}
