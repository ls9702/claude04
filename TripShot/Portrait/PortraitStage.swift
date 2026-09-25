// 보정 파이프라인 3단계(인물 보정) hook의 자리. R1-S5/S6에서 실제 얼굴 보정으로 교체한다.
import CoreImage

/// 인물 보정 단계. `PipelineContext.portraitStage`에 넣는 클로저를 제공한다.
enum PortraitStage {
    /// R1-S5 전까지의 자리 표시자: 입력을 그대로 돌려준다.
    /// 인물 모드 스위치(앱 상태)가 켜져 있을 때만 `AppServices.pipelineContext()`가 이 hook을 넣는다.
    static let placeholder: (CIImage, PortraitParams) -> CIImage = { image, _ in image }
}
