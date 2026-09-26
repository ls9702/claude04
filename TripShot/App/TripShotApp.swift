// 앱 진입점: SwiftData 컨테이너·시드, 앱 전역 서비스(AppServices) 생성과 주입.
import SwiftUI
import SwiftData

@main
struct TripShotApp: App {
    let container: ModelContainer
    /// 앱 전역 의존성. 화면들은 `@EnvironmentObject`로 받는다.
    @StateObject private var services = AppServices()

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
                .environmentObject(services)
                .environmentObject(services.music)
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}
