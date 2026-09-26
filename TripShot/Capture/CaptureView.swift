// 촬영 탭(앱 시작 화면): 라이브 보정 프리뷰·인물 모드·렌즈(0.5×/1×/2×·전면 전환)·프리셋 스트립·셔터·마지막 사진(→ 사진 앱)·후처리 배지.
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    enum Mode: String, CaseIterable { case photo = "사진", shorts = "쇼츠" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
                deniedView
            } else {
                VStack(spacing: 0) {
                    topBar
                    previewArea
                    Spacer(minLength: 0)
                    bottomControls
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
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 190)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(2))
                    vm.clearToast()
                }
            }
        }
        .task {
            // 앱 전역 저장·위치 서비스 주입과 프레임 파이프라인 연결.
            vm.configure(services: services)
            vm.syncPresets(presets)
            let cam = await Permissions.requestCamera()
            _ = await Permissions.requestMicrophone()
            permissionDenied = !cam
            // 위치는 "앱 사용 중" 권한만 요청한다. 거부해도 위치 없이 촬영·저장된다(PLAN §3.4).
            services.locationProvider.start()
            guard cam else { return }
            vm.startCamera()
        }
        .onAppear {                        // 다른 탭에서 돌아옴(권한 전이면 아무 일 없음)
            isVisible = true
            vm.resume()
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
            // 인물 모드 스위치(앱 상태, 마지막 상태 기억). 켜져 있고 얼굴이 잡히면 작은 얼굴 표시(PLAN §3.3).
            HStack(spacing: 6) {
                Toggle(isOn: $services.portraitModeEnabled) {
                    Label("인물", systemImage: "person.crop.circle")
                }
                .toggleStyle(.button)
                if services.portraitModeEnabled && vm.detectedFaceCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "face.smiling")
                        if vm.detectedFaceCount > 1 {
                            Text("\(vm.detectedFaceCount)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("인물 보정 중, 얼굴 \(vm.detectedFaceCount)명")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

    /// 활성 포맷(4:3)의 사진 비율(세로 3:4) 그대로 보여 준다 → aspect-fill이어도 잘리는 부분이 없어 저장본과 구도가 같다.
    private var previewArea: some View {
        MetalPreviewView(coordinator: vm.preview) { devicePoint, viewPoint in
            vm.focus(at: devicePoint)
            showFocus(at: viewPoint)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay {
            if let focusPoint {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if mode == .shorts {
                Text("쇼츠 촬영 보조는 릴리즈 2에서 추가됩니다")
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .clipped()
        .gesture(
            // 시그니처(iOS 17+): MagnifyGesture.Value.magnification: CGFloat
            MagnifyGesture()
                .onChanged { value in vm.pinchChanged(value.magnification) }
                .onEnded { _ in vm.pinchEnded() }
        )
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
                PresetStrip(selection: vm.choice) { choice, params in
                    vm.select(choice: choice, params: params)
                }
            }

            HStack {
                thumbnail
                    .frame(maxWidth: .infinity, alignment: .leading)

                ShutterButton(isVideo: mode == .shorts) {
                    guard mode == .photo else { return }
                    vm.capture()
                    flashScreen()
                }

                processingBadge
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
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
        .disabled(vm.lastThumbnail == nil)
        .accessibilityLabel("마지막으로 촬영한 사진")
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

    @ViewBuilder
    private var processingBadge: some View {
        if vm.processingCount > 0 {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("보정 \(vm.processingCount)")
                    .font(.footnote.monospacedDigit())
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel("보정 저장 중 \(vm.processingCount)장")
        } else {
            Color.clear.frame(width: 52, height: 52)
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
