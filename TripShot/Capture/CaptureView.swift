// 촬영 탭(앱 시작 화면): 카메라 프리뷰·모드 토글·셔터.
import SwiftUI

struct CaptureView: View {
    @StateObject private var camera = CameraService()
    @EnvironmentObject private var services: AppServices
    @State private var mode: Mode = .photo
    @State private var permissionDenied = false
    @Environment(\.scenePhase) private var scenePhase

    enum Mode: String, CaseIterable { case photo = "사진", shorts = "쇼츠" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
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
            } else {
                CameraPreviewView(session: camera.session, onTap: { camera.focus(at: $0) })
                    .ignoresSafeArea()
            }

            VStack {
                Picker("모드", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .padding(.top, 8)

                Spacer()

                if mode == .shorts {
                    Text("쇼츠 촬영 보조는 릴리즈 2에서 추가됩니다")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }

                ShutterButton(isVideo: mode == .shorts) {
                    if mode == .photo { camera.capturePhoto() }
                }
                .padding(.bottom, 24)
            }

            if let msg = camera.lastSavedMessage ?? camera.lastError {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(2))
                    camera.lastSavedMessage = nil
                    camera.lastError = nil
                }
            }
        }
        .task {
            // 앱 전역 저장·위치 서비스 주입(R1-S3). 촬영 저장은 PhotoSaver, GPS는 LocationProvider를 쓴다.
            camera.photoSaver = services.photoSaver
            camera.locationProvider = services.locationProvider
            let cam = await Permissions.requestCamera()
            _ = await Permissions.requestMicrophone()
            permissionDenied = !cam
            // 위치는 "앱 사용 중" 권한만 요청한다. 거부해도 위치 없이 촬영·저장된다(PLAN §3.4).
            services.locationProvider.start()
            guard cam else { return }
            camera.configureIfNeeded()
            camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: if !permissionDenied { camera.start() }
            case .background: camera.stop()
            default: break
            }
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
