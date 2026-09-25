// 촬영 탭(앱 시작 화면): 라이브 보정 프리뷰·인물 모드·프리셋 스트립·셔터·마지막 사진·후처리 배지.
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
            // 인물 모드 스위치(앱 상태, 마지막 상태 기억). 실제 인물 보정은 R1-S5에서 연결.
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $services.portraitModeEnabled) {
                    Label("인물", systemImage: "person.crop.circle")
                }
                .toggleStyle(.button)
                .disabled(true)
                Text("인물 보정 준비 중")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("모드", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f×", vm.zoomFactor))
                    .font(.footnote.monospacedDigit().weight(.semibold))
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

    /// .photo 프리셋의 사진 비율(세로 3:4) 그대로 보여 준다 → aspect-fill이어도 잘리는 부분이 없어 저장본과 구도가 같다.
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

    private var thumbnail: some View {
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
        .accessibilityLabel("마지막으로 촬영한 사진")
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
