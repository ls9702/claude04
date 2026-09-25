// 보정 프리셋 가로 스트립: "원본"·"자동" + 저장된 프리셋(정렬 순서). 선택 시 그 파라미터를 알려 준다.
import SwiftData
import SwiftUI

struct PresetStrip: View {
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]

    /// 현재 사진의 선택 표시(nil이면 강조 없음: 복원 값 등).
    let selection: PresetChoice?
    /// (선택 항목, 적용할 파라미터)
    let onSelect: (PresetChoice, PresetParams) -> Void

    init(selection: PresetChoice?, onSelect: @escaping (PresetChoice, PresetParams) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("원본", choice: .original) { onSelect(.original, .identity) }
                    chip("자동", choice: .auto) { onSelect(.auto, PresetParams()) }
                    ForEach(presets) { preset in
                        chip(preset.name, choice: .preset(preset.id)) {
                            onSelect(.preset(preset.id), preset.params)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .onAppear {
                if let selection { proxy.scrollTo(chipID(selection), anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func chip(_ title: String, choice: PresetChoice, action: @escaping () -> Void) -> some View {
        let selected = selection == choice
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.12)))
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .id(chipID(choice))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 스크롤 위치 지정용 식별자. 프리셋은 UUID 그대로.
    private func chipID(_ choice: PresetChoice) -> AnyHashable {
        switch choice {
        case .original: return AnyHashable("original")
        case .auto: return AnyHashable("auto")
        case .preset(let id): return AnyHashable(id)
        }
    }
}
