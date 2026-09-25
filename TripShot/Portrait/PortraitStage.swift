// 보정 파이프라인 3단계(인물 보정) hook: 저장·앨범용(매번 검출)과 라이브용(평활 트래커) 클로저를 만든다.
import CoreImage

/// 인물 보정 단계. `PipelineContext.portraitStage`에 넣는 클로저를 제공한다.
/// 인물 모드 스위치(앱 상태)가 켜져 있을 때만 `AppServices.pipelineContext(...)`가 이 hook을 넣는다.
/// R1-S5: 피부 부드럽게·잡티·치아. (얼굴 윤곽·눈 확대 워프는 R1-S6.)
enum PortraitStage {
    /// 저장·앨범용. 호출마다 얼굴을 검출한다(긴 변 1024로 줄여 검출, 좌표는 원본 스케일).
    /// 얼굴이 없으면 입력 그대로 + 마스크 nil.
    static func full(detector: FaceDetector, kernels: PortraitKernels?) -> (CIImage, PortraitParams) -> PortraitResult {
        return { image, params in
            // 이번 단계에서 쓰는 강도가 모두 0이면 검출 비용도 쓰지 않는다.
            guard isActive(params) else { return PortraitResult(image: image, skinMask: nil) }
            let faces = detector.detect(in: image, detectionMaxDimension: FaceDetector.defaultDetectionMaxDimension)
            guard !faces.isEmpty else { return PortraitResult(image: image, skinMask: nil) }
            return SkinSmoothing.process(image, faces: faces, params: params, quality: .full, kernels: kernels)
        }
    }

    /// 라이브 프리뷰용. 트래커가 3프레임마다 검출하고 시간축으로 평활한 얼굴을 쓴다. 비디오 큐에서만 호출된다.
    static func live(tracker: SmoothedFaceTracker, kernels: PortraitKernels?) -> (CIImage, PortraitParams) -> PortraitResult {
        return { image, params in
            guard isActive(params) else {
                tracker.reset()
                return PortraitResult(image: image, skinMask: nil)
            }
            let faces = tracker.faces(in: image)
            guard !faces.isEmpty else { return PortraitResult(image: image, skinMask: nil) }
            return SkinSmoothing.process(image, faces: faces, params: params, quality: .live, kernels: kernels)
        }
    }

    /// 이번 단계에서 효과가 있는 값이 하나라도 있는지. (R1-S6에서 faceSlim·eyeEnlarge를 추가한다.)
    static func isActive(_ params: PortraitParams) -> Bool {
        params.skinSmooth > 0 || params.teethWhiten > 0
    }
}
