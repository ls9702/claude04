import SwiftData
import SwiftUI

struct SettingsView: View {
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @Query(sort: \ShotTemplate.sortOrder) private var templates: [ShotTemplate]
    @Query(sort: \FormatPreset.sortOrder) private var formats: [FormatPreset]
    @Query private var tracks: [MusicTrack]

    var body: some View {
        NavigationStack {
            List {
                Section("보정 프리셋") {
                    ForEach(presets) { p in
                        LabeledContent(p.name, value: p.isBuiltIn ? "기본" : "직접")
                    }
                }
                Section("쇼츠 템플릿") {
                    ForEach(templates) { t in
                        LabeledContent(t.name, value: t.shots.isEmpty ? "자유" : "\(t.shots.count)샷 · \(Int(t.totalSeconds))초")
                    }
                }
                Section("규격") {
                    ForEach(formats) { f in
                        LabeledContent(f.name, value: "\(f.width)×\(f.height)")
                    }
                }
                Section("음원 라이브러리") {
                    if tracks.isEmpty {
                        Text("YouTube 링크 가져오기는 P3에서 추가됩니다.").foregroundStyle(.secondary)
                    } else {
                        ForEach(tracks) { LabeledContent($0.title, value: "\(Int($0.durationSeconds))초") }
                    }
                }
                Section("정보") {
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    Text("무료 Apple ID 서명은 설치 후 7일간 유효합니다. 만료 전 Mac에서 다시 설치하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
        }
    }
}
