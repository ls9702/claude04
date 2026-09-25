import SwiftUI

struct RootTabView: View {
    @State private var selection: Tab = .capture

    enum Tab: Hashable { case capture, enhance, shorts, settings }

    var body: some View {
        TabView(selection: $selection) {
            CaptureView()
                .tabItem { Label("촬영", systemImage: "camera.fill") }
                .tag(Tab.capture)
            EnhanceView()
                .tabItem { Label("보정", systemImage: "wand.and.stars") }
                .tag(Tab.enhance)
            ShortsView()
                .tabItem { Label("쇼츠", systemImage: "film.stack.fill") }
                .tag(Tab.shorts)
            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}

#Preview {
    RootTabView()
}
