// 보정 파이프라인 3단계(인물 보정) hook: 저장·앨범용(매번 검출)과 라이브용(평활 트래커) 클로저를 만든다.
import CoreImage

/// 인물 보정 단계. `PipelineContext.portraitStage`에 넣는 클로저를 제공한다.
/// 인물 모드 스위치(앱 상태)가 켜져 있을 때만 `AppServices.pipelineContext(...)`가 이 hook을 넣는다.
/// R1-S5: 피부 부드럽게·잡티·치아. R1-S6: 얼굴 윤곽·눈 확대 워프. R1-S8a: 피부톤 업. R1-S8b: 배경 흐림(저장·앨범만).
///
/// 순서: **전신 워프(몸 슬림·다리 길게, 저장·앨범만)** → 얼굴 검출 → **얼굴 워프** → 랜드마크·boundingBox를 워프 후 좌표로 옮김 → 피부 보정(마스크가 워프된 얼굴에 맞는다) → 배경 흐림.
enum PortraitStage {
    /// 저장·앨범용. 호출마다 얼굴을 검출한다(긴 변 1024로 줄여 검출, 좌표는 원본 스케일).
    /// 얼굴이 없으면 워프·피부는 건너뛴다. 배경 흐림(`backgroundBlur > 0`)은 얼굴 검출 결과와 무관하게
    /// 사람 분리로 동작한다(뒷모습·옆모습). 사람도 없으면 입력 그대로 + 마스크 nil.
    /// - Parameter segmentationPreview: 앨범 프리뷰용이면 true(인물 분리 `.balanced`), 저장이면 false(`.accurate`).
    static func full(detector: FaceDetector, bodyDetector: BodyPoseDetector? = nil, kernels: PortraitKernels?,
                     segmentationPreview: Bool = false) -> (CIImage, PortraitParams) -> PortraitResult {
        return { input, params in
            // 이번 단계에서 쓰는 강도가 모두 0이면 검출·분리 비용도 쓰지 않는다.
            guard isActive(params) else { return PortraitResult(image: input, skinMask: nil) }
            // 전신 워프를 먼저 해서 얼굴 검출·인물 분리가 워프된 이미지 좌표로 이뤄지게 한다.
            var image = input
            if let bodyDetector, BodyShape.isActive(params) {
                image = BodyShape.apply(image, params: params, detector: bodyDetector, kernel: kernels?.bodyReshape)
            }
            let faces = isFaceActive(params)
                ? detector.detect(in: image, detectionMaxDimension: FaceDetector.defaultDetectionMaxDimension)
                : []
            let segmenter: ((CIImage) -> CIImage?)? = params.backgroundBlur > 0
                ? { BackgroundBlur.mask(for: $0, quality: .full, isPreview: segmentationPreview) }
                : nil
            guard !faces.isEmpty || segmenter != nil else { return PortraitResult(image: image, skinMask: nil) }
            return process(image, faces: faces, params: params, quality: .full, kernels: kernels, segmenter: segmenter)
        }
    }

    /// 라이브 프리뷰용. 트래커가 3프레임마다 검출하고 시간축으로 평활한 얼굴을 쓴다. 비디오 큐에서만 호출된다.
    static func live(tracker: SmoothedFaceTracker, kernels: PortraitKernels?) -> (CIImage, PortraitParams) -> PortraitResult {
        return { image, params in
            // 라이브는 배경 흐림을 하지 않으므로 얼굴 보정 값만 본다.
            guard isFaceActive(params) else {
                tracker.reset()
                return PortraitResult(image: image, skinMask: nil)
            }
            let faces = tracker.faces(in: image)
            guard !faces.isEmpty else { return PortraitResult(image: image, skinMask: nil) }
            return process(image, faces: faces, params: params, quality: .live, kernels: kernels)
        }
    }

    /// 워프 → (워프 후 좌표의 얼굴로) 피부·치아 보정 → 배경 흐림(마지막). 주어진 입력에 대해 순수 함수
    /// (배경 분리는 `segmenter`로 주입 — 테스트는 합성 마스크를 돌려주는 클로저를 넘긴다).
    /// - Parameters:
    ///   - faces: 비어 있으면 워프·피부를 건너뛴다.
    ///   - segmenter: 워프·피부까지 끝난 이미지를 받아 사람 마스크(사람 = 1)를 돌려준다. nil을 돌려주면(사람 없음) 흐림 없음.
    ///     `quality == .live`거나 `backgroundBlur == 0`이면 호출하지 않는다.
    static func process(_ image: CIImage, faces: [DetectedFace], params: PortraitParams,
                        quality: PortraitQuality, kernels: PortraitKernels?,
                        segmenter: ((CIImage) -> CIImage?)? = nil) -> PortraitResult {
        var result: PortraitResult
        if faces.isEmpty {
            result = PortraitResult(image: image, skinMask: nil)
        } else {
            let warped = FaceWarp.process(image, faces: faces, params: params, quality: quality, kernels: kernels)
            result = SkinSmoothing.process(warped.image, faces: warped.faces, params: params, quality: quality, kernels: kernels)
        }
        // 배경 흐림: 워프 후 이미지로 분리해야 줄어든 턱선 바깥이 배경으로 잡힌다. 라이브 금지.
        if quality == .full, params.backgroundBlur > 0, let segmenter,
           let personMask = segmenter(result.image) {
            result.image = BackgroundBlur.apply(result.image, personMask: personMask,
                                                strength: params.backgroundBlur / 100)
        }
        return result
    }

    /// 이번 단계에서 효과가 있는 값이 하나라도 있는지(배경 흐림·전신 보정 포함).
    static func isActive(_ params: PortraitParams) -> Bool {
        isFaceActive(params) || params.backgroundBlur > 0 || BodyShape.isActive(params)
    }

    /// 얼굴 검출이 필요한 값(피부·치아·윤곽·눈·피부톤)이 하나라도 있는지.
    static func isFaceActive(_ params: PortraitParams) -> Bool {
        params.skinSmooth > 0 || params.teethWhiten > 0 || params.faceSlim > 0 || params.eyeEnlarge > 0
            || params.skinBrighten > 0
    }
}
