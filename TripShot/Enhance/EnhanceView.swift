// 보정 탭(앨범 보정): 사진 선택 → 프리셋 → 슬라이더(기본/인물 세그먼트·강도 칩) → 전/후(길게 누르기)·얼굴 확대 → 저장(비파괴·사본·일괄) → 닫기(선택 해제). 상태는 EnhanceViewModel.
import Photos
import PhotosUI
import SwiftData
import SwiftUI

/// 보정 탭 진입점. 앱 서비스를 받아 ViewModel을 한 번만 만든다.
struct EnhanceView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        EnhanceScreen(services: services)
    }
}

private struct EnhanceScreen: View {
    @ObservedObject var services: AppServices
    @StateObject private var vm: EnhanceViewModel

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]

    @State private var pickerItems: [PhotosPickerItem] = []
    /// 조정 패널 탭(기본/인물).
    @State private var panelTab: PanelTab = .basic
    /// 얼굴 확대 토글(인물 모드에서 첫 얼굴 주변을 확대해 보여 준다, 이미지 재렌더 없음).
    @State private var faceZoom = false
    @State private var showPresetNameAlert = false
    @State private var newPresetName = ""
    @State private var showClearConfirm = false
    /// 프리뷰를 길게 누르는 동안 true → 원본 표시.
    @GestureState private var isPressingPreview = false

    enum PanelTab: Hashable { case basic, portrait }

    init(services: AppServices) {
        _services = ObservedObject(wrappedValue: services)
        _vm = StateObject(wrappedValue: EnhanceViewModel(services: services))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.items.isEmpty {
                    ContentUnavailableView {
                        Label("보정할 사진을 선택하세요", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("여러 장(최대 50장)을 골라 한 번에 보정할 수 있습니다.")
                    } actions: {
                        photoPicker { Text("사진 선택") }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    editor
                }
            }
            .navigationTitle("보정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    photoPicker { Label("선택", systemImage: "plus") }
                        .disabled(vm.isSaving)
                }
                if !vm.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { saveMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        // 선택 해제 → 초기 화면. 직접 조정한 값이 있으면 먼저 확인한다.
                        Button {
                            if vm.hasAdjustments {
                                showClearConfirm = true
                            } else {
                                clearSelection()
                            }
                        } label: {
                            Label("닫기", systemImage: "xmark")
                        }
                        .disabled(vm.isSaving)
                        .accessibilityLabel("선택 해제")
                    }
                }
            }
            .onChange(of: pickerItems) { _, newItems in
                // 선택 해제(clearSelection)로 비운 경우: 목록이 이미 비어 있으므로 다시 불러오지 않는다.
                if newItems.isEmpty && vm.items.isEmpty { return }
                let identifiers = newItems.map { $0.itemIdentifier }
                Task { await vm.loadSelection(identifiers: identifiers) }
            }
            .onChange(of: services.portraitModeEnabled) { _, enabled in
                vm.wantsPreviewFaces = enabled
                if !enabled { faceZoom = false }
                vm.scheduleRender(debounce: false)
            }
            .onChange(of: services.selectedPresetID) { _, _ in syncDefaultPreset() }
            .onChange(of: presets.map(\.id)) { _, _ in syncDefaultPreset() }
            // 강도 칩·직접 값이 바뀌면(촬영 화면에서 바꾼 경우 포함) 손대지 않은 사진의 기본값을 다시 계산한다.
            .onChange(of: services.portraitStrength) { _, _ in syncDefaultPreset() }
            .onChange(of: services.customPortrait) { _, _ in syncDefaultPreset() }
            .onAppear {
                vm.wantsPreviewFaces = services.portraitModeEnabled
                syncDefaultPreset()
            }
            .alert("알림", isPresented: alertBinding) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(vm.alertMessage ?? "")
            }
            .alert("선택 해제", isPresented: $showClearConfirm) {
                Button("해제", role: .destructive) { clearSelection() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("선택을 해제하면 조정한 값이 사라집니다")
            }
            .alert("프리셋으로 저장", isPresented: $showPresetNameAlert) {
                TextField("프리셋 이름", text: $newPresetName)
                Button("저장") { saveCurrentAsPreset() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("현재 사진의 보정값을 새 프리셋으로 저장합니다.")
            }
        }
    }

    // MARK: 사진 선택

    /// `photoLibrary: .shared()`를 넘겨야 `PhotosPickerItem.itemIdentifier`(PHAsset localIdentifier)가 채워진다.
    /// 선택 자체는 권한 없이 동작하지만, 에셋 조회·저장에 필요하므로 선택 직후 ViewModel이 권한을 요청한다.
    /// TODO(검증): `PhotosPicker(selection:maxSelectionCount:selectionBehavior:matching:preferredItemEncoding:photoLibrary:label:)`
    ///            이니셜라이저 인자 순서·`.ordered` 선택 동작(iOS 16+)을 Xcode에서 확인.
    private func photoPicker<L: View>(@ViewBuilder label: @escaping () -> L) -> some View {
        PhotosPicker(selection: $pickerItems,
                     maxSelectionCount: 50,
                     selectionBehavior: .ordered,
                     matching: .images,
                     preferredItemEncoding: .automatic,
                     photoLibrary: .shared(),
                     label: label)
    }

    /// 사진 선택 해제(PhotosPicker 선택도 비운다). `pickerItems` 변경 → `loadSelection([])`은 권한 요청만 하고 빈 목록을 둔다.
    private func clearSelection() {
        guard !vm.isSaving else { return }
        vm.clearSelection()
        pickerItems = []
    }

    // MARK: 편집 화면

    private var editor: some View {
        ZStack {
            VStack(spacing: 0) {
                previewArea
                thumbnailStrip
                Divider()
                controlsPanel
            }
            .disabled(vm.isSaving)

            if let progress = vm.progress {
                saveProgressOverlay(progress)
            }
        }
    }

    private var displayedImage: UIImage? {
        if isPressingPreview { return vm.originalImage }
        return vm.previewImage ?? vm.originalImage
    }

    private var previewArea: some View {
        ZStack {
            Color.black
            if let image = displayedImage {
                GeometryReader { geo in
                    let zoom = zoomTransform(imageSize: image.size, viewSize: geo.size)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom.scale)
                        .offset(zoom.offset)
                }
            }
            if vm.isLoadingPreview {
                ProgressView().tint(.white)
            } else if let error = vm.previewError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .overlay(alignment: .topLeading) {
            Text(isPressingPreview ? "원본" : "보정")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if vm.isRendering { ProgressView().controlSize(.mini) }
                    Text("\(vm.currentIndex + 1) / \(vm.items.count)")
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

                if services.portraitModeEnabled {
                    faceZoomButton
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottom) {
            Text("길게 눌러 원본 보기 · 좌우로 넘기기")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .opacity(isPressingPreview ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(swipeGesture)
        .simultaneousGesture(beforeAfterGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("보정 프리뷰 \(vm.currentIndex + 1) / \(vm.items.count)")
        .accessibilityAction(named: "다음 사진") { vm.showNext() }
        .accessibilityAction(named: "이전 사진") { vm.showPrevious() }
        .accessibilityAction(named: "얼굴 확대 전환") {
            // 프리뷰 전체가 하나의 접근성 요소라 오버레이 버튼 대신 동작으로 제공한다.
            guard services.portraitModeEnabled, !vm.previewFaceRects.isEmpty else { return }
            faceZoom.toggle()
        }
    }

    // MARK: 얼굴 확대

    /// 얼굴 확대 토글. 첫 얼굴(넓이 최대)이 없으면 비활성.
    private var faceZoomButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { faceZoom.toggle() }
        } label: {
            Image(systemName: faceZoom ? "arrow.up.left.and.arrow.down.right" : "face.smiling")
                .font(.footnote.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(vm.previewFaceRects.isEmpty)
        .opacity(vm.previewFaceRects.isEmpty ? 0.4 : 1)
        .accessibilityLabel(faceZoom ? "얼굴 확대 끄기" : "얼굴 확대")
    }

    /// 확대가 켜져 있고 얼굴이 있으면 첫 얼굴 주변(1.6배 여유)을 화면 가운데로. 아니면 변환 없음.
    private func zoomTransform(imageSize: CGSize, viewSize: CGSize) -> (scale: CGFloat, offset: CGSize) {
        guard faceZoom, services.portraitModeEnabled, let face = vm.previewFaceRects.first else {
            return (1, .zero)
        }
        return FaceZoomGeometry.transform(face: face, imageSize: imageSize, viewSize: viewSize)
    }

    /// 누르고 0.2초가 지나면 손을 뗄 때까지 원본을 보여 준다.
    private var beforeAfterGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isPressingPreview) { value, state, _ in
                switch value {
                case .second(true, _): state = true
                default: break
                }
            }
    }

    /// 좌우 스와이프로 이전/다음 사진.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard !isPressingPreview, abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
                if dx < 0 { vm.showNext() } else { vm.showPrevious() }
            }
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                        Button { vm.select(index: index) } label: {
                            AssetThumbnail(item: item,
                                           selected: index == vm.currentIndex,
                                           saved: vm.savedIDs.contains(item.localID))
                        }
                        .buttonStyle(.plain)
                        .id(item.localID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .frame(height: 68)
            .onChange(of: vm.currentIndex) { _, _ in
                if let id = vm.currentItem?.localID {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PresetStrip(selection: vm.currentChoice) { choice, params in
                    vm.applyPreset(params, choice: choice)
                    // 선택 프리셋은 앱 상태(촬영 화면과 공유). 원본·자동은 nil(기본 = 자동).
                    if case .preset(let id) = choice {
                        services.selectedPresetID = id
                    } else {
                        services.selectedPresetID = nil
                    }
                }
                .padding(.horizontal, -16)

                Picker("조정", selection: $panelTab) {
                    Text("기본").tag(PanelTab.basic)
                    Text("인물").tag(PanelTab.portrait)
                }
                .pickerStyle(.segmented)

                switch panelTab {
                case .basic:
                    AdjustmentSliders(params: currentParamsBinding)
                case .portrait:
                    portraitPanel
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 340)
    }

    /// 인물 탭: 인물 모드 스위치(앱 상태, 촬영 화면과 공유) → 강도 칩 + "직접" → 피부·피부톤·윤곽·눈·치아·배경 흐림.
    private var portraitPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $services.portraitModeEnabled) {
                Label("인물 모드", systemImage: "person.crop.circle")
            }
            if services.portraitModeEnabled {
                if vm.currentParams.portrait.enabled {
                    PortraitStrengthChips(selection: PortraitStrength.matching(vm.currentParams.portrait)) { strength in
                        // 칩: 앱 상태에 저장(직접 값 해제) → 현재 사진의 portrait만 교체.
                        services.selectPortraitStrength(strength)
                        vm.updateCurrentPortrait(services.effectivePortrait(base: vm.currentParams.portrait))
                    }
                    AdjustmentSliders(params: portraitParamsBinding, kinds: AdjustmentKind.portrait)
                    Text("배경 흐림은 저장·보정 화면에서만 적용됩니다(촬영 라이브 프리뷰에는 보이지 않음).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("원본에서는 인물 보정을 적용하지 않습니다")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("인물 모드를 켜면 얼굴별 피부·윤곽·눈·치아 보정과 배경 흐림을 쓸 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentParamsBinding: Binding<PresetParams> {
        Binding(get: { vm.currentParams }, set: { vm.updateCurrentParams($0) })
    }

    /// 인물 슬라이더: 값이 바뀌면 "직접" 값으로 앱 상태에 보관한다(촬영 화면·다른 사진에도 우선 적용).
    private var portraitParamsBinding: Binding<PresetParams> {
        Binding(get: { vm.currentParams }, set: { newValue in
            let oldPortrait = vm.currentParams.portrait
            vm.updateCurrentParams(newValue)
            if newValue.portrait != oldPortrait { services.customPortrait = newValue.portrait }
        })
    }

    // MARK: 저장

    private var saveMenu: some View {
        Menu {
            Button {
                vm.save(mode: .nonDestructive, all: false)
            } label: {
                Label("이 사진 저장(비파괴)", systemImage: "square.and.arrow.down")
            }
            Button {
                vm.save(mode: .copy, all: false)
            } label: {
                Label("사본으로 저장", systemImage: "plus.square.on.square")
            }
            if vm.items.count > 1 {
                Button {
                    vm.save(mode: .nonDestructive, all: true)
                } label: {
                    Label("선택한 전체 \(vm.items.count)장 저장(비파괴)", systemImage: "square.stack.3d.down.right")
                }
                Divider()
                Button {
                    vm.applyCurrentToAll()
                } label: {
                    Label("이 보정을 모든 사진에 적용", systemImage: "square.on.square")
                }
            }
            Divider()
            Button {
                newPresetName = ""
                showPresetNameAlert = true
            } label: {
                Label("현재 슬라이더 값을 프리셋으로 저장", systemImage: "star")
            }
        } label: {
            Label("저장", systemImage: "square.and.arrow.down")
        }
        .disabled(vm.isSaving)
    }

    private func saveProgressOverlay(_ progress: BatchProgress) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(progress.total > 1 ? "사진 저장 중" : "저장 중")
                    .font(.headline)
                ProgressView(value: progress.fraction)
                    .frame(width: 220)
                HStack {
                    Text(progress.currentName).lineLimit(1)
                    Spacer()
                    Text(progress.label).monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 220)
                if progress.total > 1 {
                    Button(progress.cancelRequested ? "취소 중… (현재 장 완료 후 중단)" : "취소", role: .cancel) {
                        vm.cancelBatch()
                    }
                    .disabled(progress.cancelRequested)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: 프리셋

    /// 앱의 선택 프리셋을 손대지 않은 사진의 기본값으로 쓴다. 없으면 자동 보정.
    private func syncDefaultPreset() {
        if let id = services.selectedPresetID, let preset = presets.first(where: { $0.id == id }) {
            vm.setDefault(params: preset.params, choice: .preset(id))
        } else {
            vm.setDefault(params: PresetParams(), choice: .auto)
        }
    }

    /// 현재 사진의 보정값(슬라이더 포함)을 새 프리셋으로 저장하고 선택한다.
    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            vm.alertMessage = "프리셋 이름을 입력해 주세요."
            return
        }
        let order = (presets.map(\.sortOrder).max() ?? -1) + 1
        let preset = Preset(name: name, params: vm.currentParams, isBuiltIn: false, sortOrder: order)
        modelContext.insert(preset)
        do {
            try modelContext.save()
        } catch {
            vm.alertMessage = "프리셋을 저장하지 못했습니다: \(error.localizedDescription)"
            return
        }
        vm.applyPreset(preset.params, choice: .preset(preset.id))
        services.selectedPresetID = preset.id
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { vm.alertMessage != nil },
                set: { if !$0 { vm.alertMessage = nil } })
    }
}

// MARK: - 썸네일

/// 하단 썸네일 한 칸. 작은 크기로만 요청하고, 화면에서 사라지면 `.task` 취소로 요청도 취소된다.
private struct AssetThumbnail: View {
    let item: PhotoItem
    let selected: Bool
    let saved: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .overlay(alignment: .bottomTrailing) {
            if saved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .green)
                    .padding(2)
            }
        }
        .accessibilityLabel(item.displayName)
        .task(id: item.localID) {
            guard let asset = item.asset else { return }
            image = await PhotoImageLoader.image(for: asset,
                                                 targetSize: CGSize(width: 168, height: 168),
                                                 contentMode: .aspectFill)
        }
    }
}

// MARK: - 얼굴 확대 좌표

/// 앨범 프리뷰 얼굴 확대 변환(순수 함수, 테스트 대상). SwiftUI `scaleEffect`(가운데 기준) 뒤 `offset`.
enum FaceZoomGeometry {
    /// 얼굴 사각형 주변 여유 배율.
    static let margin: CGFloat = 1.6
    static let maxScale: CGFloat = 5

    /// - Parameters:
    ///   - face: 프리뷰 이미지 정규화 사각형(0~1, 원점 좌하단).
    ///   - imageSize: 표시 이미지 크기(비율만 쓴다). 이미지는 뷰에 aspect-fit으로 놓인다.
    /// - Returns: 얼굴 중심이 뷰 중심에 오고, 얼굴×여유가 뷰 안에 들어오는 배율(1~5)과 이동량.
    static func transform(face: CGRect, imageSize: CGSize, viewSize: CGSize,
                          margin: CGFloat = margin) -> (scale: CGFloat, offset: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0,
              face.width > 0, face.height > 0 else { return (1, .zero) }
        let fit = MetalPreviewView.fitRect(image: CGRect(origin: .zero, size: imageSize), drawable: viewSize, mode: .fit)
        let faceView = CGRect(x: fit.minX + face.minX * fit.width,
                              y: fit.minY + (1 - face.maxY) * fit.height,
                              width: face.width * fit.width,
                              height: face.height * fit.height)
        let regionW = faceView.width * margin
        let regionH = faceView.height * margin
        let raw = min(viewSize.width / regionW, viewSize.height / regionH)
        let scale = min(max(raw, 1), maxScale)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        // scaleEffect(가운데 기준): p → c + (p − c)·s. 얼굴 중심 f가 c로 오도록 offset = (c − f)·s.
        let offset = CGSize(width: (center.x - faceView.midX) * scale,
                            height: (center.y - faceView.midY) * scale)
        return (scale, offset)
    }
}
