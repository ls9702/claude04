// 효과 선택 시트(R2): 40종 템플릿을 분류(스티커·얼굴·렌즈·스타일)별 격자로 보여 주고, 탭하면 바로 라이브 프리뷰에 적용된다.
import SwiftUI
import UIKit

struct EffectPickerView: View {
    let selection: EffectKind?
    let onSelect: (EffectKind?) -> Void

    @State private var category: EffectKind.Category = .sticker
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("분류", selection: $category) {
                    ForEach(EffectKind.Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        noneTile
                        ForEach(EffectKind.allCases.filter { $0.category == category }) { kind in
                            tile(kind)
                        }
                    }
                    .padding(.horizontal, 16)

                    if let selection {
                        Text("\(selection.title) — \(selection.summary)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .padding(.top, 8)
            .navigationTitle("효과")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if let selection { category = selection.category } }
        }
    }

    private var noneTile: some View {
        Button { onSelect(nil) } label: {
            tileBody(isOn: selection == nil, title: "없음") {
                Image(systemName: "nosign").font(.title2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("효과 없음")
    }

    private func tile(_ kind: EffectKind) -> some View {
        Button { onSelect(kind) } label: {
            tileBody(isOn: selection == kind, title: kind.title) {
                if let name = kind.tileAsset, let image = Self.thumbnail(name) {
                    Image(uiImage: image).resizable().scaledToFit().padding(7)
                } else {
                    Text(kind.icon).font(.system(size: 28))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .accessibilityHint(kind.summary)
        .accessibilityAddTraits(selection == kind ? .isSelected : [])
    }

    private func tileBody<Content: View>(isOn: Bool, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(isOn ? 0.35 : 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isOn ? Color.yellow : .clear, lineWidth: 2.5))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    /// 타일용 스티커 그림(번들 PNG). 한 번 읽은 것은 캐시한다.
    private static var cache: [String: UIImage] = [:]
    private static func thumbnail(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        let file = "stk_" + name
        guard let url = Bundle.main.url(forResource: file, withExtension: "png")
                ?? Bundle.main.url(forResource: file, withExtension: "png", subdirectory: "Stickers"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[name] = image
        return image
    }
}
