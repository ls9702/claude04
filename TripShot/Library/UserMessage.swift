// 사용자에게 보이는 오류 문구를 한 곳에서 만든다(원인 + 조치, 한국어). 저장·보정·카메라·백업 오류 공통.
import AVFoundation
import Foundation

/// 오류 → 사용자 문구. 화면·ViewModel은 `error.localizedDescription` 대신 이것을 쓴다.
/// `PhotoSaveError`·`EnhanceSaveError`·`CameraError`·`BackupError`의 `errorDescription`도 여기로 위임한다.
/// 모르는 오류는 `LocalizedError.errorDescription` → `localizedDescription` 순으로 그대로 쓴다.
enum UserMessage {
    /// 사진 보관함 권한 안내(여러 곳에서 같은 문구).
    static let photoPermission = "사진 보관함 권한이 없습니다. 설정 > TripShot > 사진에서 허용해 주세요."

    static func text(for error: Error) -> String {
        switch error {
        case let e as PhotoSaveError:
            return photoSave(e)
        case let e as EnhanceSaveError:
            switch e {
            case .assetUnavailable:
                return "사진을 찾을 수 없습니다. 사진 앱에서 삭제됐거나 접근이 제한된 사진입니다."
            case .saverUnavailable:
                return "저장 기능을 사용할 수 없습니다. 앱을 다시 실행해 주세요."
            }
        case let e as CameraError:
            return camera(e)
        case let e as BackupError:
            switch e {
            case .unsupportedVersion(let v):
                return "이 백업 파일(버전 \(v))은 지금 앱보다 새 버전에서 만든 것입니다. 앱을 업데이트한 뒤 가져와 주세요."
            case .unreadable:
                return "백업 파일을 읽지 못했습니다. 파일 앱에서 파일이 기기에 내려받아졌는지 확인해 주세요."
            case .invalidFormat:
                return "TripShot 백업 파일이 아니거나 손상된 파일입니다."
            }
        case is DecodingError:
            return "TripShot 백업 파일이 아니거나 손상된 파일입니다."
        default:
            if let localized = error as? LocalizedError, let text = localized.errorDescription {
                return text
            }
            return error.localizedDescription
        }
    }

    private static func photoSave(_ e: PhotoSaveError) -> String {
        switch e {
        case .notAuthorized:
            return photoPermission
        case .inputUnavailable:
            return "원본 사진을 불러오지 못했습니다. iCloud 사진이면 네트워크 연결을 확인하고 다시 시도해 주세요."
        case .renderFailed:
            return "보정 이미지를 만들지 못했습니다. 다른 앱을 닫고 다시 시도해 주세요."
        case .encodingFailed:
            return "이미지 인코딩에 실패했습니다. 다시 시도해 주세요."
        case .writeFailed:
            return "보정 결과를 기록하지 못했습니다. 저장 공간을 확인해 주세요."
        case .library(let error):
            return "사진 보관함에 저장하지 못했습니다(\(error.localizedDescription)). 저장 공간과 권한을 확인해 주세요."
        }
    }

    private static func camera(_ e: CameraError) -> String {
        switch e {
        case .deviceUnavailable:
            return "카메라를 열 수 없습니다. 다른 앱이 카메라를 쓰고 있으면 닫고 다시 시도해 주세요."
        case .switchUnavailable:
            return "이 기기에서 해당 카메라를 쓸 수 없습니다."
        case .switchFailed:
            return "카메라를 전환하지 못했습니다. 잠시 후 다시 시도해 주세요."
        case .previewUnavailable:
            return "프리뷰를 시작할 수 없습니다. 앱을 다시 실행해 주세요."
        case .captureFailed(let error):
            let reason = error.map { "(\($0.localizedDescription))" } ?? ""
            return "촬영하지 못했습니다\(reason). 다시 눌러 주세요."
        case .noCaptureData:
            return "촬영 데이터를 읽지 못했습니다. 다시 촬영해 주세요."
        case .runtime:
            return "카메라 오류로 프리뷰가 멈췄습니다. 다시 시작을 시도합니다. 계속 멈춰 있으면 다른 탭에 갔다 오거나 앱을 다시 실행해 주세요."
        case .previewStalled:
            return "프리뷰가 1분 넘게 멈췄습니다. 앱을 완전히 닫고 다시 실행해 주세요."
        }
    }

    // MARK: 카메라 중단

    /// 세션 중단 이유 → 프리뷰 위 안내. 중단이 끝나면 자동으로 재개된다.
    static func cameraInterruption(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceInUseByAnotherClient?:
            return "다른 앱이 카메라를 쓰고 있어 프리뷰를 멈췄습니다. 그 앱을 닫으면 다시 시작합니다."
        case .audioDeviceInUseByAnotherClient?:
            return "통화 등으로 마이크가 사용 중이라 카메라를 멈췄습니다. 끝나면 다시 시작합니다."
        case .videoDeviceNotAvailableWithMultipleForegroundApps?:
            return "화면 분할 중에는 카메라를 쓸 수 없습니다. 전체 화면으로 돌아오면 다시 시작합니다."
        case .videoDeviceNotAvailableDueToSystemPressure?:
            return "기기가 너무 뜨거워 카메라를 멈췄습니다. 잠시 식힌 뒤 다시 시작합니다."
        default:
            return "카메라가 잠시 멈췄습니다. 끝나면 다시 시작합니다."
        }
    }

    // MARK: 촬영 후처리

    /// 연속 몇 번 실패하면 원인 안내를 덧붙이는지.
    static let postProcessHintThreshold = 3

    /// 촬영 후처리(보정 저장) 실패 문구. 원본은 이미 저장돼 있음을 항상 알린다.
    /// 연속 실패가 `postProcessHintThreshold` 이상이면 인물 모드·저조도 단계가 원인일 수 있음을 안내한다.
    static func postProcessFailure(reason: String, consecutiveFailures: Int) -> String {
        let base = "보정 저장 실패(원본은 저장됨): \(reason)"
        guard consecutiveFailures >= postProcessHintThreshold else { return base }
        return base + "\n\(consecutiveFailures)회 연속 실패 — 인물 모드나 저조도(야경) 보정이 원인일 수 있습니다. 인물 모드를 끄거나 다른 프리셋으로 찍어 보세요."
    }
}
