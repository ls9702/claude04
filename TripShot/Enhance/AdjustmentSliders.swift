// 앨범 보정 화면의 조정 슬라이더(기본 8종 + 인물 모드의 피부·피부톤·윤곽·눈·치아·배경 흐림). 라벨 더블탭으로 0 리셋.
import SwiftUI

/// 슬라이더 항목. `keyPath`로 `PresetParams`의 필드와 연결된다.
enum AdjustmentKind: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows, temperature, vibrance, sharpness, lowLight
    /// 인물 모드 전용(`PresetParams.portrait` — 프리셋에 함께 저장된다). 배경 흐림은 저장·앨범에서만 보인다(라이브 미적용).
    case skin, skinTone, slim, eyes, teeth, backgroundBlur

    var id: String { rawValue }

    /// 기본 조정 8종(저조도는 R1-S7).
    static let basic: [AdjustmentKind] = [.exposure, .contrast, .highlights, .shadows, .temperature, .vibrance, .sharpness, .lowLight]
    /// 인물 모드가 켜져 있을 때만 보이는 항목.
    static let portrait: [AdjustmentKind] = [.skin, .skinTone, .slim, .eyes, .teeth, .backgroundBlur]

    var title: String {
        switch self {
        case .exposure: return "노출"
        case .contrast: return "대비"
        case .highlights: return "하이라이트"
        case .shadows: return "섀도우"
        case .temperature: return "색온도"
        case .vibrance: return "생동감"
        case .sharpness: return "선명도"
        case .lowLight: return "저조도"
        case .skin: return "피부"
        case .skinTone: return "피부톤"
        case .slim: return "윤곽"
        case .eyes: return "눈"
        case .teeth: return "치아"
        case .backgroundBlur: return "배경 흐림"
        }
    }

    var systemImage: String {
        switch self {
        case .exposure: return "plusminus.circle"
        case .contrast: return "circle.lefthalf.filled"
        case .highlights: return "sun.max"
        case .shadows: return "moon"
        case .temperature: return "thermometer.medium"
        case .vibrance: return "drop"
        case .sharpness: return "triangle"
        case .lowLight: return "moon.stars"
        case .skin: return "face.smiling"
        case .skinTone: return "sun.min"
        case .slim: return "face.dashed"   // TODO(검증): SF Symbol 이름
        case .eyes: return "eye"
        case .teeth: return "mouth"
        case .backgroundBlur: return "person.crop.rectangle"
        }
    }

    /// 선명도·저조도·피부·피부톤·윤곽·눈·치아·배경 흐림은 0…100, 나머지는 −100…100 (`Mapping` 입력 범위와 같다).
    var range: ClosedRange<Double> {
        switch self {
        case .sharpness, .lowLight, .skin, .skinTone, .slim, .eyes, .teeth, .backgroundBlur: return 0...100
        default: return -100...100
        }
    }

    /// 선명도는 `PresetParams.sharpness`(언샤프 마스크). 로컬 대비(`clarity`)는 프리셋 값만 쓴다.
    var keyPath: WritableKeyPath<PresetParams, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .temperature: return \.temperature
        case .vibrance: return \.vibrance
        case .sharpness: return \.sharpness
        case .lowLight: return \.lowLight
        case .skin: return \.portrait.skinSmooth
        case .skinTone: return \.portrait.skinBrighten
        case .slim: return \.portrait.faceSlim
        case .eyes: return \.portrait.eyeEnlarge
        case .teeth: return \.portrait.teethWhiten
        case .backgroundBlur: return \.portrait.backgroundBlur
        }
    }

    /// 값 라벨. 양방향 슬라이더의 양수에는 "+"를 붙인다.
    func formatted(_ value: Double) -> String {
        let n = Int(value.rounded())
        return (range.lowerBound < 0 && n > 0) ? "+\(n)" : "\(n)"
    }
}

/// 슬라이더 묶음(기본 8종, 또는 `kinds`로 지정). 값이 바뀔 때마다 `params` 전체가 갱신된다(렌더 디바운스는 ViewModel 담당).
struct AdjustmentSliders: View {
    @Binding var params: PresetParams
    let kinds: [AdjustmentKind]

    init(params: Binding<PresetParams>, kinds: [AdjustmentKind] = AdjustmentKind.basic) {
        _params = params
        self.kinds = kinds
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(kinds) { kind in
                AdjustmentRow(kind: kind, value: Binding(
                    get: { params[keyPath: kind.keyPath] },
                    set: { params[keyPath: kind.keyPath] = $0 }
                ))
            }
        }
    }
}

/// 슬라이더 한 줄: 라벨·값 + 슬라이더. 라벨 줄을 두 번 탭하면 0으로 되돌린다.
private struct AdjustmentRow: View {
    let kind: AdjustmentKind
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(kind.title, systemImage: kind.systemImage)
                    .font(.subheadline)
                Spacer()
                Text(kind.formatted(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(value == 0 ? Color.secondary : Color.primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = 0 }
            .accessibilityHint("두 번 탭하면 0으로 되돌립니다")

            Slider(value: $value, in: kind.range, step: 1)
                .accessibilityLabel(kind.title)
                .accessibilityValue(kind.formatted(value))
        }
    }
}
