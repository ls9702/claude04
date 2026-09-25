// 설정 탭: 프리셋(직접 만든 것 삭제)·템플릿·규격·음원·정보.
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: AppServices
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @Query(sort: \ShotTemplate.sortOrder) private var templates: [ShotTemplate]
    @Query(sort: \FormatPreset.sortOrder) private var formats: [FormatPreset]
    @Query private var tracks: [MusicTrack]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets) { p in
                        LabeledContent(p.name, value: p.isBuiltIn ? "기본" : "직접")
                            // 기본 프리셋은 삭제 불가(스와이프 삭제 버튼이 나오지 않음).
                            .deleteDisabled(p.isBuiltIn)
                    }
                    .onDelete(perform: deletePresets)
                } header: {
                    Text("보정 프리셋")
                } footer: {
                    Text("새 프리셋은 보정 탭의 저장 메뉴에서 만듭니다. 직접 만든 프리셋은 왼쪽으로 밀어 삭제합니다.")
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
                        Text("YouTube 링크 가져오기는 릴리즈 2에서 추가됩니다.").foregroundStyle(.secondary)
                    } else {
                        ForEach(tracks) { LabeledContent($0.title, value: "\(Int($0.durationSeconds))초") }
                    }
                }
                Section("정보") {
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    LabeledContent("저조도 모델", value: services.lowLight.isModelAvailable ? "있음" : "없음(폴백)")
                    Text("무료 Apple ID 서명은 설치 후 7일간 유효합니다. 만료 전 Mac에서 다시 설치하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
        }
    }

    /// 직접 만든 프리셋만 삭제한다. 삭제한 프리셋이 선택 프리셋이면 선택을 해제(기본 = 자동)한다.
    private func deletePresets(at offsets: IndexSet) {
        for index in offsets {
            let preset = presets[index]
            guard !preset.isBuiltIn else { continue }
            if services.selectedPresetID == preset.id { services.selectedPresetID = nil }
            modelContext.delete(preset)
        }
        try? modelContext.save()   // 실패해도 SwiftData 자동 저장이 다시 시도한다.
    }
}
