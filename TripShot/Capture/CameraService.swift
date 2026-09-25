import AVFoundation
import Photos
import UIKit

/// P0: 프리뷰 + 사진 촬영 + 사진 앱 저장. (Metal 프리뷰·프리셋 적용은 P5, 영상 녹화는 P1)
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tripshot.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    @Published var isRunning = false
    @Published var lastError: String?
    @Published var lastSavedMessage: String?

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

    func capturePhoto() {
        sessionQueue.async { [self] in
            guard configured else { return }
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality
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
        guard let data = photo.fileDataRepresentation() else { return }
        Task {
            guard await Permissions.requestPhotoLibrary() else {
                await MainActor.run { self.lastError = "사진 보관함 권한이 없습니다." }
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: data, options: nil)
                }
                await MainActor.run { self.lastSavedMessage = "사진 앱에 저장했습니다." }
            } catch {
                await MainActor.run { self.lastError = "저장 실패: \(error.localizedDescription)" }
            }
        }
    }
}
