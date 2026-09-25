// PhotoKit에서 다운샘플 이미지와 이전 TripShot 편집 기록(PHAdjustmentData)을 async로 읽어 오는 도구(읽기 전용).
import Foundation
import Photos
import UIKit

/// 사진 보관함 읽기 도우미. 에셋을 바꾸지 않는다.
enum PhotoImageLoader {

    // MARK: 다운샘플 이미지

    /// `targetSize`(픽셀) 안에 맞춘 이미지를 한 번만 받아 온다. iCloud 원본은 내려받는다.
    /// - 풀해상도를 메모리에 올리지 않도록 `resizeMode = .exact`로 요청 크기에 맞춘다.
    /// - Task가 취소되면 PhotoKit 요청을 취소하고 즉시 nil을 돌려준다.
    /// - Parameter version: `.current`(편집 반영본) 또는 `.unadjusted`(편집 전 원본).
    ///   이전 TripShot 편집이 있는 사진은 저장 시 원본에서 다시 렌더하므로 프리뷰도 `.unadjusted`를 쓴다.
    static func image(for asset: PHAsset,
                      targetSize: CGSize,
                      contentMode: PHImageContentMode = .aspectFit,
                      version: PHImageRequestOptionsVersion = .current) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // 결과 핸들러가 한 번만 호출됨(저화질 중간본 없음)
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact
        options.version = version

        let box = ImageRequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                guard box.start(continuation) else { return }   // 이미 취소됨 → nil로 재개됨
                let id = PHImageManager.default().requestImage(for: asset,
                                                               targetSize: targetSize,
                                                               contentMode: contentMode,
                                                               options: options) { image, info in
                    // 방어: 저화질 중간본이 오면 무시하고 최종본을 기다린다.
                    if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                    box.finish(image)
                }
                box.setRequestID(id)
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: 이전 TripShot 편집 기록

    /// 에셋에 TripShot 비파괴 편집 기록이 있으면 그 `AdjustmentPayload`, 없으면 nil.
    /// `PHContentEditingInput`을 요청하므로 비용이 있다(원본 파일 준비). 사진을 처음 표시할 때 한 번만 부른다.
    /// TODO(검증): iCloud 전용 원본은 이 호출이 원본 전체를 내려받는다. 체감이 크면 `isNetworkAccessAllowed = false`로
    ///            바꾸고 로컬에 있는 사진만 복원하는 쪽을 실기기에서 판단.
    static func previousAdjustment(for asset: PHAsset) async -> AdjustmentPayload? {
        guard asset.mediaType == .image else { return nil }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == PhotoSaver.adjustmentFormatIdentifier
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<AdjustmentPayload?, Never>) in
            // 완료 핸들러는 요청마다 한 번 호출된다(성공·실패 모두).
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let adjustment = input?.adjustmentData else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decodePayload(formatIdentifier: adjustment.formatIdentifier,
                                                             data: adjustment.data))
            }
        }
    }

    /// PHAdjustmentData 내용 → AdjustmentPayload. TripShot 형식이 아니거나 해석 불가면 nil. 순수 함수.
    static func decodePayload(formatIdentifier: String, data: Data) -> AdjustmentPayload? {
        guard formatIdentifier == PhotoSaver.adjustmentFormatIdentifier else { return nil }
        return try? JSONDecoder().decode(AdjustmentPayload.self, from: data)
    }
}

/// PHImageManager 요청 한 건의 상태. 결과 콜백·취소가 어느 스레드에서 와도 continuation을 정확히 한 번만 재개한다.
private final class ImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private var finished = false

    /// continuation을 등록한다. 이미 취소됐으면 nil로 바로 재개하고 false.
    func start(_ continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        let cancelNow = cancelled
        if !cancelNow { requestID = id }
        lock.unlock()
        if cancelNow { PHImageManager.default().cancelImageRequest(id) }
    }

    func finish(_ image: UIImage?) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        let pending = finished ? nil : continuation
        finished = true
        continuation = nil
        lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
        pending?.resume(returning: nil)
    }
}
