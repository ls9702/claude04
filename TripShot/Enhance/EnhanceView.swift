import PhotosUI
import SwiftUI

/// P0: 앨범 선택까지만. 보정 파이프라인은 P4.
struct EnhanceView: View {
    @State private var selection: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []

    var body: some View {
        NavigationStack {
            Group {
                if images.isEmpty {
                    ContentUnavailableView("보정할 사진을 선택하세요", systemImage: "photo.on.rectangle.angled", description: Text("여러 장을 골라 한 번에 보정할 수 있습니다."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                            ForEach(images.indices, id: \.self) { i in
                                Image(uiImage: images[i])
                                    .resizable().scaledToFill()
                                    .frame(height: 110).clipped()
                            }
                        }
                    }
                }
            }
            .navigationTitle("보정")
            .toolbar {
                PhotosPicker(selection: $selection, maxSelectionCount: 50, matching: .images) {
                    Label("선택", systemImage: "plus")
                }
            }
            .onChange(of: selection) { _, items in
                Task {
                    var loaded: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                            loaded.append(img)
                        }
                    }
                    images = loaded
                }
            }
        }
    }
}
