// 카메라 세션·사진 촬영·사진 보관함 저장. 촬영 시 GPS를 메타데이터에 기록한다(PLAN §3.4).
import AVFoundation
import CoreLocation
import ImageIO
import Photos
import UIKit

/// R1-S0: 프리뷰 + 사진 촬영 + 사진 앱 저장. (Metal 프리뷰·프리셋 적용은 R1-S4, 영상 녹화는 R2-S2)
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tripshot.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

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
            session.commitConfiguration()
            configured = true
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
    func capturePhoto() {
        let location = locationProvider?.last
        sessionQueue.async { [self] in
            guard configured else { return }
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
            guard let data else {
                DispatchQueue.main.async { self.lastError = "촬영 데이터를 읽지 못했습니다." }
                return
            }
            save(data: data, location: location)
        }
    }

    /// 촬영 데이터를 그대로(재인코딩 없이) 새 에셋으로 저장한다. 기존 에셋은 건드리지 않는다.
    private func save(data: Data, location: CLLocation?) {
        let saver = photoSaver
        Task {
            if let saver {
                do {
                    let id = try await saver.saveCapturedPhoto(data: data, location: location)
                    await MainActor.run {
                        self.lastCapturedAssetID = id
                        self.lastSavedMessage = "사진 앱에 저장했습니다."
                    }
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
