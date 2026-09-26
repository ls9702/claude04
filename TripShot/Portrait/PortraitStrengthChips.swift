// 인물 강도 3단계 칩(자연/보통/강함) + "직접" 표시. 촬영 화면(프리셋 스트립 위)과 앨범 인물 탭 상단에서 같이 쓴다.
import SwiftUI

struct PortraitStrengthChips: View {
    /// 현재 인물 값과 정확히 같은 단계. nil이면 "직접"(슬라이더로 만든 값)을 강조한다.
    let selection: PortraitStrength?
    let onSelect: (PortraitStrength) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PortraitStrength.allCases) { strength in
                chip(strength.title, selected: selection == strength) { onSelect(strength) }
                    .accessibilityLabel("인물 강도 \(strength.title)")
            }
            if selection == nil {
                // 직접 조정한 값: 누를 수 없는 표시만.
                Text("직접")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().stroke(Color.yellow, lineWidth: 1.5))
                    .foregroundStyle(Color.yellow)
                    .accessibilityLabel("인물 강도 직접 조정")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Color.yellow : Color.white.opacity(0.12)))
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
