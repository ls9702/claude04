// 카메라 세션·프레임 공급·사진 촬영·사진 보관함 저장. 촬영 시 GPS를 메타데이터에 기록한다(PLAN §3.4).
import AVFoundation
import CoreLocation
import CoreMedia
import ImageIO
import os
import Photos
import UIKit

/// 카메라 세션 담당. 프리뷰 렌더는 모른다 — 프레임을 `frameHandler`로 넘길 뿐이다(R1-S4).
///
/// 큐 규칙:
/// - 세션 구성·시작/정지·촬영 요청·포커스·줌: `sessionQueue`(직렬).
/// - 프리뷰 프레임 콜백: `videoQueue`(직렬, userInteractive). `frameHandler`는 이 큐에서 불린다.
/// - `@Published` 값: 메인에서만 바꾼다.
/// (영상 녹화는 R2-S2)
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tripshot.camera.session")
    private let videoQueue = DispatchQueue(label: "tripshot.camera.video", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    /// 사진 방향 결정용(기기를 가로로 들면 가로 사진). sessionQueue에서만 접근.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// 사진 연결 회전 폴백 값(세로).
    private static let portraitRotationAngle: CGFloat = 90
    /// 줌 상한(디지털 줌을 과하게 쓰지 않도록).
    static let maxZoomFactor: CGFloat = 10

    private static let log = Logger(subsystem: "com.ls9702.tripshot", category: "camera")

    // MARK: 잠금 보호 상태 (여러 큐에서 접근)

    private let handlerLock = NSLock()
    private var _frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    private var _postCaptureHandler: ((String, Int) -> Void)?
    private var _frameOrientation: CGImagePropertyOrientation = .up
    private var _droppedFrames = 0
    private var loggedFirstFrame = false   // videoQueue 전용

    /// 프리뷰 프레임 콜백. **videoQueue에서** 불린다. 어느 스레드에서 설정해도 된다.
    /// 콜백 안에서 메인 액터 객체를 만지지 않는다(필요한 값은 미리 복사해 둔다).
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
    /// 지원하지 않으면 `.right`(CIImage.oriented로 시계 방향 90°). 세션 구성 후 확정된다.
    var frameOrientation: CGImagePropertyOrientation {
        handlerLock.withLock { _frameOrientation }
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
    @Published var lastSavedMessage: String?
    /// 마지막으로 저장한 촬영 에셋의 localIdentifier. 보정본을 같은 에셋에 얹는 것은 R1-S4에서 이 값을 쓴다.
    @Published var lastCapturedAssetID: String?

    /// 촬영 위치 제공자(선택). 없거나 위치가 없으면 GPS 없이 저장한다.
    var locationProvider: LocationProvider?
    /// 사진 보관함 저장 담당(선택). 없으면 기존 방식(PHAssetCreationRequest 직접)으로 저장한다.
    var photoSaver: PhotoSaver?
    /// 촬영 요청 시점의 위치. uniqueID별로 보관했다가 저장 시 에셋 location으로도 넣는다. sessionQueue에서만 접근.
    private var pendingLocations: [Int64: CLLocation] = [:]
    /// 촬영 요청 tag. uniqueID별로 보관했다가 `postCaptureHandler`에 넘긴다. sessionQueue에서만 접근.
    private var pendingTags: [Int64: Int] = [:]

    func configureIfNeeded() {
        sessionQueue.async { [self] in
            guard !configured else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                DispatchQueue.main.async { self.lastError = "카메라를 열 수 없습니다." }
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            videoInput = input

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
                configureVideoConnection()
            } else {
                DispatchQueue.main.async { self.lastError = "프리뷰를 시작할 수 없습니다." }
            }

            // 사진 방향: 앱 UI는 세로 고정이지만 사진은 기기를 든 방향을 따른다.
            // 시그니처(iOS 17+): AVCaptureDevice.RotationCoordinator.init(device: AVCaptureDevice, previewLayer: CALayer?)
            //                    var videoRotationAngleForHorizonLevelCapture: CGFloat { get }
            // TODO(검증): previewLayer 없이(nil) 만들어도 캡처 각도가 기기 방향을 따르는지 실기기에서 확인.
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

            session.commitConfiguration()
            configured = true
        }
    }

    /// 프리뷰 프레임 연결 설정(세션 큐, 구성 트랜잭션 안에서).
    /// - 회전: 앱은 세로 고정이므로 프레임을 항상 세로(90°)로 받는다. 지원 안 하면 소비 측이 `.right`로 돌린다.
    /// - 미러: 후면 카메라만 쓰므로 미러링하지 않는다(전면 카메라 추가 시 `isVideoMirrored`와 탭 좌표 x 반전 필요).
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        // 시그니처(iOS 17+): AVCaptureConnection.isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool
        //                    AVCaptureConnection.videoRotationAngle: CGFloat
        let orientation: CGImagePropertyOrientation
        if connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
            connection.videoRotationAngle = Self.portraitRotationAngle
            orientation = .up
        } else {
            orientation = .right
            Self.log.notice("비디오 연결이 90° 회전을 지원하지 않아 CIImage 회전으로 대체")
        }
        handlerLock.withLock { _frameOrientation = orientation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func start() {
        sessionQueue.async { [self] in
            guard configured, !session.isRunning else { return }
            session.startRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
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

    /// 핀치 줌. `minAvailableVideoZoomFactor … min(activeFormat.videoMaxZoomFactor, 10)`로 자른다.
    /// - Parameter completion: 실제 적용된 배율. **메인에서** 불린다.
    func setZoom(factor: CGFloat, completion: ((CGFloat) -> Void)? = nil) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device else { return }
            let upper = min(device.activeFormat.videoMaxZoomFactor, Self.maxZoomFactor)
            let lower = device.minAvailableVideoZoomFactor
            let clamped = min(max(factor, lower), max(lower, upper))
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            if let completion {
                DispatchQueue.main.async { completion(clamped) }
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
            // 실기기 체크포인트: .photo 프리셋에서 프레임이 어떤 크기로 오는지 기록(프리뷰 비용 판단용).
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
            DispatchQueue.main.async { self.lastError = "촬영 실패: \(error.localizedDescription)" }
            return
        }
        // 이 콜백은 세션 큐가 아닌 스레드에서 올 수 있으므로 pendingLocations는 세션 큐에서 꺼낸다.
        let uniqueID = photo.resolvedSettings.uniqueID
        let data = photo.fileDataRepresentation()
        sessionQueue.async { [self] in
            let location = pendingLocations.removeValue(forKey: uniqueID)
            let tag = pendingTags.removeValue(forKey: uniqueID) ?? 0
            guard let data else {
                DispatchQueue.main.async { self.lastError = "촬영 데이터를 읽지 못했습니다." }
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
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run { self.lastError = "저장 실패: \(message)" }
                }
                return
            }

            // PhotoSaver가 주입되지 않은 경우의 기존 저장 방식.
            guard await Permissions.requestPhotoLibrary() else {
                await MainActor.run { self.lastError = "사진 보관함 권한이 없습니다." }
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
                await MainActor.run { self.lastError = "저장 실패: \(error.localizedDescription)" }
            }
        }
    }
}
