// 쇼츠 조립 화면(R3-S4): 칸 영상으로 템플릿대로 조립 → 미리보기 재생 → 1080×1920 내보내기 → 사진 앱 저장.
import AVKit
import SwiftData
import SwiftUI

struct AssembleView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var services: AppServices
    @Bindable var project: ShortsProject

    @State private var player: AVPlayer?
    @State private var keepOriginalAudio = true
    @State private var building = false
    @State private var exporting = false
    @State private var progress: Double = 0
    @State private var message: String?
    @State private var built: (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?)?

    private var template: ShortsTemplate? { ShortsTemplateLibrary.template(for: project.templateKey) }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black)
                if let player {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else if building {
                    ProgressView("조립 중…").tint(.white).foregroundStyle(.white)
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxHeight: 460)

            if let template {
                Text("\(template.name) · \(template.slots.count)칸 · 약 \(Int(template.totalSeconds.rounded()))초 · 전환 \(template.transition.title)")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Toggle("영상 원래 소리", isOn: $keepOriginalAudio)
                .padding(.horizontal)
                .onChange(of: keepOriginalAudio) { _, _ in Task { await rebuild() } }

            if exporting {
                ProgressView(value: progress) { Text("내보내는 중 \(Int(progress * 100))%") }
                    .padding(.horizontal)
            } else {
                Button {
                    Task { await exportAndSave() }
                } label: {
                    Label(project.exportedAssetLocalID == nil ? "사진 앱에 저장" : "다시 저장", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(built == nil)
            }
            Spacer()
        }
        .padding(.top)
        .navigationTitle("쇼츠 만들기")
        .navigationBarTitleDisplayMode(.inline)
        .task { await rebuild() }
        .onDisappear { player?.pause() }
        .alert("알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    /// 칸 영상을 불러와 컴포지션을 만들고 미리보기 플레이어를 붙인다.
    private func rebuild() async {
        guard let template else { return }
        building = true
        player?.pause()
        player = nil
        defer { building = false }
        do {
            var sources: [AssemblySource] = []
            for slot in template.slots {
                guard let clip = project.clip(forSlot: slot.index) else { throw ShortsAssemblyError.missingClip(slot.index) }
                guard let asset = await ShortsAssembler.loadAsset(localID: clip.assetLocalID) else {
                    throw ShortsAssemblyError.assetUnavailable(slot.index)
                }
                sources.append(AssemblySource(asset: asset, start: clip.inSeconds, end: clip.outSeconds))
            }
            let result = try await ShortsAssembler.build(template: template, sources: sources, keepOriginalAudio: keepOriginalAudio)
            built = result
            let item = AVPlayerItem(asset: result.0)
            item.videoComposition = result.1
            item.audioMix = result.2
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
        } catch {
            built = nil
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func exportAndSave() async {
        guard let (composition, videoComposition, audioMix) = built else { return }
        player?.pause()
        exporting = true
        progress = 0
        defer { exporting = false }
        do {
            let url = try await ShortsAssembler.export(composition: composition, videoComposition: videoComposition,
                                                       audioMix: audioMix) { value in
                Task { @MainActor in progress = value }
            }
            let id = try await services.photoSaver.saveVideo(fileURL: url, location: nil)
            project.exportedAssetLocalID = id
            project.status = .exported
            try? context.save()
            message = "사진 앱에 저장했습니다."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
