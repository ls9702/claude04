// 쇼츠 프로젝트 화면(R3-S2): 템플릿 칸 목록. 칸마다 즉석 촬영(가이드) 또는 앨범 영상 가져오기, 다시 하기, 비우기.
// 칸은 며칠에 걸쳐 채워도 된다(SwiftData에 바로 저장). 모두 채우면 [쇼츠 만들기](R3-S4).
import Photos
import PhotosUI
import SwiftData
import SwiftUI

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var project: ShortsProject
    @State private var pickerSlot: Int?
    @State private var pickerItem: PhotosPickerItem?
    @State private var shootingSlot: SlotSpec?
    @State private var message: String?
    @State private var showExample = false

    private var template: ShortsTemplate? { ShortsTemplateLibrary.template(for: project.templateKey) }

    var body: some View {
        List {
            if let template {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(template.name, systemImage: template.symbol).font(.headline)
                        Text(template.summary).font(.subheadline).foregroundStyle(.secondary)
                        let filled = project.filledSlotCount(of: template)
                        Text("\(filled)/\(template.slots.count)칸 채움 · 완성 \(Int(template.totalSeconds.rounded()))초 · 전환 \(template.transition.title)")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(filled), total: Double(template.slots.count))
                        Button { showExample = true } label: {
                            Label("예시 영상 보기", systemImage: "play.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                Section("칸") {
                    ForEach(template.slots) { slot in
                        SlotRow(slot: slot, clip: project.clip(forSlot: slot.index),
                                onShoot: { shootingSlot = slot },
                                onPick: { pickerSlot = slot.index },
                                onClear: { clear(slot.index) })
                    }
                }
                Section {
                    NavigationLink {
                        AssembleView(project: project)
                    } label: {
                        Label("쇼츠 만들기", systemImage: "wand.and.stars")
                            .font(.headline)
                    }
                    .disabled(project.filledSlotCount(of: template) < template.slots.count)
                } footer: {
                    if project.filledSlotCount(of: template) < template.slots.count {
                        Text("모든 칸을 채우면 만들 수 있어요. 비어 있는 칸은 여행하면서 천천히 채워도 됩니다.")
                    }
                }
            } else {
                Text("이 프로젝트는 예전 방식으로 만들어져 템플릿이 없습니다.")
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: Binding(get: { pickerSlot != nil }, set: { if !$0 { pickerSlot = nil } }),
                      selection: $pickerItem, matching: .videos, photoLibrary: .shared())
        .onChange(of: pickerItem) { _, item in
            guard let item, let slot = pickerSlot else { return }
            pickerItem = nil
            pickerSlot = nil
            guard let id = item.itemIdentifier else {
                message = "사진 보관함 접근 권한이 필요합니다(설정 > TripShot > 사진 > 전체 접근)."
                return
            }
            assign(assetID: id, to: slot)
        }
        .fullScreenCover(item: $shootingSlot) { slot in
            if let template {
                SlotCaptureView(template: template, slot: slot,
                                previousAssetID: slot.index > 0 ? project.clip(forSlot: slot.index - 1)?.assetLocalID : nil) { assetID in
                    assign(assetID: assetID, to: slot.index, shotInApp: true)
                }
            }
        }
        .sheet(isPresented: $showExample) {
            if let template { TemplatePreviewSheet(template: template) }
        }
        .alert("알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    /// 칸에 영상을 넣는다(있으면 바꾼다). 기본 구간은 앞에서부터 칸 길이만큼(영상이 짧으면 전체).
    /// `shotInApp`: 칸 촬영 화면에서 찍은 영상이면 앞 여유(버튼 흔들림)를 건너뛴다.
    private func assign(assetID: String, to slotIndex: Int, shotInApp: Bool = false) {
        guard let slot = template?.slots.first(where: { $0.index == slotIndex }) else { return }
        let duration = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject?.duration ?? slot.seconds
        let range = ClipRange.initial(assetDuration: duration, slotSeconds: slot.seconds,
                                      skipLead: shotInApp ? SlotCaptureTiming.leadIn : 0)
        if let existing = project.clip(forSlot: slotIndex) {
            existing.assetLocalID = assetID
            existing.inSeconds = range.lowerBound
            existing.outSeconds = range.upperBound
        } else {
            let clip = Clip(shotIndex: slotIndex, order: slotIndex, assetLocalID: assetID,
                            inSeconds: range.lowerBound, outSeconds: range.upperBound)
            project.clips.append(clip)
        }
        try? context.save()
    }

    private func clear(_ slotIndex: Int) {
        guard let clip = project.clip(forSlot: slotIndex) else { return }
        project.clips.removeAll { $0.id == clip.id }
        context.delete(clip)
        try? context.save()
    }
}

/// 클립 구간 계산(순수 함수, 테스트 대상).
enum ClipRange {
    /// 처음 넣을 때의 구간: 영상이 칸보다 길면 앞에서부터 칸 길이, 짧으면 전체.
    /// 즉석 촬영 영상은 앞 0.3초(버튼 누르는 흔들림)를 건너뛴다.
    static func initial(assetDuration: Double, slotSeconds: Double, skipLead: Double = 0) -> ClosedRange<Double> {
        let lead = assetDuration - skipLead >= slotSeconds ? skipLead : 0
        let end = min(assetDuration, lead + slotSeconds)
        return lead...max(end, lead)
    }
}

private struct SlotRow: View {
    let slot: SlotSpec
    let clip: Clip?
    let onShoot: () -> Void
    let onPick: () -> Void
    let onClear: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Text("\(slot.index + 1)").font(.title2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(slot.index + 1). \(slot.title)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.1f초", slot.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(slot.instruction).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onShoot) { Label(clip == nil ? "촬영" : "다시 촬영", systemImage: "video.fill") }
                    Button(action: onPick) { Label("앨범", systemImage: "photo.on.rectangle") }
                    if clip != nil {
                        Button(role: .destructive, action: onClear) { Image(systemName: "trash") }
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .task(id: clip?.assetLocalID) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let id = clip?.assetLocalID,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            thumbnail = nil
            return
        }
        thumbnail = await PhotoImageLoader.image(for: asset, targetSize: CGSize(width: 160, height: 280), contentMode: .aspectFill)
    }
}
