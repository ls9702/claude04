// 카메라 세션·프레임 공급·렌즈(0.5×/1×/2×·전면) 전환·사진 촬영·사진 보관함 저장. 촬영 시 GPS를 메타데이터에 기록한다(PLAN §3.4).
import AVFoundation
import CoreLocation
import CoreMedia
import ImageIO
import os
import Photos
import UIKit

/// 카메라 오류. 사용자 문구는 `UserMessage.text(for:)`가 만든다.
enum CameraError: Error, LocalizedError, Equatable {
    /// 카메라 기기·입력을 열지 못함.
    case deviceUnavailable
    /// 이 기기에 요청한 카메라(전면 등)가 없음.
    case switchUnavailable
    /// 카메라 전환 중 입력 교체 실패.
    case switchFailed
    /// 프리뷰 출력을 붙이지 못함.
    case previewUnavailable
    /// 촬영 실패(AVFoundation 오류 래핑, 메시지만 비교).
    case captureFailed(Error?)
    /// 촬영 결과에 파일 데이터가 없음.
    case noCaptureData
    /// 세션 실행 중 오류(`runtimeErrorNotification`).
    case runtime
    /// 프리뷰 프레임이 오래 끊김(세션 재시작 후에도).
    case previewStalled

    var errorDescription: String? { UserMessage.text(for: self) }

    static func == (lhs: CameraError, rhs: CameraError) -> Bool {
        switch (lhs, rhs) {
        case (.deviceUnavailable, .deviceUnavailable), (.switchUnavailable, .switchUnavailable),
             (.switchFailed, .switchFailed), (.previewUnavailable, .previewUnavailable),
             (.noCaptureData, .noCaptureData), (.runtime, .runtime), (.previewStalled, .previewStalled):
            return true
        case (.captureFailed(let a), .captureFailed(let b)):
            return a?.localizedDescription == b?.localizedDescription
        default:
            return false
        }
    }
}

/// 카메라 세션 담당. 프리뷰 렌더는 모른다 — 프레임을 `frameHandler`로 넘길 뿐이다(R1-S4).
///
/// 큐 규칙:
/// - 세션 구성·시작/정지·카메라 전환·촬영 요청·포커스·줌: `sessionQueue`(직렬).
/// - 프리뷰 프레임 콜백: `videoQueue`(직렬, userInteractive). `frameHandler`는 이 큐에서 불린다.
/// - `@Published` 값: 메인에서만 바꾼다.
/// (영상 녹화는 R2-S2)
///
/// 포맷(R1-S8a): `.photo` 프리셋은 비디오 프레임을 12MP급으로 보내 라이브 프리뷰 비용이 컸다.
/// `.inputPriority`로 두고 활성 포맷을 직접 골라(4:3, 1920×1440 이하, 30fps) 프리뷰 프레임을 작게 받고,
/// 사진은 `photoOutput.maxPhotoDimensions`로 풀해상도를 유지한다. 고를 포맷이 없으면 `.photo` 프리셋으로 폴백.
///
/// 렌즈(R1-S8a): 후면은 가상 기기(트리플 → 듀얼 와이드 → 광각 순)를 써서 줌 배율에 따라 렌즈가 자동 전환된다.
/// 외부에는 "표시 배율"(0.5× = 초광각, 1× = 광각, 2× = 망원)만 보인다(`LensZoom` 환산).
/// 전면은 광각 하나. 프리뷰만 좌우 반전하고 사진은 반전하지 않는다(시스템 카메라 기본과 같다).
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tripshot.camera.session")
    private let videoQueue = DispatchQueue(label: "tripshot.camera.video", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    /// 사진 방향 결정용(기기를 가로로 들면 가로 사진). sessionQueue에서만 접근. 카메라 전환 시 다시 만든다.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// 현재 기기의 `virtualDeviceSwitchOverVideoZoomFactors`(표시 배율 환산용). sessionQueue에서만 접근.
    private var currentSwitchOvers: [CGFloat] = []
    /// 사용자가 세션 실행을 원하는지(start/stop). 중단·런타임 오류 뒤 자동 재개 판단용. sessionQueue에서만 접근.
    private var wantsRunning = false
    /// 런타임 오류 자동 재시작을 이미 한 번 시도했는지(연속 재시작 방지). sessionQueue에서만 접근.
    private var runtimeRestartTried = false
    private var sessionObservers: [NSObjectProtocol] = []
    /// 사진 연결 회전 폴백 값(세로).
    private static let portraitRotationAngle: CGFloat = 90

    private static let log = Logger(subsystem: "com.ls9702.tripshot", category: "camera")

    // MARK: 잠금 보호 상태 (여러 큐에서 접근)

    private let handlerLock = NSLock()
    private var _frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    private var _postCaptureHandler: ((String, Int) -> Void)?
    private var _frameOrientation: CGImagePropertyOrientation = .up
    private var _isPreviewMirrored = false
    private var _preferredFrameRate: Double = 30
    private var _droppedFrames = 0
    private var loggedFirstFrame = false   // videoQueue 전용

    /// 프리뷰 프레임 콜백. **videoQueue에서** 불린다. 어느 스레드에서 설정해도 된다.
    /// 콜백 안에서 메인 액터 객체를 만지지 않는다(필요한 값은 미리 복사해 둔다). 카메라 전환 중에도 그대로 유효하다.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)? {
        get { handlerLock.withLock { _frameHandler } }
        set { handlerLock.withLock { _frameHandler = newValue } }
    }

    /// 촬영 원본이 사진 보관함에 저장된 뒤 (새 에셋 localIdentifier, `capturePhoto(tag:)`의 tag)로 불린다.
    /// 메인이 아닌 스레드에서 불릴 수 있다. 보정 후처리는 이 콜백을 받은 쪽(CaptureViewModel)이 한다.
    var postCaptureHandler: ((String, Int) -> Void)? {
        get { handlerLock.withLock { _postCaptureHandler } }
        set { handlerLock.withLock { _postCaptureHandler = newValue } }
    }

    /// 프레임을 세로로 세우기 위해 소비 측이 적용할 방향. 연결이 90° 회전을 지원하면 `.up`(이미 세로),
    /// 지원하지 않으면 `.right`(CIImage.oriented로 시계 방향 90°). 세션 구성·카메라 전환 후 확정된다.
    var frameOrientation: CGImagePropertyOrientation {
        handlerLock.withLock { _frameOrientation }
    }

    /// 프리뷰 프레임이 좌우 반전돼 오는지(전면 카메라). 아무 스레드에서 읽어도 된다.
    /// 메인 UI는 `isFrontCamera`(@Published)를 쓴다.
    var isPreviewMirrored: Bool {
        handlerLock.withLock { _isPreviewMirrored }
    }

    /// 프리뷰·영상 프레임 레이트(기본 30, 발열 완화용으로 24 선택 가능 — 설정 탭 `AppServices.preferredFrameRate`,
    /// 저전력 모드면 자동 24 — `CaptureViewModel.applyFrameRate()`).
    /// 어느 스레드에서 바꿔도 되며, 세션이 구성돼 있으면 세션 큐에서 바로 적용한다.
    var preferredFrameRate: Double {
        get { handlerLock.withLock { _preferredFrameRate } }
        set {
            let fps = min(max(newValue, 15), 30)
            handlerLock.withLock { _preferredFrameRate = fps }
            sessionQueue.async { [self] in
                guard configured, let device = videoInput?.device,
                      (try? device.lockForConfiguration()) != nil else { return }
                applyFrameRate(fps, to: device)
                device.unlockForConfiguration()
            }
        }
    }

    /// 지난 호출 이후 AVFoundation이 버린 프레임 수(측정용, 호출 시 0으로 초기화).
    func takeDroppedFrameCount() -> Int {
        handlerLock.withLock {
            defer { _droppedFrames = 0 }
            return _droppedFrames
        }
    }

    @Published var isRunning = false
    @Published var lastError: String?
    /// 세션이 중단된 동안(전화·다른 앱의 카메라 점유·화면 분할·발열) 프리뷰 위에 보일 안내. 중단이 끝나면 nil.
    @Published private(set) var interruptionMessage: String?
    @Published var lastSavedMessage: String?
    /// 마지막으로 저장한 촬영 에셋의 localIdentifier. 보정본을 같은 에셋에 얹는 것은 R1-S4에서 이 값을 쓴다.
    @Published var lastCapturedAssetID: String?
    /// 현재 표시 배율(0.5× = 초광각, 1× = 광각). `videoZoomFactor`가 아니라 사용자에게 보이는 값이다.
    @Published private(set) var zoomFactor: CGFloat = 1
    /// 이 기기·카메라에서 보일 렌즈 버튼(표시 배율). 전면·단일 렌즈 기기는 [1].
    @Published private(set) var availableDisplayFactors: [CGFloat] = [1]
    /// 전면 카메라 사용 중(프리뷰 좌우 반전).
    @Published private(set) var isFrontCamera = false

    /// 촬영 위치 제공자(선택). 없거나 위치가 없으면 GPS 없이 저장한다.
    var locationProvider: LocationProvider?
    /// 사진 보관함 저장 담당(선택). 없으면 기존 방식(PHAssetCreationRequest 직접)으로 저장한다.
    var photoSaver: PhotoSaver?
    /// 촬영 요청 시점의 위치. uniqueID별로 보관했다가 저장 시 에셋 location으로도 넣는다. sessionQueue에서만 접근.
    private var pendingLocations: [Int64: CLLocation] = [:]
    /// 촬영 요청 tag. uniqueID별로 보관했다가 `postCaptureHandler`에 넘긴다. sessionQueue에서만 접근.
    private var pendingTags: [Int64: Int] = [:]

    // MARK: 초기화·중단 처리

    override init() {
        super.init()
        observeSession()
    }

    deinit {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// 세션 중단·런타임 오류 알림 구독. 알림은 임의 스레드에서 오므로 상태는 세션 큐·메인으로 옮겨 바꾼다.
    /// - 중단(전화·다른 앱 카메라 점유 등): 프리뷰가 멈춘다 → 안내 표시.
    /// - 중단 끝: 안내를 지우고, 실행을 원하는 상태인데 멈춰 있으면 `startRunning()`으로 재개.
    /// - 런타임 오류: 미디어 서비스 재설정 등. 한 번만 자동 재시작하고 안내한다.
    private func observeSession() {
        let center = NotificationCenter.default
        // 시그니처: AVCaptureSession.wasInterruptedNotification / interruptionEndedNotification / runtimeErrorNotification
        //          userInfo[AVCaptureSessionInterruptionReasonKey]: NSNumber(InterruptionReason.rawValue)
        //          userInfo[AVCaptureSessionErrorKey]: AVError
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                   object: session, queue: nil) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            // 백그라운드 전환 중단은 정상 흐름(pause가 이미 멈춤)이라 안내하지 않는다.
            guard reason != .videoDeviceNotAvailableInBackground else { return }
            let message = UserMessage.cameraInterruption(reason)
            Self.log.notice("세션 중단: \(message, privacy: .public)")
            DispatchQueue.main.async { self?.interruptionMessage = message }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                   object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            Self.log.notice("세션 중단 끝")
            DispatchQueue.main.async { self.interruptionMessage = nil }
            self.sessionQueue.async {
                guard self.wantsRunning, !self.session.isRunning else { return }
                self.session.startRunning()
                let running = self.session.isRunning
                DispatchQueue.main.async { self.isRunning = running }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                   object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Self.log.error("세션 런타임 오류: \(error?.localizedDescription ?? "-", privacy: .public)")
            self.sessionQueue.async {
                guard self.wantsRunning else { return }
                // 미디어 서비스 재설정은 매번 재시작, 그 밖의 오류는 한 번만 시도한다(무한 재시작 방지).
                let isReset = error?.code == .mediaServicesWereReset
                guard isReset || !self.runtimeRestartTried else {
                    DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.runtime) }
                    return
                }
                self.runtimeRestartTried = true
                DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.runtime) }
                self.session.startRunning()
                let running = self.session.isRunning
                DispatchQueue.main.async { self.isRunning = running }
            }
        })
    }

    // MARK: 세션 구성

    func configureIfNeeded() {
        sessionQueue.async { [self] in
            guard !configured else { return }
            session.beginConfiguration()
            // 활성 포맷을 직접 고른다(아래 configureFormat). 고르지 못하면 거기서 .photo로 폴백.
            if session.canSetSessionPreset(.inputPriority) {
                session.sessionPreset = .inputPriority
            } else {
                session.sessionPreset = .photo
            }

            guard let device = Self.makeDevice(for: .back), installInput(device: device) else {
                DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.deviceUnavailable) }
                session.commitConfiguration()
                return
            }

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
            }

            // 라이브 프리뷰 프레임. 처리가 늦으면 AVFoundation이 늦은 프레임을 버린다(1차 백프레셔).
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            } else {
                DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.previewUnavailable) }
            }

            configureFormat(for: device)
            configureConnections(for: device)

            session.commitConfiguration()
            finishDeviceSetup(device)
            configured = true
        }
    }

    /// 카메라 전환(후면 ↔ 전면). 세션 큐에서 입력을 바꾸고 포맷·연결·회전 코디네이터를 다시 구성한다.
    /// 세션은 멈추지 않는다(전환 중 프레임이 잠시 끊길 수 있다). `frameHandler`는 그대로 유효하다.
    func switchCamera(to position: AVCaptureDevice.Position) {
        sessionQueue.async { [self] in
            guard configured, videoInput?.device.position != position else { return }
            guard let device = Self.makeDevice(for: position) else {
                DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.switchUnavailable) }
                return
            }
            session.beginConfiguration()
            guard installInput(device: device) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.switchFailed) }
                return
            }
            configureFormat(for: device)
            configureConnections(for: device)
            session.commitConfiguration()
            finishDeviceSetup(device)
            // 새 카메라의 첫 프레임 크기도 기록한다(videoQueue 전용 상태이므로 그 큐에서 바꾼다).
            videoQueue.async { self.loggedFirstFrame = false }
        }
    }

    /// 후면: 트리플 → 듀얼 와이드(초광각+광각) → 광각. 전면: 광각.
    /// 가상 기기를 쓰면 `videoZoomFactor`에 따라 렌즈가 자동 전환된다(`virtualDeviceSwitchOverVideoZoomFactors`).
    private static func makeDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        return AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// 세션 큐, 구성 트랜잭션 안에서. 기존 입력을 새 기기 입력으로 바꾼다. 실패하면 기존 입력을 되돌리고 false.
    private func installInput(device: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let old = videoInput
        if let old { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let old, session.canAddInput(old) { session.addInput(old) }
            return false
        }
        session.addInput(input)
        videoInput = input
        return true
    }

    /// 세션 큐, 구성 트랜잭션 안에서. 활성 포맷을 고르고(`CameraFormatPicker`), 없으면 `.photo` 프리셋으로 폴백.
    private func configureFormat(for device: AVCaptureDevice) {
        let formats = device.formats
        let infos = formats.map(Self.formatInfo)
        // 30fps 기준으로 고른다(24fps 선택 시에도 30fps 포맷은 24를 지원한다). 사진 풀해상도를 잃는 포맷은 제외.
        if let index = CameraFormatPicker.pick(formats: infos, frameRate: 30, requireFullPhoto: true),
           (try? device.lockForConfiguration()) != nil {
            // activeFormat을 설정하면 세션 프리셋은 자동으로 .inputPriority가 된다.
            device.activeFormat = formats[index]
            device.unlockForConfiguration()
            let info = infos[index]
            let photo = CameraFormatPicker.largestPhotoDimensions(info.maxPhotoDimensions) ?? PixelSize(width: 0, height: 0)
            let summary = "\(info.width)x\(info.height) 최대 \(Int(info.maxFrameRate))fps, 사진 \(photo.width)x\(photo.height), binned=\(info.isBinned)"
            Self.log.notice("활성 포맷 \(summary, privacy: .public)")
        } else {
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            Self.log.notice("조건에 맞는 활성 포맷이 없어 .photo 프리셋으로 폴백")
        }
    }

    /// `AVCaptureDevice.Format` → 선택용 값.
    private static func formatInfo(_ format: AVCaptureDevice.Format) -> FormatInfo {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        // 시그니처(iOS 16+): AVCaptureDevice.Format.supportedMaxPhotoDimensions: [CMVideoDimensions]
        let photo = format.supportedMaxPhotoDimensions.map { PixelSize(width: Int($0.width), height: Int($0.height)) }
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return FormatInfo(width: Int(dims.width), height: Int(dims.height),
                          maxFrameRate: maxRate,
                          maxPhotoDimensions: photo,
                          isBinned: format.isVideoBinned,
                          isFullRange: subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    /// 세션 큐, 구성 트랜잭션 안에서(입력을 붙인 뒤 — 연결은 입력·출력이 모두 있어야 생긴다).
    private func configureConnections(for device: AVCaptureDevice) {
        let front = device.position == .front
        configureVideoConnection(mirrored: front)
        // 사진은 반전하지 않는다(시스템 카메라 기본 "전면 카메라 미러링 끔"과 같다).
        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        // 사진 방향: 앱 UI는 세로 고정이지만 사진은 기기를 든 방향을 따른다.
        // 시그니처(iOS 17+): AVCaptureDevice.RotationCoordinator.init(device: AVCaptureDevice, previewLayer: CALayer?)
        //                    var videoRotationAngleForHorizonLevelCapture: CGFloat { get }
        // TODO(검증): previewLayer 없이(nil) 만들어도 캡처 각도가 기기 방향을 따르는지 실기기에서 확인(전면 포함).
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    }

    /// 프리뷰 프레임 연결 설정(세션 큐, 구성 트랜잭션 안에서).
    /// - 회전: 앱은 세로 고정이므로 프레임을 항상 세로(90°)로 받는다. 지원 안 하면 소비 측이 `.right`로 돌린다.
    /// - 미러: 전면 카메라만 프리뷰를 좌우 반전한다(거울처럼 보이게). 탭 좌표는 `MetalPreviewView.devicePoint(mirrored:)`가 되돌린다.
    private func configureVideoConnection(mirrored: Bool) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        // 시그니처(iOS 17+): AVCaptureConnection.isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool
        //                    AVCaptureConnection.videoRotationAngle: CGFloat
        let orientation: CGImagePropertyOrientation
        if connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
            connection.videoRotationAngle = Self.portraitRotationAngle
            orientation = .up
        } else {
            // TODO(검증): 회전 미지원 + 전면(미러) 조합에서 `.right`가 맞는지. 실기기에서는 회전 지원이라 이 분기는 드물다.
            orientation = .right
            Self.log.notice("비디오 연결이 90° 회전을 지원하지 않아 CIImage 회전으로 대체")
        }
        var appliedMirror = false
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
            appliedMirror = mirrored
        }
        handlerLock.withLock {
            _frameOrientation = orientation
            _isPreviewMirrored = appliedMirror
        }
    }

    /// 세션 큐, 구성 커밋 뒤. 사진 최대 크기·프레임 레이트·시작 배율(1×)을 맞추고 화면 상태를 알린다.
    private func finishDeviceSetup(_ device: AVCaptureDevice) {
        // 사진은 활성 포맷이 허용하는 가장 큰 크기(12 Pro: 4032×3024)로. 값은 반드시 이 목록 안의 것이어야 한다.
        // 시그니처(iOS 16+): AVCapturePhotoOutput.maxPhotoDimensions: CMVideoDimensions
        let photoDims = device.activeFormat.supportedMaxPhotoDimensions
        if let best = photoDims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = best
            Self.log.notice("사진 최대 크기 \(Int(best.width))x\(Int(best.height))")
        }

        // 시그니처: AVCaptureDevice.virtualDeviceSwitchOverVideoZoomFactors: [NSNumber] (가상 기기가 아니면 빈 배열)
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        currentSwitchOvers = switchOvers

        var display: CGFloat = 1
        if (try? device.lockForConfiguration()) != nil {
            applyFrameRate(preferredFrameRate, to: device)
            // 가상 트리플/듀얼 와이드의 videoZoomFactor 1.0은 초광각이다. 시작은 광각(1×)으로 맞춘다.
            let wide = LensZoom.wideZoomFactor(switchOvers: switchOvers)
            let clamped = min(max(wide, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clamped
            display = LensZoom.displayFactor(videoZoom: clamped, switchOvers: switchOvers)
            device.unlockForConfiguration()
        }

        let factors = LensZoom.availableDisplayFactors(switchOvers: switchOvers)
        let front = device.position == .front
        let description = "\(device.localizedName) 전환 계수 \(switchOvers.map { Double($0) }) 렌즈 버튼 \(factors.map { Double($0) })"
        Self.log.notice("카메라 \(description, privacy: .public)")
        DispatchQueue.main.async {
            self.zoomFactor = display
            self.availableDisplayFactors = factors
            self.isFrontCamera = front
        }
    }

    /// 프레임 레이트 상한(최소 프레임 간격 = 1/fps). 최대 간격은 1/15까지 허용해 어두운 곳에서 자동 노출이
    /// 프레임 레이트를 낮춰 노출 시간을 늘릴 수 있게 한다(리뷰 수정: 최대 간격까지 1/fps로 묶으면 야간 프리뷰가 어둡고 노이즈가 커진다).
    /// 호출 측이 `lockForConfiguration`을 잡고 부른다. 활성 포맷이 그 fps를 지원하지 않으면 바꾸지 않는다.
    private func applyFrameRate(_ fps: Double, to device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let supported = ranges.contains { $0.minFrameRate <= fps + 0.01 && fps <= $0.maxFrameRate + 0.01 }
        guard supported else {
            Self.log.notice("활성 포맷이 \(fps)fps를 지원하지 않아 프레임 레이트를 그대로 둠")
            return
        }
        let minDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        // 어두운 곳의 자동 저하 하한: 포맷이 허용하는 최저 fps와 15 중 큰 값.
        let lowestSupported = ranges.map(\.minFrameRate).min() ?? fps
        let floorFps = min(fps, max(15, lowestSupported))
        let maxDuration = CMTime(value: 1, timescale: CMTimeScale(floorFps.rounded()))
        device.activeVideoMinFrameDuration = minDuration
        device.activeVideoMaxFrameDuration = maxDuration
    }

    func start() {
        sessionQueue.async { [self] in
            wantsRunning = true
            runtimeRestartTried = false
            guard configured, !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            guard session.isRunning else { return }
            session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.interruptionMessage = nil
            }
        }
    }

    /// 프리뷰가 오래 멈췄을 때(20분 연속 사용 대비) 세션을 멈췄다가 다시 시작한다. 실행을 원하는 상태일 때만.
    func restartSession() {
        sessionQueue.async { [self] in
            guard configured, wantsRunning else { return }
            Self.log.notice("프리뷰 멈춤 → 세션 재시작")
            if session.isRunning { session.stopRunning() }
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    /// 메인 스레드(UI)에서 호출한다. 위치는 호출 시점에 메인에서 읽어 세션 큐로 넘긴다.
    /// - Parameter tag: 호출 측이 이 촬영을 식별하는 값. 저장 후 `postCaptureHandler`에 그대로 돌려준다
    ///   (셔터를 누른 순간의 보정 설정을 찾는 데 쓴다. 저장 완료 순서가 촬영 순서와 다를 수 있어 순서에 의존하지 않는다).
    func capturePhoto(tag: Int = 0) {
        let location = locationProvider?.last
        sessionQueue.async { [self] in
            guard configured else { return }
            // 사진 방향을 기기 방향에 맞춘다(파일은 재인코딩 없이 방향 태그로 기록된다).
            if let connection = photoOutput.connection(with: .video) {
                let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? Self.portraitRotationAngle
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality
            // 활성 포맷을 작은 비디오 포맷으로 골랐으므로, 사진 크기는 출력의 최대값을 명시해 풀해상도를 요청한다.
            // 시그니처(iOS 16+): AVCapturePhotoSettings.maxPhotoDimensions: CMVideoDimensions
            // TODO(검증): 실기기 로그 "촬영 사진 크기"가 4032x3024인지 확인.
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            if let location {
                // GPS는 촬영 시점에 파일 EXIF로 기록한다(재인코딩 없이). 기존 metadata와 병합.
                var metadata = settings.metadata
                metadata[kCGImagePropertyGPSDictionary as String] =
                    ImageMetadata.stringKeyed(ImageMetadata.gpsDictionary(from: location))
                settings.metadata = metadata
                pendingLocations[settings.uniqueID] = location
            }
            pendingTags[settings.uniqueID] = tag
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint; device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = devicePoint; device.exposureMode = .autoExpose }
        }
    }

    /// 줌(핀치·렌즈 버튼). **표시 배율**로 받는다(0.5× = 초광각). 램프 없이 즉시 바꾼다.
    /// 범위: 표시 0.5~10 ∩ 기기 `minAvailableVideoZoomFactor … activeFormat.videoMaxZoomFactor`.
    /// 적용된 표시 배율은 `zoomFactor`(@Published)에도 반영된다.
    /// - Parameter completion: 실제 적용된 표시 배율. **메인에서** 불린다.
    func setZoom(displayFactor: CGFloat, completion: ((CGFloat) -> Void)? = nil) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device else { return }
            let switchOvers = currentSwitchOvers
            let requested = LensZoom.videoZoom(forDisplay: displayFactor, switchOvers: switchOvers)
            let upper = min(device.activeFormat.videoMaxZoomFactor,
                            LensZoom.videoZoom(forDisplay: LensZoom.maxDisplayFactor, switchOvers: switchOvers))
            let lower = max(device.minAvailableVideoZoomFactor,
                            LensZoom.videoZoom(forDisplay: LensZoom.minDisplayFactor, switchOvers: switchOvers))
            let clamped = min(max(requested, lower), max(lower, upper))
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            let display = LensZoom.displayFactor(videoZoom: clamped, switchOvers: switchOvers)
            DispatchQueue.main.async {
                self.zoomFactor = display
                completion?(display)
            }
        }
    }
}

// MARK: - 프리뷰 프레임

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// videoQueue. 처리 시간이 길면 다음 프레임이 버려진다(alwaysDiscardsLateVideoFrames).
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !loggedFirstFrame {
            loggedFirstFrame = true
            // 실기기 체크포인트: 활성 포맷 선택 후 프레임 크기 기록(12 Pro 기대: 1440x1920 세로). 카메라 전환 때마다 다시 찍는다.
            Self.log.notice("프리뷰 프레임 크기 \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameHandler?(pixelBuffer, time)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handlerLock.withLock { _droppedFrames += 1 }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.captureFailed(error)) }
            return
        }
        // 이 콜백은 세션 큐가 아닌 스레드에서 올 수 있으므로 pendingLocations는 세션 큐에서 꺼낸다.
        let uniqueID = photo.resolvedSettings.uniqueID
        // 실기기 체크포인트: 사진이 풀해상도(12 Pro 4032x3024)로 찍히는지(활성 포맷을 작은 비디오 포맷으로 골랐으므로).
        let dims = photo.resolvedSettings.photoDimensions
        Self.log.notice("촬영 사진 크기 \(Int(dims.width))x\(Int(dims.height))")
        let data = photo.fileDataRepresentation()
        sessionQueue.async { [self] in
            let location = pendingLocations.removeValue(forKey: uniqueID)
            let tag = pendingTags.removeValue(forKey: uniqueID) ?? 0
            guard let data else {
                DispatchQueue.main.async { self.lastError = UserMessage.text(for: CameraError.noCaptureData) }
                return
            }
            save(data: data, location: location, tag: tag)
        }
    }

    /// 촬영 실패로 사진 콜백이 오지 않는 경우에도 보관한 위치·tag를 정리한다.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error != nil else { return }
        let uniqueID = resolvedSettings.uniqueID
        sessionQueue.async { [self] in
            pendingLocations.removeValue(forKey: uniqueID)
            pendingTags.removeValue(forKey: uniqueID)
        }
    }

    /// 촬영 데이터를 그대로(재인코딩 없이) 새 에셋으로 저장한다. 기존 에셋은 건드리지 않는다.
    private func save(data: Data, location: CLLocation?, tag: Int) {
        let saver = photoSaver
        let handler = postCaptureHandler
        Task {
            if let saver {
                do {
                    let id = try await saver.saveCapturedPhoto(data: data, location: location)
                    await MainActor.run {
                        self.lastCapturedAssetID = id
                        self.lastSavedMessage = "사진 앱에 저장했습니다."
                    }
                    // 원본 저장이 끝난 뒤 보정 후처리를 요청한다(같은 에셋에 비파괴로 얹음).
                    handler?(id, tag)
                } catch {
                    let message = UserMessage.text(for: error)
                    await MainActor.run { self.lastError = "원본 저장 실패: \(message)" }
                }
                return
            }

            // PhotoSaver가 주입되지 않은 경우의 기존 저장 방식.
            guard await Permissions.requestPhotoLibrary() else {
                await MainActor.run { self.lastError = UserMessage.photoPermission }
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: data, options: nil)
                    if let location { req.location = location }
                }
                await MainActor.run { self.lastSavedMessage = "사진 앱에 저장했습니다." }
            } catch {
                await MainActor.run { self.lastError = "원본 저장 실패: \(UserMessage.text(for: error))" }
            }
        }
    }
}
