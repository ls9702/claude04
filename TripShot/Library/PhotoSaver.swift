// 보정·촬영 결과를 사진 보관함에 저장한다: 비파괴 편집, 사본 저장, 촬영 원본 저장 (PLAN §3.4).
import CoreImage
import CoreLocation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// `PHAdjustmentData`에 넣는 편집 기록. 사진 앱이 원본을 보관하고, TripShot은 다음 편집 때 이 값을 보고
/// 원본에서 다시 렌더한다(보정이 누적되지 않음).
struct AdjustmentPayload: Codable, Equatable {
    var version: Int = 1
    var params: PresetParams
    var horizonAngle: Double?
}

/// 저장 오류. 어느 경우든 **원본 에셋은 바뀌지 않은 상태**다(사진 보관함 변경 전에 던지거나, 변경 트랜잭션 자체가 실패).
enum PhotoSaveError: Error, LocalizedError {
    /// 사진 보관함 권한 없음.
    case notAuthorized
    /// 편집 입력(원본 이미지 파일)을 얻지 못함. iCloud 다운로드 실패·동영상 에셋 등.
    case inputUnavailable(Error?)
    /// 보정 렌더 실패.
    case renderFailed
    /// HEIF/JPEG 인코딩 실패.
    case encodingFailed(Error)
    /// 렌더 결과 파일 쓰기 실패.
    case writeFailed(Error)
    /// 사진 보관함 변경 실패(PhotoKit 오류 래핑).
    case library(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "사진 보관함 권한이 없습니다."
        case .inputUnavailable: return "원본 사진을 불러오지 못했습니다."
        case .renderFailed: return "보정 이미지를 만들지 못했습니다."
        case .encodingFailed: return "이미지 인코딩에 실패했습니다."
        case .writeFailed: return "보정 결과를 기록하지 못했습니다."
        case .library(let error): return "사진 보관함 저장 실패: \(error.localizedDescription)"
        }
    }
}

/// 사진 보관함 저장 담당. 앱에 하나만 두고 `EnhanceRenderer`를 주입받는다.
///
/// 원본 보호 원칙:
/// - 원본 파일은 읽기만 한다(`PHContentEditingInput.fullSizeImageURL`). 쓰기는 PhotoKit이 준 새 URL에만 한다.
/// - 사진 보관함 변경(`performChanges`)은 모든 준비(렌더·인코딩·파일 쓰기)가 끝난 뒤 **마지막에 한 번**만 한다.
///   그 이전 단계에서 오류가 나면 보관함에는 아무 변화가 없다.
/// - 비파괴 편집은 사진 앱이 원본을 보관하므로 사진 앱의 "원본으로 되돌리기"로 언제든 복원된다.
final class PhotoSaver {
    /// `PHAdjustmentData.formatIdentifier`. 이 값이 같으면 이전 TripShot 편집으로 보고 원본에서 다시 렌더한다.
    static let adjustmentFormatIdentifier = "com.ls9702.tripshot.preset"
    static let adjustmentFormatVersion = "1"
    /// 손실 압축 품질(HEIF/JPEG 공통).
    static let compressionQuality: Double = 0.92

    let renderer: EnhanceRenderer

    init(renderer: EnhanceRenderer) {
        self.renderer = renderer
    }

    // MARK: 비파괴 편집

    /// 같은 에셋에 보정본을 비파괴 편집으로 얹는다. 촬영일·위치·EXIF는 에셋 그대로 유지되고,
    /// 렌더 출력 파일에도 원본 EXIF·GPS·TIFF를 복사해 넣는다.
    ///
    /// 원본 손상 경로 없음: 입력 요청·렌더·인코딩·파일 쓰기 중 어디서 실패해도 `performChanges` 전에 throw하므로
    /// 에셋은 변하지 않는다. `performChanges`가 실패해도 PhotoKit 트랜잭션이라 부분 적용되지 않는다.
    /// 성공 후에도 원본은 사진 앱이 보관하므로 "원본으로 되돌리기"가 가능하다.
    ///
    /// 무거운 렌더가 호출 스레드(협력 스레드 풀)에서 돌므로 메인 액터에서 부르지 말고 `Task`로 부른다.
    func saveNonDestructive(asset: PHAsset, params: PresetParams, horizonAngle: Double?) async throws {
        guard await Permissions.requestPhotoLibrary() else { throw PhotoSaveError.notAuthorized }

        let input = try await contentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)

        // 원본 포맷 유지. 출력이 그 포맷을 받지 못하면 JPEG로 내려간다.
        let wanted = ImageEncoder.format(ofUTI: input.uniformTypeIdentifier ?? "")
        let (outputURL, format) = try renderedContentDestination(for: output, wanted: wanted)

        let rendered = try renderAndEncode(input: input, params: params, horizonAngle: horizonAngle, format: format)

        do {
            try rendered.data.write(to: outputURL, options: .atomic)
        } catch {
            throw PhotoSaveError.writeFailed(error)
        }

        let payload = AdjustmentPayload(params: params, horizonAngle: horizonAngle)
        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(payload)
        } catch {
            throw PhotoSaveError.encodingFailed(error)
        }
        // PHAdjustmentData(formatIdentifier: String, formatVersion: String, data: Data)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: Self.adjustmentFormatIdentifier,
                                                 formatVersion: Self.adjustmentFormatVersion,
                                                 data: payloadData)

        // 여기까지 오기 전에는 보관함을 전혀 건드리지 않았다. 이 트랜잭션이 유일한 변경 지점.
        // 시그니처: PHPhotoLibrary.performChanges(_ changeBlock: @escaping () -> Void) async throws  (iOS 15+)
        // 시그니처: PHAssetChangeRequest.init(for asset: PHAsset)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.contentEditingOutput = output
            }
        } catch {
            throw PhotoSaveError.library(error)
        }
    }

    // MARK: 사본 저장

    /// 보정본을 새 에셋으로 저장하고 새 에셋의 localIdentifier를 반환한다. 원본 에셋·앨범은 건드리지 않는다.
    /// 파일에는 원본 EXIF·GPS·TIFF를 복사하고, 에셋의 `creationDate`·`location`은 원본 에셋 값으로 명시 설정한다
    /// (원본 에셋 값이 없으면 원본 파일 메타데이터에서 읽은 값).
    ///
    /// 원본 손상 경로 없음: 원본은 읽기만 하고, 보관함 변경은 새 에셋 생성 하나뿐이다.
    func saveAsCopy(asset: PHAsset, params: PresetParams, horizonAngle: Double?) async throws -> String {
        guard await Permissions.requestPhotoLibrary() else { throw PhotoSaveError.notAuthorized }

        let input = try await contentEditingInput(for: asset)
        let format = ImageEncoder.format(ofUTI: input.uniformTypeIdentifier ?? "")
        let rendered = try renderAndEncode(input: input, params: params, horizonAngle: horizonAngle, format: format)

        let creationDate = asset.creationDate ?? ImageMetadata.creationDate(from: rendered.sourceProperties)
        let location = asset.location ?? (rendered.sourceProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
            .flatMap { ImageMetadata.location(from: $0) }

        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = format.uti.identifier

        let created = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: rendered.data, options: options)
                request.creationDate = creationDate
                request.location = location
                created.value = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PhotoSaveError.library(error)
        }
        guard let identifier = created.value else {
            // 생성은 성공했으나 식별자를 못 얻은 경우(정상 흐름에서는 발생하지 않음).
            throw PhotoSaveError.library(CocoaError(.fileWriteUnknown))
        }
        return identifier
    }

    // MARK: 촬영 저장

    /// 촬영 결과(`AVCapturePhoto.fileDataRepresentation()`)를 **재인코딩 없이** 새 에셋으로 저장한다.
    /// 카메라 EXIF·촬영 시각은 데이터에 그대로 들어 있고, GPS는 촬영 시 `AVCapturePhotoSettings.metadata`로
    /// 이미 기록된다(CameraService). 여기서는 에셋 `location`만 추가로 설정한다.
    ///
    /// 원본 손상 경로 없음: 기존 에셋을 건드리지 않고 새 에셋 하나만 만든다. 데이터는 받은 바이트 그대로.
    func saveCapturedPhoto(data: Data, location: CLLocation?) async throws -> String {
        guard await Permissions.requestPhotoLibrary() else { throw PhotoSaveError.notAuthorized }

        let created = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                if let location { request.location = location }
                created.value = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PhotoSaveError.library(error)
        }
        guard let identifier = created.value else {
            throw PhotoSaveError.library(CocoaError(.fileWriteUnknown))
        }
        return identifier
    }

    // MARK: 내부 — 공통 렌더 경로

    private struct RenderedPhoto {
        let data: Data
        /// 원본(편집 입력) 파일의 전체 속성. 사본 저장 시 날짜·위치 대체값으로 쓴다.
        let sourceProperties: [CFString: Any]
    }

    /// 편집 입력을 읽어 보정 렌더 → 메타데이터 복사 → 인코딩. 메모리 안에서만 동작(보관함·원본 파일 불변).
    private func renderAndEncode(input: PHContentEditingInput,
                                 params: PresetParams,
                                 horizonAngle: Double?,
                                 format: ImageEncoder.Format) throws -> RenderedPhoto {
        guard let url = input.fullSizeImageURL else { throw PhotoSaveError.inputUnavailable(nil) }
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: url)   // 읽기 전용
        } catch {
            throw PhotoSaveError.inputUnavailable(error)
        }
        let sourceProperties = ImageMetadata.properties(of: sourceData) ?? [:]

        guard let ciImage = CIImage(data: sourceData) else { throw PhotoSaveError.inputUnavailable(nil) }
        // 방향을 픽셀에 반영해 똑바로 세운다. 렌더 결과는 항상 .up(Orientation 1)으로 기록한다.
        let upright = ciImage.oriented(forExifOrientation: input.fullSizeImageOrientation)

        // HEIF는 10비트 원본의 계조를 지키려고 16비트로 렌더한다. JPEG는 8비트면 충분.
        // TODO(검증): 16비트 CGImage를 HEIC로 넘기면 ImageIO가 10비트 HEIC로 쓰는지 실기기에서 확인(8비트로 쓰면 계조 이득 없음).
        let pixelFormat: CIFormat = format == .heif ? .RGBA16 : .RGBA8
        guard let cgImage = renderer.renderFullResolution(
            ciImage: upright,
            params: params,
            outputColorSpace: EnhanceRenderer.colorSpace(of: upright),
            pixelFormat: pixelFormat,
            adjustContext: { $0.horizonAngle = horizonAngle }
        ) else {
            throw PhotoSaveError.renderFailed
        }

        let properties = ImageMetadata.withPixelSize(
            ImageMetadata.preservedProperties(from: sourceProperties),
            width: cgImage.width, height: cgImage.height
        )
        do {
            let data = try ImageEncoder.encode(cgImage, format: format, properties: properties, quality: Self.compressionQuality)
            return RenderedPhoto(data: data, sourceProperties: sourceProperties)
        } catch {
            throw PhotoSaveError.encodingFailed(error)
        }
    }

    /// 편집 입력 요청. 이전 TripShot 편집이면 원본을, 다른 앱 편집이면 그 렌더 결과를 입력으로 받는다.
    /// iCloud에만 있는 원본은 내려받는다. 이 호출은 에셋을 읽기만 한다.
    private func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        guard asset.mediaType == .image else { throw PhotoSaveError.inputUnavailable(nil) }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == PhotoSaver.adjustmentFormatIdentifier
        }
        // 시그니처: PHAsset.requestContentEditingInput(with: PHContentEditingInputRequestOptions?,
        //           completionHandler: @escaping (PHContentEditingInput?, [AnyHashable: Any]) -> Void) -> PHContentEditingInputRequestID
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    let error = info[PHContentEditingInputErrorKey] as? Error
                    continuation.resume(throwing: PhotoSaveError.inputUnavailable(error))
                }
            }
        }
    }

    /// 렌더 결과를 쓸 URL과 실제 포맷. 원하는 포맷을 출력이 지원하지 않으면 JPEG.
    private func renderedContentDestination(for output: PHContentEditingOutput,
                                            wanted: ImageEncoder.Format) throws -> (URL, ImageEncoder.Format) {
        if #available(iOS 17, *) {
            // 시그니처(iOS 17+): PHContentEditingOutput.supportedRenderedContentTypes: [UTType]
            //                    PHContentEditingOutput.renderedContentURL(for type: UTType) throws -> URL
            // TODO(검증): 위 두 API 이름·throws 여부를 Xcode에서 확인.
            let format: ImageEncoder.Format =
                output.supportedRenderedContentTypes.contains(wanted.uti) ? wanted : .jpeg
            do {
                return (try output.renderedContentURL(for: format.uti), format)
            } catch {
                throw PhotoSaveError.writeFailed(error)
            }
        } else {
            // iOS 16 이하: renderedContentURL은 JPEG 고정. (배포 대상이 iOS 26이라 실제로는 쓰이지 않는다.)
            return (output.renderedContentURL, .jpeg)
        }
    }
}

/// `performChanges` 블록 안에서 만든 placeholder 식별자를 바깥으로 꺼내기 위한 상자.
/// (변경 블록이 @Sendable일 수 있어 캡처한 지역 변수를 직접 바꾸지 않는다.)
private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}
