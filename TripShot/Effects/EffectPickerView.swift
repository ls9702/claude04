// 효과 선택 띠(R2): 셔터 위에 낮게 붙는 가로 스크롤 — 분류 버튼(스티커·얼굴·렌즈·스타일) + 타일 한 줄.
// 프리뷰를 가리지 않아 효과를 넘겨 보며 바로 확인할 수 있다.
import SwiftUI
import UIKit

struct EffectPickerStrip: View {
    let selection: EffectKind?
    let onSelect: (EffectKind?) -> Void
    let onClose: () -> Void

    @State private var category: EffectKind.Category = .sticker
    @State private var thumbnails: [EffectKind: UIImage] = [:]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(EffectKind.Category.allCases, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c.rawValue)
                            .font(.caption.weight(category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? Color.black : Color.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(category == c ? Color.yellow : Color.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("효과 닫기")
            }
            .padding(.horizontal, 16)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        tile(id: "none", title: "없음", isOn: selection == nil) {
                            Image(systemName: "nosign").font(.title3).foregroundStyle(.white.opacity(0.8))
                        } action: { onSelect(nil) }
                        ForEach(EffectKind.allCases.filter { $0.category == category }) { kind in
                            tile(id: kind.rawValue, title: kind.title, isOn: selection == kind) {
                                if let image = thumbnails[kind] {
                                    Image(uiImage: image).resizable().scaledToFit().padding(4)
                                } else {
                                    Text(kind.icon).font(.system(size: 26))
                                }
                            } action: { onSelect(kind) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear {
                    if let selection {
                        category = selection.category
                        proxy.scrollTo(selection.rawValue, anchor: .center)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 8)
        .task(id: category) { await loadThumbnails() }
    }

    private func tile<Content: View>(id: String, title: String, isOn: Bool, @ViewBuilder content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                content()
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white.opacity(isOn ? 0.3 : 0.12)))
                    .overlay(Circle().stroke(isOn ? Color.yellow : .clear, lineWidth: 2.5))
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 58)
            }
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// 스티커 타일: 3D 렌더 썸네일을 백그라운드에서 만든다(처음 한 번, 캐시됨).
    private func loadThumbnails() async {
        guard category == .sticker else { return }
        for kind in EffectKind.allCases where kind.category == .sticker && thumbnails[kind] == nil {
            let image = await Task.detached(priority: .utility) { StickerRenderer3D.shared.thumbnail(kind) }.value
            if Task.isCancelled { return }
            if let image { thumbnails[kind] = image }
        }
    }
}
