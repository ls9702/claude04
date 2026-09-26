// 효과 선택 시트(R2): 20종 템플릿을 분류별 격자로 보여 주고, 탭하면 바로 라이브 프리뷰에 적용된다. "없음"으로 끈다.
import SwiftUI

struct EffectPickerView: View {
    let selection: EffectKind?
    let onSelect: (EffectKind?) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    tile(icon: "🚫", title: "없음", isOn: selection == nil) { onSelect(nil) }
                    ForEach(EffectKind.allCases) { kind in
                        tile(icon: kind.icon, title: kind.title, isOn: selection == kind) { onSelect(kind) }
                            .accessibilityHint(kind.summary)
                    }
                }
                .padding(16)

                if let selection {
                    Text(selection.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("효과")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func tile(icon: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(icon)
                    .font(.system(size: 28))
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(isOn ? 0.35 : 0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(isOn ? Color.yellow : .clear, lineWidth: 2.5))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
