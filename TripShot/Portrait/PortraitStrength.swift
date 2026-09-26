// 인물 모드 강도 3단계 칩(자연/보통/강함)의 값 묶음과, 칩·직접 값·프리셋 값 중 최종 인물 값을 고르는 규칙(순수 함수).
import Foundation

/// 강도 3단계(PLAN §3.3). 피부·윤곽·눈·치아·피부톤·몸 슬림·다리 길게를 한 번에 정한다. 배경 흐림은 포함하지 않는다(기본 0, 슬라이더로만).
enum PortraitStrength: String, CaseIterable, Identifiable {
    case natural, normal, strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: return "자연"
        case .normal: return "보통"
        case .strong: return "강함"
        }
    }

    /// 이 단계의 인물 값. `enabled = true`, `backgroundBlur = 0`.
    var params: PortraitParams {
        var p = PortraitParams()
        p.enabled = true
        p.backgroundBlur = 0
        switch self {
        case .natural:
            p.skinSmooth = 20; p.faceSlim = 10; p.eyeEnlarge = 0; p.teethWhiten = 10; p.skinBrighten = 0
            p.bodySlim = 15; p.legLengthen = 20
        case .normal:
            p.skinSmooth = 40; p.faceSlim = 20; p.eyeEnlarge = 10; p.teethWhiten = 20; p.skinBrighten = 10
            p.bodySlim = 30; p.legLengthen = 40
        case .strong:
            p.skinSmooth = 60; p.faceSlim = 35; p.eyeEnlarge = 20; p.teethWhiten = 30; p.skinBrighten = 20
            p.bodySlim = 50; p.legLengthen = 60
        }
        return p
    }

    /// 칩에 묶인 값(피부·윤곽·눈·치아·피부톤·몸 슬림·다리 길게)이 정확히 같은 단계. 없으면 nil("직접").
    /// `enabled`와 `backgroundBlur`는 칩과 무관하므로 비교하지 않는다.
    static func matching(_ p: PortraitParams) -> PortraitStrength? {
        allCases.first { s in
            let q = s.params
            return !chipValuesDiffer(q, p)
        }
    }

    /// 칩에 묶인 값 중 하나라도 다른지.
    static func chipValuesDiffer(_ a: PortraitParams, _ b: PortraitParams) -> Bool {
        a.skinSmooth != b.skinSmooth || a.faceSlim != b.faceSlim || a.eyeEnlarge != b.eyeEnlarge
            || a.teethWhiten != b.teethWhiten || a.skinBrighten != b.skinBrighten
            || a.bodySlim != b.bodySlim || a.legLengthen != b.legLengthen
    }

    /// 최종 인물 값 규칙(순수 함수). 인물 모드가 켜져 있을 때 칩·직접 값이 프리셋 값보다 우선한다.
    /// - `base.enabled == false`("원본" 등)면 base 그대로 — 원본 선택이 인물 값 때문에 "보정 있음"이 되지 않게.
    /// - 직접 값(`custom`)이 있으면 그 값(단, `enabled`는 base를 따른다).
    /// - 없으면 단계 값에 base의 `backgroundBlur`를 유지한다(배경 흐림은 칩에 묶이지 않음).
    static func effective(base: PortraitParams, strength: PortraitStrength, custom: PortraitParams?) -> PortraitParams {
        guard base.enabled else { return base }
        if var c = custom {
            c.enabled = base.enabled
            c.backgroundBlur = base.backgroundBlur   // 배경 흐림은 사진별 값(칩·직접 값과 무관)
            return c
        }
        var p = strength.params
        p.enabled = base.enabled
        p.backgroundBlur = base.backgroundBlur
        return p
    }
}
