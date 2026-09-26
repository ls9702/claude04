// 설정 탭: 촬영 옵션(프레임 레이트)·인물 모드·보정 프리셋·쇼츠(릴리즈 3)·백업(JSON 내보내기/가져오기)·정보(모델·커널 상태, 무료 서명 만료)·앱 데이터 초기화.
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: AppServices
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @Query(sort: \ShotTemplate.sortOrder) private var templates: [ShotTemplate]
    @Query(sort: \FormatPreset.sortOrder) private var formats: [FormatPreset]
    @Query private var tracks: [MusicTrack]

    /// 마지막으로 백업 파일을 만든 시각(1970 기준 초, 0 = 없음).
    @AppStorage("lastBackupAt") private var lastBackupAt: Double = 0

    // 백업·복원 상태
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var pendingRestore: BackupDocument?
    /// 복원 방식 선택 표시. 버튼 동작보다 먼저 false로 바뀔 수 있어 `pendingRestore`와 따로 둔다.
    @State private var showRestoreDialog = false
    @State private var alertTitle = ""
    @State private var alertMessage: String?
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                captureSection
                portraitSection
                presetSection
                shortsSection
                backupSection
                infoSection
                resetSection
            }
            .navigationTitle("설정")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        // 가져온 백업을 어떻게 적용할지(병합/교체/취소).
        .confirmationDialog("백업을 어떻게 복원할까요?", isPresented: $showRestoreDialog, titleVisibility: .visible) {
            Button("병합 (같은 이름은 갱신, 나머지 유지)") { performRestore(mode: .merge) }
            Button("교체 (직접 만든 항목을 지우고 백업으로)", role: .destructive) { performRestore(mode: .replace) }
            Button("취소", role: .cancel) { pendingRestore = nil }
        } message: {
            if let doc = pendingRestore {
                Text("\(doc.exportedAt.formatted(date: .abbreviated, time: .shortened)) 백업 — 프리셋 \(doc.presets.count)개, 템플릿 \(doc.templates.count)개. 기본 프리셋은 지우지 않고 값만 바뀝니다. 사진은 영향이 없습니다.")
            }
        }
        .confirmationDialog("앱 데이터를 초기화할까요?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("초기화", role: .destructive) { resetAppData() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("직접 만든 프리셋과 설정(인물 모드·강도·프레임 레이트·선택 프리셋)을 지우고 기본 프리셋 값을 처음으로 되돌립니다. 사진 보관함의 사진은 건드리지 않습니다.")
        }
        .alert(alertTitle, isPresented: alertBinding) {
            Button("확인", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: 촬영 옵션

    private var captureSection: some View {
        Section {
            Picker("프리뷰 프레임 레이트", selection: $services.preferredFrameRate) {
                ForEach(AppServices.frameRateOptions, id: \.self) { fps in
                    Text("\(Int(fps))fps").tag(fps)
                }
            }
        } header: {
            Text("촬영 옵션")
        } footer: {
            Text("24fps는 발열과 배터리 사용을 줄입니다. 저전력 모드에서는 자동으로 24fps가 됩니다. 사진 화질에는 영향이 없습니다.")
        }
    }

    // MARK: 인물 모드

    private var portraitSection: some View {
        Section {
            Toggle("인물 모드", isOn: $services.portraitModeEnabled)
            VStack(alignment: .leading, spacing: 8) {
                Text("강도").font(.subheadline).foregroundStyle(.secondary)
                PortraitStrengthChips(selection: services.customPortrait == nil ? services.portraitStrength : nil) { strength in
                    services.selectPortraitStrength(strength)
                }
            }
            .padding(.vertical, 4)
            Button("직접 값 초기화") {
                // 직접 값을 지우고 지금 단계(칩) 값으로 돌아간다.
                services.selectPortraitStrength(services.portraitStrength)
            }
            .disabled(services.customPortrait == nil)
        } header: {
            Text("인물 모드")
        } footer: {
            Text("촬영·보정 화면에서 슬라이더로 바꾼 값은 \"직접\"으로 표시됩니다. 초기화하면 선택한 강도 값으로 돌아갑니다.")
        }
    }

    // MARK: 보정 프리셋

    private var presetSection: some View {
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
    }

    // MARK: 쇼츠 (릴리즈 3)

    private var shortsSection: some View {
        Section {
            DisclosureGroup("템플릿·규격·음원") {
                ForEach(templates) { t in
                    LabeledContent(t.name, value: t.shots.isEmpty ? "자유" : "\(t.shots.count)샷 · \(Int(t.totalSeconds))초")
                }
                ForEach(formats) { f in
                    LabeledContent(f.name, value: "\(f.width)×\(f.height)")
                }
                ForEach(tracks) { LabeledContent($0.title, value: "\(Int($0.durationSeconds))초") }
            }
        } header: {
            Text("쇼츠")
        } footer: {
            Text("템플릿·규격 편집과 YouTube 음원 가져오기는 릴리즈 3에서 추가됩니다.")
        }
    }

    // MARK: 백업

    private var backupSection: some View {
        Section {
            Button {
                makeExportFile()
            } label: {
                Label("백업 파일 내보내기", systemImage: "square.and.arrow.up")
            }
            if let exportURL {
                // 파일을 만든 뒤 공유 시트(파일 앱에 저장·AirDrop 등)로 보낸다.
                ShareLink(item: exportURL) {
                    Label(exportURL.lastPathComponent, systemImage: "doc.text")
                        .font(.footnote)
                }
            }
            Button {
                showImporter = true
            } label: {
                Label("백업 파일 가져오기", systemImage: "square.and.arrow.down")
            }
            LabeledContent("마지막 백업", value: lastBackupText)
        } header: {
            Text("백업")
        } footer: {
            Text("무료 서명은 7일마다 재설치가 필요합니다. 재설치해도 앱 데이터는 유지되지만, 기기 교체·삭제에 대비해 백업해 두세요.")
        }
    }

    private var lastBackupText: String {
        guard lastBackupAt > 0 else { return "없음" }
        return Date(timeIntervalSince1970: lastBackupAt).formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: 정보

    private var infoSection: some View {
        Section("정보") {
            LabeledContent("버전", value: versionText)
            LabeledContent("저조도 모델", value: services.lowLight.isModelAvailable ? "있음" : "없음(폴백)")
            LabeledContent("저조도 커널", value: services.lowLight.isKernelAvailable ? "로드됨" : "없음(폴백)")
            LabeledContent("인물 보정 커널", value: portraitKernelText)
            LabeledContent("마지막 저조도 경로", value: lowLightPathText)
            LabeledContent("설치일", value: services.installDate.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("서명 만료 예정", value: expiryText)
            Text("무료 Apple ID 서명은 설치 후 7일간 유효합니다. 만료 전 Mac에 연결해 다시 설치하세요(앱 데이터 유지).")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var portraitKernelText: String {
        guard let kernels = services.portraitKernels else { return "없음(폴백)" }
        return kernels.faceWarp == nil ? "로드됨(워프 없음)" : "로드됨"
    }

    private var lowLightPathText: String {
        switch services.lowLight.lastPath {
        case .model?: return "모델"
        case .fallback(let reason)?: return "폴백: \(reason)"
        case nil: return "아직 실행 안 함"
        }
    }

    private var expiryText: String {
        let expiry = SigningInfo.effectiveExpiry(installDate: services.installDate,
                                                 provisioning: SigningInfo.bundleProvisioningExpiry)
        let days = SigningInfo.daysRemaining(until: expiry.date)
        let date = expiry.date.formatted(date: .abbreviated, time: .omitted)
        return "\(date)\(expiry.isEstimate ? "(추정)" : "") · \(SigningInfo.remainingText(days: days))"
    }

    // MARK: 초기화

    private var resetSection: some View {
        Section {
            Button("앱 데이터 초기화", role: .destructive) { showResetConfirm = true }
        } footer: {
            Text("직접 만든 프리셋과 설정만 지웁니다. 사진 보관함의 사진은 건드리지 않습니다.")
        }
    }

    // MARK: 동작

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

    private func makeExportFile() {
        let doc = Backup.make(context: modelContext, services: services)
        do {
            exportURL = try Backup.writeTemporaryFile(doc)
            lastBackupAt = doc.exportedAt.timeIntervalSince1970
        } catch {
            showAlert("백업 파일을 만들지 못했습니다", UserMessage.text(for: error))
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                pendingRestore = try Backup.readImportedFile(at: url)
                // TODO(검증): 파일 선택기가 닫히는 중에 확인 대화상자를 띄워도 표시되는지 실기기 확인
                // (안 뜨면 짧은 지연 뒤 true로).
                showRestoreDialog = true
            } catch {
                showAlert("백업을 가져오지 못했습니다", UserMessage.text(for: error))
            }
        case .failure(let error):
            showAlert("백업을 가져오지 못했습니다", UserMessage.text(for: error))
        }
    }

    private func performRestore(mode: RestoreMode) {
        guard let doc = pendingRestore else { return }
        pendingRestore = nil
        do {
            let summary = try Backup.restore(doc, context: modelContext, services: services, mode: mode)
            showAlert("복원 완료", summary.message)
        } catch {
            showAlert("복원하지 못했습니다", UserMessage.text(for: error))
        }
    }

    private func resetAppData() {
        do {
            try Backup.resetAppData(context: modelContext, services: services)
            showAlert("초기화 완료", "직접 만든 프리셋과 설정을 지웠습니다. 사진은 그대로입니다.")
        } catch {
            showAlert("초기화하지 못했습니다", UserMessage.text(for: error))
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }
}
