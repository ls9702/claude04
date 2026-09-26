// 쇼츠 조립 화면(R3-S4·S5): 칸 영상 + 음악(시작 지점·원래 소리·비트 맞춤)으로 템플릿대로 조립 → 미리보기 재생 → 1080×1920 내보내기 → 사진 앱 저장.
import AVKit
import SwiftData
import SwiftUI

struct AssembleView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var library: MusicLibrary
    @Bindable var project: ShortsProject
    @Query private var tracks: [MusicTrack]

    @State private var player: AVPlayer?
    @State private var keepOriginalAudio = true
    /// 칸 경계를 음악 비트에 맞출지(템플릿 bpm과 맞을 때만 켤 수 있음).
    @State private var alignToBeats = true
    @State private var showMusicPicker = false
    /// 슬라이더 편집 중 값(손을 떼면 프로젝트에 저장·재조립).
    @State private var musicStart: Double = 0
    @State private var building = false
    @State private var exporting = false
    @State private var progress: Double = 0
    @State private var message: String?
    @State private var built: (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?)?
    /// 늦게 끝난 이전 조립 결과가 새 결과를 덮지 않게.
    @State private var buildGeneration = 0
    /// 음악 파일 없음 경고를 한 번만.
    @State private var warnedMissingMusic = false

    /// 끝 페이드아웃(고정).
    private static let fadeOutSeconds = 1.5

    private var template: ShortsTemplate? { ShortsTemplateLibrary.template(for: project.templateKey) }

    private var selectedTrack: MusicTrack? {
        guard let id = project.musicTrackID else { return nil }
        return tracks.first { $0.id == id }
    }

    /// 비트 맞춤이 가능한지(템플릿 bpm이 있고 음악 bpm이 20% 이내).
    private var canAlign: Bool {
        ShortsTimeline.shouldSnap(templateBPM: template?.beatsPerMinute, musicBPM: selectedTrack?.bpm)
    }

    /// 대략의 쇼츠 길이(시작 지점 슬라이더 범위용).
    private var approxLength: Double {
        guard let template else { return 0 }
        if alignToBeats, canAlign, let bpm = selectedTrack?.bpm {
            let sum = template.slotSecondsAdjusted(forBPM: bpm).reduce(0, +)
            return sum - template.transition.duration * Double(max(template.slots.count - 1, 0))
        }
        return template.totalSeconds
    }

    var body: some View {
        ScrollView {
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
                    Text("\(template.name) · \(template.slots.count)칸 · 약 \(Int(approxLength.rounded()))초 · 전환 \(template.transition.title)")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                musicControls
                    .padding(.horizontal)

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
                    .disabled(built == nil || building)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("쇼츠 만들기")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            musicStart = project.musicStartSeconds
            await rebuild()
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $showMusicPicker) {
            MusicPickerSheet(selectedID: project.musicTrackID) { track in
                project.musicTrackID = track?.id
                project.musicStartSeconds = 0
                musicStart = 0
                warnedMissingMusic = false
                try? context.save()
                Task { await rebuild() }
            }
        }
        // 박자 분석이 끝나 bpm이 생기면 비트 맞춤을 반영해 다시 조립.
        .onChange(of: selectedTrack?.bpm) { _, _ in
            if alignToBeats { Task { await rebuild() } }
        }
        .alert("알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    // MARK: 음악 조작부

    @ViewBuilder
    private var musicControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                player?.pause()
                showMusicPicker = true
            } label: {
                HStack {
                    Label("음악", systemImage: "music.note")
                    Spacer()
                    Text(musicTitle).lineLimit(1).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if let track = selectedTrack {
                let upper = max(track.durationSeconds - approxLength, 0)
                if upper > 0.5 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("시작 지점 \(MusicFormat.duration(musicStart)) / \(MusicFormat.duration(track.durationSeconds))")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $musicStart, in: 0...upper, onEditingChanged: { editing in
                            guard !editing else { return }
                            project.musicStartSeconds = musicStart
                            try? context.save()
                            Task { await rebuild() }
                        })
                    }
                }
                Toggle(isOn: $alignToBeats) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("비트에 맞추기")
                        Text(beatCaption(track)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!canAlign)
                .onChange(of: alignToBeats) { _, _ in Task { await rebuild() } }
                Text("끝 \(String(format: "%.1f", Self.fadeOutSeconds))초 페이드아웃")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle(selectedTrack == nil ? "영상 원래 소리" : "영상 원래 소리(작게)", isOn: $keepOriginalAudio)
                .onChange(of: keepOriginalAudio) { _, _ in Task { await rebuild() } }
        }
    }

    private var musicTitle: String {
        guard project.musicTrackID != nil else { return "없음" }
        return selectedTrack?.title ?? "찾을 수 없음"
    }

    private func beatCaption(_ track: MusicTrack) -> String {
        let music: String
        if library.analyzing.contains(track.id) {
            music = "박자 분석 중…"
        } else if let bpm = track.bpm {
            music = "음악 \(Int(bpm.rounded()))bpm"
        } else {
            music = "박자를 찾지 못함"
        }
        guard let templateBPM = template?.beatsPerMinute else { return "\(music) · 이 템플릿은 박자 맞춤이 없습니다" }
        let base = "\(music) · 템플릿 \(Int(templateBPM))bpm"
        return canAlign ? base : base + " (20% 넘게 달라 맞추지 않음)"
    }

    // MARK: 조립

    /// 고른 음악 → 조립 입력. 파일이 사라졌으면 한 번 경고하고 nil(음악 없이).
    private func musicSelection() -> MusicSelection? {
        let track = selectedTrack
        let url = track.map { library.fileURL(for: $0) }
        let state = MusicLibrary.availability(trackID: project.musicTrackID, trackExists: track != nil,
                                              fileExists: url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        switch state {
        case .none:
            return nil
        case .missing:
            warnMissingMusic()
            return nil
        case .available:
            guard let track, let url else { return nil }
            return MusicSelection(fileURL: url, startSeconds: project.musicStartSeconds,
                                  fadeOutSeconds: Self.fadeOutSeconds,
                                  beats: BeatDetector.extendBeats(track.beats, bpm: track.bpm, until: track.durationSeconds),
                                  bpm: track.bpm, alignToBeats: alignToBeats)
        }
    }

    private func warnMissingMusic() {
        guard !warnedMissingMusic else { return }
        warnedMissingMusic = true
        message = UserMessage.musicMissing
    }

    /// 칸 영상을 불러와 컴포지션을 만들고 미리보기 플레이어를 붙인다(음악 포함).
    private func rebuild() async {
        guard let template else { return }
        buildGeneration += 1
        let generation = buildGeneration
        building = true
        player?.pause()
        player = nil
        defer { if generation == buildGeneration { building = false } }
        do {
            let music = musicSelection()
            // 비트 맞춤이면 칸 길이가 바뀌므로(음악 bpm 기준) 원본에서 더 쓸 수 있게 끝을 늘려 준다.
            let adjusted: [Double]? = {
                guard let music, music.alignToBeats, let bpm = music.bpm,
                      ShortsTimeline.shouldSnap(templateBPM: template.beatsPerMinute, musicBPM: bpm) else { return nil }
                return template.slotSecondsAdjusted(forBPM: bpm)
            }()
            var sources: [AssemblySource] = []
            for (i, slot) in template.slots.enumerated() {
                guard let clip = project.clip(forSlot: slot.index) else { throw ShortsAssemblyError.missingClip(slot.index) }
                guard let asset = await ShortsAssembler.loadAsset(localID: clip.assetLocalID) else {
                    throw ShortsAssemblyError.assetUnavailable(slot.index)
                }
                var end = clip.outSeconds
                if let adjusted, i < adjusted.count {
                    let assetDuration = (try? await asset.load(.duration).seconds) ?? clip.outSeconds
                    end = max(clip.outSeconds, min(assetDuration, clip.inSeconds + adjusted[i] + ShortsTimeline.beatTolerance))
                }
                sources.append(AssemblySource(asset: asset, start: clip.inSeconds, end: end))
            }
            let result: (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?)
            do {
                result = try await ShortsAssembler.build(template: template, sources: sources,
                                                         keepOriginalAudio: keepOriginalAudio, music: music)
            } catch ShortsAssemblyError.musicUnavailable {
                // 음악 파일이 손상·삭제 → 경고 후 음악 없이.
                warnMissingMusic()
                result = try await ShortsAssembler.build(template: template, sources: sources,
                                                         keepOriginalAudio: keepOriginalAudio, music: nil)
            }
            guard generation == buildGeneration else { return }
            built = result
            let item = AVPlayerItem(asset: result.0)
            item.videoComposition = result.1
            item.audioMix = result.2
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
        } catch {
            guard generation == buildGeneration else { return }
            built = nil
            message = UserMessage.text(for: error)
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
            message = UserMessage.text(for: error)
        }
    }
}
