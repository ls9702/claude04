// 촬영 탭(앱 시작 화면): 전체화면 9:16 라이브 보정 프리뷰(얼굴 마커·길게 눌러 원본·기기 경고 배너·카메라 중단 안내)·렌즈(0.5×/1×/2×·전면 전환)·[원본]/[인물 ▾]/[배경 ▾] 메뉴·셔터·마지막 사진(→ 사진 앱, 없으면 보관함 최근 사진)·후처리 배지.
import SwiftData
import SwiftUI

struct CaptureView: View {
    @StateObject private var vm = CaptureViewModel()
    @EnvironmentObject private var services: AppServices
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @State private var mode: Mode = .photo
    @State private var permissionDenied = false
    @State private var flash = false
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    /// 촬영 탭이 화면에 보이는지. 다른 탭에 있을 때 앱이 활성화돼도 카메라를 켜지 않기 위해.
    @State private var isVisible = false
    /// 프리뷰를 길게 누르는 동안 true → 라이브 보정을 건너뛰고 원본 프레임 표시.
    @GestureState private var isPressingPreview = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// 탭해서 접은 경고(종류별). 그 경고가 사라지면 목록에서도 뺀다(다시 생기면 펼쳐서 보인다).
    @State private var collapsedWarnings: Set<DeviceWarning.Kind> = []
    /// 효과 선택 시트(R2).
    @State private var showEffects = false

    enum Mode: String, CaseIterable { case photo = "사진", shorts = "쇼츠" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
                deniedView
            } else {
                // 전체화면: 9:16 프리뷰를 화면 가운데에 크게 깔고, 상단 바·하단 조작부는 그 위에 반투명으로 얹는다.
                // 저장 사진도 16:9 포맷(12 Pro 4032×2268)이라 보이는 그대로 저장된다(CameraService.configureFormat).
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .background(barGradient(from: .top))
                    warningBanner
                    Spacer(minLength: 0)
                    shortsNotice
                    bottomControls
                        .background(barGradient(from: .bottom).ignoresSafeArea(edges: .bottom))
                }
            }

            // 촬영 순간 깜빡임
            Color.white
                .ignoresSafeArea()
                .opacity(flash ? 0.8 : 0)
                .allowsHitTesting(false)

            if let msg = vm.toastMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 300)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .task(id: msg) {
                    // 저장 완료는 짧게, 오류(원인·조치 문구)는 읽을 시간을 준다.
                    let isError = msg != vm.camera.lastSavedMessage
                    try? await Task.sleep(for: .seconds(isError ? 4 : 2))
                    vm.clearToast()
                }
            }
        }
        .task {
            // 앱 전역 저장·위치 서비스 주입과 프레임 파이프라인 연결.
            vm.configure(services: services)
            vm.syncPresets(presets)
            let cam = await Permissions.requestCamera()
            // 마이크 권한은 영상 녹화(릴리즈 3)에서 요청한다. 릴리즈 1(사진)은 첫 실행에 묻지 않는다.
            permissionDenied = !cam
            // 위치는 "앱 사용 중" 권한만 요청한다. 거부해도 위치 없이 촬영·저장된다(PLAN §3.4).
            services.locationProvider.start()
            guard cam else { return }
            vm.startCamera()
            vm.loadLatestLibraryThumbnail()
        }
        .onAppear {                        // 다른 탭에서 돌아옴(권한 전이면 아무 일 없음)
            isVisible = true
            vm.resume()
            vm.loadLatestLibraryThumbnail()   // 다른 앱에서 찍은 사진 반영(이번 실행에 찍은 사진이 있으면 그대로)
        }
        .onDisappear {                     // 다른 탭으로 감: 세션·프레임 처리 정지(발열·배터리)
            isVisible = false
            vm.pause()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: if !permissionDenied && isVisible { vm.resume() }
            case .background: vm.pause()
            default: break
            }
        }
        .onChange(of: services.selectedPresetID) { _, _ in vm.syncPresets(presets) }
        .onChange(of: presets.map(\.id)) { _, _ in vm.syncPresets(presets) }
        .onChange(of: presets.map(\.paramsData)) { _, _ in vm.syncPresets(presets) }
        .onChange(of: services.portraitModeEnabled) { _, _ in vm.refreshContext() }
        // 설정 탭 프레임 레이트(30/24). 저전력 모드면 ViewModel이 24로 낮춘다.
        .onChange(of: services.preferredFrameRate) { _, _ in vm.applyFrameRate() }
        .onChange(of: vm.deviceWarnings.map(\.kind)) { _, kinds in
            collapsedWarnings.formIntersection(kinds)
        }
        // 강도 칩·직접 값(앨범에서 바꾼 경우 포함) → 현재 params의 인물 값만 다시 계산.
        .onChange(of: services.portraitStrength) { _, _ in vm.refreshPortrait() }
        .onChange(of: services.customPortrait) { _, _ in vm.refreshPortrait() }
        .onChange(of: isPressingPreview) { _, pressing in vm.setBypass(pressing) }
        // 전면 카메라 전환 시 한 번만 묻는다. 어느 쪽으로 답하든(바깥 탭 = 나중에) 다시 묻지 않는다.
        .confirmationDialog("셀피에 인물 모드를 켤까요?", isPresented: suggestionBinding, titleVisibility: .visible) {
            Button("켜기") { vm.answerPortraitSuggestion(enable: true) }
            Button("나중에", role: .cancel) { vm.answerPortraitSuggestion(enable: false) }
        } message: {
            Text("피부·윤곽 보정을 라이브로 보면서 찍을 수 있습니다. 촬영 버튼 오른쪽 얼굴 버튼으로 언제든 바꿀 수 있어요.")
        }
    }

    private var suggestionBinding: Binding<Bool> {
        Binding(get: { vm.showPortraitSuggestion },
                set: { shown in
                    // 바깥 탭 등으로 닫힘: "나중에"로 기억한다.
                    if !shown && vm.showPortraitSuggestion { vm.answerPortraitSuggestion(enable: false) }
                })
    }

    // MARK: 권한 거부

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("카메라 권한이 필요합니다").font(.headline)
            Text("설정 > TripShot에서 카메라와 마이크를 허용해 주세요.").font(.footnote).foregroundStyle(.secondary)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        .multilineTextAlignment(.center)
        .padding()
    }

    // MARK: 상단 바

    private var topBar: some View {
        HStack(alignment: .center) {
            // 인물 모드 버튼은 셔터 오른쪽으로 옮겼다(R1-S8b U5). 좌측은 비워 모드 선택을 가운데에 둔다.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)

            Picker("모드", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 10) {
                    Text(Self.zoomLabel(vm.zoomFactor))
                        .font(.footnote.monospacedDigit().weight(.semibold))
                    // 전면 ↔ 후면 전환. 전환 중 프리뷰가 잠깐 멈출 수 있다.
                    Button {
                        vm.toggleCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.body)
                    }
                    .accessibilityLabel(vm.isFrontCamera ? "후면 카메라로 전환" : "전면 카메라로 전환")
                }
                if vm.thermalState == .serious || vm.thermalState == .critical {
                    Label("발열로 프리뷰 화질 낮춤", systemImage: "thermometer.high")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.iconOnly)
                }
                #if DEBUG
                Text(vm.stats)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: 프리뷰

    /// 위·아래 조작부 뒤의 어두운 그라디언트(프리뷰 위에서 글자·버튼이 보이게).
    private func barGradient(from edge: VerticalEdge) -> some View {
        LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                       startPoint: edge == .top ? .top : .bottom,
                       endPoint: edge == .top ? .bottom : .top)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var shortsNotice: some View {
        if mode == .shorts {
            Text("쇼츠 촬영 보조는 릴리즈 3에서 추가됩니다")
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 8)
        }
    }

    /// 세로 9:16(활성 포맷 16:9 = 저장 사진 비율). 프레임이 4:3으로 폴백돼도 aspect-fill이라 화면은 9:16으로 꽉 찬다
    /// (그때는 저장본 좌우가 화면보다 넓다).
    private var previewArea: some View {
        MetalPreviewView(coordinator: vm.preview) { devicePoint, viewPoint in
            // 원본 보기 중이거나 방금 뗀 탭은 포커스로 쓰지 않는다(길게 누르기와 충돌 방지).
            if vm.focus(at: devicePoint) { showFocus(at: viewPoint) }
        }
        .aspectRatio(CGFloat(AspectRatio.sixteenByNine.portraitWidthOverHeight), contentMode: .fit)
        .overlay {
            // 라이브 얼굴 마커: 인물 모드에서 얼굴이 잡히면 모서리 표시, 새 얼굴이 나타나고 1초 뒤 사라진다.
            // 프레임은 연결 단계에서 이미 미러돼 있어(전면) 화면과 좌표가 같으므로 x 반전은 하지 않는다.
            // TODO(검증): 전면에서 마커가 얼굴과 좌우 반대로 보이면 mirrored: vm.isFrontCamera로.
            FaceMarkerOverlay(rects: vm.faceMarkers, imageSize: vm.faceMarkerImageSize, mirrored: false)
                .allowsHitTesting(false)
        }
        .overlay {
            if let message = vm.interruptionMessage {
                // 세션 중단(전화·다른 앱 카메라 점유 등). 중단이 끝나면 카메라가 스스로 재개하고 이 안내도 사라진다.
                VStack(spacing: 8) {
                    Image(systemName: "pause.circle")
                        .font(.largeTitle)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(24)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if isPressingPreview {
                Text("원본")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let focusPoint {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .gesture(
            // 시그니처(iOS 17+): MagnifyGesture.Value.magnification: CGFloat
            MagnifyGesture()
                .onChanged { value in vm.pinchChanged(value.magnification) }
                .onEnded { _ in vm.pinchEnded() }
        )
        // 라이브 전/후: 0.2초 이상 누르면 손을 뗄 때까지 원본. 핀치와 동시 인식, 탭 포커스는 UIKit 인식기라
        // 여기서 순서를 정할 수 없어 ViewModel이 원본 보기 중·직후의 탭을 무시한다.
        // TODO(검증): 최소 거리 0 DragGesture가 MTKView의 UITapGestureRecognizer를 막지 않는지, 핀치 중 길게 누르기가 켜지지 않는지 실기기 확인.
        .simultaneousGesture(beforeAfterGesture)
    }

    // MARK: 경고 배너

    /// 가장 심각한 경고 하나만 프리뷰 위쪽에. 탭하면 작은 아이콘으로 접히고, 아이콘을 탭하면 다시 펼친다.
    @ViewBuilder
    private var warningBanner: some View {
        if let warning = vm.deviceWarnings.first {
            let collapsed = collapsedWarnings.contains(warning.kind)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsed { collapsedWarnings.remove(warning.kind) } else { collapsedWarnings.insert(warning.kind) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.warningIcon(warning.kind))
                    if !collapsed {
                        Text(warning.message)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .foregroundStyle(warning.level == .caution ? Color.black : Color.white)
                .padding(.horizontal, collapsed ? 8 : 12).padding(.vertical, 6)
                .background(Self.warningColor(warning.level), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel(warning.message)
            .accessibilityHint(collapsed ? "펼치기" : "접기")
        }
    }

    nonisolated static func warningIcon(_ kind: DeviceWarning.Kind) -> String {
        switch kind {
        case .thermalCritical, .thermalSerious: return "thermometer.high"
        case .lowBattery: return "battery.25"
        case .lowPower: return "leaf.fill"
        case .lowDisk: return "externaldrive.badge.exclamationmark"
        }
    }

    static func warningColor(_ level: DeviceWarning.Level) -> Color {
        switch level {
        case .critical: return Color.red.opacity(0.9)
        case .caution: return Color.yellow.opacity(0.9)
        case .info: return Color.gray.opacity(0.8)
        }
    }

    /// 누르고 0.2초가 지나면 손을 뗄 때까지 원본(앨범 보정 화면과 같은 제스처).
    private var beforeAfterGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isPressingPreview) { value, state, _ in
                switch value {
                case .second(true, _): state = true
                default: break
                }
            }
    }

    private func showFocus(at point: CGPoint) {
        focusPoint = point
        focusToken &+= 1
        let token = focusToken
        Task {
            try? await Task.sleep(for: .seconds(1))
            if token == focusToken { focusPoint = nil }
        }
    }

    // MARK: 하단

    private var bottomControls: some View {
        VStack(spacing: 14) {
            lensButtons

            if mode == .photo {
                lookMenus
            }

            HStack {
                thumbnail
                    .frame(maxWidth: .infinity, alignment: .leading)

                ShutterButton(isVideo: mode == .shorts) {
                    guard mode == .photo else { return }
                    vm.capture()
                    flashScreen()
                }

                portraitControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
    }

    // MARK: 원본 / 인물 / 배경

    /// 작은 캡슐 3개: [원본] [인물 ▾ 자연·보통·강함] [배경 ▾ 자동·프리셋]. 켜진 것은 노란색, 라벨에 선택 값 표시.
    private var lookMenus: some View {
        HStack(spacing: 8) {
            Button {
                vm.selectOriginal()
            } label: {
                lookLabel("원본", detail: nil, isOn: vm.look == .original, hasMenu: false)
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(PortraitStrength.allCases) { strength in
                    Button {
                        vm.selectPortrait(strength)
                    } label: {
                        if vm.look == .portrait && vm.portraitStrengthSelection == strength {
                            Label(strength.title, systemImage: "checkmark")
                        } else {
                            Text(strength.title)
                        }
                    }
                }
            } label: {
                lookLabel("인물", detail: vm.look == .portrait ? (vm.portraitStrengthSelection?.title ?? "직접") : nil,
                          isOn: vm.look == .portrait, hasMenu: true)
            }

            Menu {
                sceneItem("자동", choice: .auto, params: PresetParams())
                ForEach(presets) { preset in
                    sceneItem(preset.name, choice: .preset(preset.id), params: preset.params)
                }
            } label: {
                lookLabel("배경", detail: vm.look == .scene ? sceneName : nil, isOn: vm.look == .scene, hasMenu: true)
            }
        }
    }

    private var sceneName: String {
        switch vm.choice {
        case .preset(let id): return presets.first { $0.id == id }?.name ?? "자동"
        default: return "자동"
        }
    }

    private func sceneItem(_ title: String, choice: PresetChoice, params: PresetParams) -> some View {
        Button {
            vm.selectScene(choice: choice, params: params)
        } label: {
            if vm.look == .scene && vm.choice == choice {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func lookLabel(_ title: String, detail: String?, isOn: Bool, hasMenu: Bool) -> some View {
        HStack(spacing: 3) {
            Text(detail.map { "\(title) · \($0)" } ?? title)
                .lineLimit(1)
            if hasMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .font(.footnote.weight(isOn ? .semibold : .regular))
        .foregroundStyle(isOn ? Color.black : Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(isOn ? Color.yellow : Color.white.opacity(0.15)))
        .contentShape(Capsule())
    }

    // MARK: 렌즈

    /// 렌즈 버튼 행(0.5×·1×·2×). 기기에 없는 렌즈·전면에서는 해당 버튼이 빠지고, 하나뿐이면 행을 숨긴다.
    @ViewBuilder
    private var lensButtons: some View {
        let factors = vm.lensFactors
        if factors.count > 1 {
            let selected = Self.selectedLens(zoom: vm.zoomFactor, factors: factors)
            HStack(spacing: 12) {
                ForEach(factors, id: \.self) { factor in
                    let isOn = factor == selected
                    Button {
                        vm.selectLens(factor)
                    } label: {
                        Text(Self.lensLabel(factor))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(isOn ? Color.yellow : Color.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(isOn ? 0.25 : 0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.lensLabel(factor)) 렌즈")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    /// 현재 배율에서 강조할 렌즈 버튼: 배율 이하인 버튼 중 가장 큰 것(예: 1.4× → 1×). 반올림 오차 허용.
    nonisolated static func selectedLens(zoom: CGFloat, factors: [CGFloat]) -> CGFloat? {
        factors.filter { $0 <= zoom + 0.01 }.max() ?? factors.min()
    }

    nonisolated static func lensLabel(_ factor: CGFloat) -> String {
        factor < 1 ? String(format: "%.1f×", factor) : String(format: "%.0f×", factor)
    }

    nonisolated static func zoomLabel(_ factor: CGFloat) -> String {
        String(format: "%.1f×", factor)
    }

    // MARK: 마지막 사진

    /// 마지막 사진 썸네일. 탭하면 사진 앱을 연다.
    /// 특정 사진(에셋)으로 바로 여는 공개 API는 없어서 `photos-redirect://`로 사진 앱을 여는 데까지만 한다
    /// (보통 "보관함" 탭의 최근 항목이 보이므로 방금 찍은 사진이 바로 보인다).
    /// TODO(검증): `photos-redirect://` 스킴이 iOS 27에서도 사진 앱을 여는지 실기기 확인(비공개 문서화 스킴).
    private var thumbnail: some View {
        Button {
            if let url = URL(string: "photos-redirect://") { openURL(url) }
        } label: {
            thumbnailImage
        }
        .buttonStyle(.plain)
        .accessibilityLabel("마지막 사진")
        .accessibilityHint("사진 앱을 엽니다")
    }

    private var thumbnailImage: some View {
        Group {
            if let image = vm.lastThumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.4), lineWidth: 1))
    }

    // MARK: 인물 버튼

    /// 셔터 오른쪽: [효과] 버튼(R2, 켜져 있으면 노란 테두리 + 그 효과 아이콘) + 후처리 배지 + 얼굴 수.
    private var portraitControl: some View {
        VStack(spacing: 4) {
            Button {
                showEffects = true
            } label: {
                Group {
                    if let effect = vm.effect {
                        Text(effect.icon).font(.system(size: 26))
                    } else {
                        Image(systemName: "sparkles").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .overlay(Circle().stroke(vm.effect == nil ? .clear : Color.yellow, lineWidth: 2.5))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) { processingBadge }
            .accessibilityLabel("효과")
            .accessibilityValue(vm.effect?.title ?? "없음")
            .sheet(isPresented: $showEffects) {
                EffectPickerView(selection: vm.effect) { kind in
                    vm.selectEffect(kind)
                }
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
            }

            // 인물 보정 중인 얼굴 수(PLAN §3.3 "지금 인물 보정 중" 표시). 자리를 유지해 버튼이 흔들리지 않게 한다.
            Text(faceCountText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.yellow)
                .frame(height: 12)
                .accessibilityHidden(faceCountText.isEmpty)
                .accessibilityLabel("인물 보정 중, 얼굴 \(vm.detectedFaceCount)명")
        }
    }

    private var faceCountText: String {
        guard services.portraitModeEnabled, vm.detectedFaceCount > 0 else { return "" }
        return "얼굴 \(vm.detectedFaceCount)"
    }

    /// 후처리 중인 장 수(인물 버튼 위 작은 뱃지).
    @ViewBuilder
    private var processingBadge: some View {
        if vm.processingCount > 0 {
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                Text("\(vm.processingCount)")
                    .font(.caption2.monospacedDigit())
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .offset(x: 12, y: -12)
            .allowsHitTesting(false)
            .accessibilityLabel("보정 저장 중 \(vm.processingCount)장")
        }
    }

    private func flashScreen() {
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.easeOut(duration: 0.15)) { flash = false }
        }
    }
}

struct ShutterButton: View {
    var isVideo: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                if isVideo {
                    RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 56, height: 56)
                } else {
                    Circle().fill(.white).frame(width: 64, height: 64)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isVideo ? "녹화" : "촬영")
    }
}

// MARK: - 라이브 얼굴 마커

/// 얼굴 마커 좌표 변환(순수 함수, 테스트 대상).
enum FaceMarkerGeometry {
    /// 프리뷰 이미지 정규화 사각형(0~1, 원점 좌하단) → 뷰 좌표(원점 좌상단). 프리뷰는 aspect-fill.
    /// - Parameters:
    ///   - imageSize: 프리뷰 이미지 크기(비율만 쓴다). 0이면 세로 3:4.
    ///   - mirrored: 화면이 이미지를 좌우 반전해 그릴 때만 true(x 반전). 이 앱은 프레임 자체가 미러되므로 false.
    static func viewRect(normalized r: CGRect, imageSize: CGSize, viewSize: CGSize, mirrored: Bool) -> CGRect {
        let size = (imageSize.width > 0 && imageSize.height > 0) ? imageSize : CGSize(width: 3, height: 4)
        let fit = MetalPreviewView.fitRect(image: CGRect(origin: .zero, size: size), drawable: viewSize, mode: .fill)
        let x = mirrored ? 1 - r.maxX : r.minX
        let yTop = 1 - r.maxY   // 원점 좌하단 → 좌상단
        return CGRect(x: fit.minX + x * fit.width,
                      y: fit.minY + yTop * fit.height,
                      width: r.width * fit.width,
                      height: r.height * fit.height)
    }
}

/// 얼굴 네 모서리에 짧은 노란 선. 새 얼굴(인덱스)이 나타나면 보였다가 1초 뒤 사라진다.
struct FaceMarkerOverlay: View {
    let rects: [CGRect]
    let imageSize: CGSize
    let mirrored: Bool

    /// 지금 보이는 마커 인덱스(얼굴 id는 인덱스로 단순 처리).
    @State private var visible: Set<Int> = []
    /// 인덱스별 표시 세대(같은 인덱스가 다시 나타나면 이전 페이드 예약을 무효화).
    @State private var generation: [Int: Int] = [:]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                let r = FaceMarkerGeometry.viewRect(normalized: rect, imageSize: imageSize,
                                                    viewSize: geo.size, mirrored: mirrored)
                CornerMarker(rect: r)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .opacity(visible.contains(index) ? 1 : 0)
            }
        }
        .onChange(of: rects.count) { old, new in
            if new < old { visible = visible.filter { $0 < new } }
            guard new > old else { return }
            for index in old..<new { show(index) }
        }
        .onAppear {
            for index in rects.indices { show(index) }
        }
    }

    private func show(_ index: Int) {
        let gen = (generation[index] ?? 0) + 1
        generation[index] = gen
        visible.insert(index)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard generation[index] == gen else { return }
            withAnimation(.easeOut(duration: 0.3)) { _ = visible.remove(index) }
        }
    }
}

/// 사각형 네 모서리의 L자 선(변 길이의 20%).
private struct CornerMarker: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height) * 0.2
        let r = rect
        // 좌상
        p.move(to: CGPoint(x: r.minX, y: r.minY + len)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        // 우상
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        // 우하
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - len)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - len, y: r.maxY))
        // 좌하
        p.move(to: CGPoint(x: r.minX + len, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - len))
        return p
    }
}
