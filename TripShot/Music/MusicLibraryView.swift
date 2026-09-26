// 음원 라이브러리 화면(R3-S5): 목록(제목·길이·bpm·출처), YouTube 링크/파일 가져오기, 미리듣기, 스와이프 삭제·이름 변경. 조립 화면의 음악 선택 시트도 여기.
import AVFoundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MusicLibraryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var library: MusicLibrary
    @Query(sort: \MusicTrack.addedAt, order: .reverse) private var tracks: [MusicTrack]
    @StateObject private var player = MusicPreviewPlayer()

    @State private var link = ""
    @State private var importing = false
    @State private var downloadProgress: Double = 0
    @State private var showFileImporter = false
    @State private var clipboardHasURL = false
    @State private var alertTitle = "알림"
    @State private var message: String?
    @State private var renaming: MusicTrack?
    @State private var renameText = ""

    var body: some View {
        List {
            importSection
            Section {
                if tracks.isEmpty {
                    Text("가져온 음원이 없습니다. YouTube 링크나 파일 앱에서 가져오세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(tracks) { track in
                    MusicTrackRow(track: track,
                                  analyzing: library.analyzing.contains(track.id),
                                  isPlaying: player.playingID == track.id) {
                        player.toggle(id: track.id, url: library.fileURL(for: track))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if player.playingID == track.id { player.stop() }
                            library.delete(track, context: context)
                        } label: { Label("삭제", systemImage: "trash") }
                        Button {
                            renameText = track.title
                            renaming = track
                        } label: { Label("이름", systemImage: "pencil") }
                        .tint(.orange)
                    }
                }
            } header: {
                Text("음원 \(tracks.count)곡")
            } footer: {
                Text("왼쪽으로 밀어 삭제·이름 변경. 가져온 뒤 박자(bpm)를 자동으로 분석합니다(앞 90초).")
            }
        }
        .navigationTitle("음원 라이브러리")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .mpeg4Audio, .mp3]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): show("가져오지 못했습니다", UserMessage.text(for: error))
            }
        }
        .alert("이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("제목", text: $renameText)
            Button("저장") {
                if let renaming { library.rename(renaming, to: renameText, context: context) }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
        .alert(alertTitle, isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(message ?? "") }
        .onAppear {
            refreshClipboard()
            library.analyzePending(tracks, context: context)
        }
        .onDisappear { player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshClipboard() }
    }

    private var importSection: some View {
        Section {
            HStack {
                TextField("YouTube 링크", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(importing)
                // 클립보드 내용은 사용자가 이 버튼을 누를 때만 읽는다(PasteButton은 붙여넣기 허용 알림도 뜨지 않는다).
                if clipboardHasURL && !importing {
                    PasteButton(payloadType: URL.self) { urls in
                        guard let url = urls.first else { return }
                        Task { @MainActor in link = url.absoluteString }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                }
            }
            if !link.isEmpty {
                if let id = MusicLibrary.videoID(from: link) {
                    Text("영상 ID \(id)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("YouTube 링크가 아닙니다.").font(.caption).foregroundStyle(.orange)
                }
            }
            if importing {
                ProgressView(value: downloadProgress) {
                    Text(downloadProgress > 0 ? "내려받는 중 \(Int(downloadProgress * 100))%" : "음원 찾는 중…")
                        .font(.footnote)
                }
            } else {
                Button {
                    Task { await importYouTube() }
                } label: {
                    Label("YouTube 링크로 가져오기", systemImage: "link.badge.plus")
                }
                .disabled(MusicLibrary.videoID(from: link) == nil)
            }
            Button {
                showFileImporter = true
            } label: {
                Label("파일에서 가져오기", systemImage: "folder")
            }
            .disabled(importing)
        } header: {
            Text("가져오기")
        } footer: {
            Text("YouTube 앱에서 공유 > 링크 복사 후 이 화면으로 오면 붙여넣기 버튼이 나타납니다. 가져오기가 안 되면(YouTube 구조 변경) 파일 앱에서 가져오세요.")
        }
    }

    private func refreshClipboard() {
        // hasURLs는 내용을 읽지 않으므로 붙여넣기 허용 알림이 뜨지 않는다.
        clipboardHasURL = UIPasteboard.general.hasURLs
    }

    private func importYouTube() async {
        // 주변 텍스트가 섞여 있어도 영상 ID로 표준 링크를 만든다.
        guard let url = MusicLibrary.videoID(from: link).flatMap({ URL(string: "https://youtu.be/\($0)") }) else {
            show("가져오지 못했습니다", UserMessage.text(for: MusicImportError.invalidLink))
            return
        }
        importing = true
        downloadProgress = 0
        defer { importing = false }
        do {
            let track = try await library.importYouTube(url: url) { value in downloadProgress = value }
            let saved = library.add(track, context: context)
            link = ""
            show("가져왔습니다", "\(saved.title) · \(MusicFormat.duration(saved.durationSeconds))")
        } catch {
            show("YouTube에서 가져오지 못했습니다", UserMessage.text(for: error))
        }
    }

    private func importFile(_ url: URL) async {
        importing = true
        downloadProgress = 0
        defer { importing = false }
        do {
            let track = try await library.importFile(url)
            library.add(track, context: context)
        } catch {
            show("가져오지 못했습니다", UserMessage.text(for: error))
        }
    }

    private func show(_ title: String, _ text: String) {
        alertTitle = title
        message = text
    }
}

// MARK: - 행

struct MusicTrackRow: View {
    let track: MusicTrack
    var analyzing = false
    var isPlaying = false
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: track.isFromYouTube ? "play.rectangle.fill" : "music.note")
                .foregroundStyle(track.isFromYouTube ? Color.red : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPlaying ? "정지" : "미리듣기")
            }
        }
    }

    private var detail: String {
        var parts = [MusicFormat.duration(track.durationSeconds)]
        if analyzing {
            parts.append("박자 분석 중…")
        } else if let bpm = track.bpm {
            parts.append("\(Int(bpm.rounded()))bpm")
        } else if track.beatsAnalyzed {
            parts.append("박자 없음")
        }
        return parts.joined(separator: " · ")
    }
}

enum MusicFormat {
    /// 초 → "3:05".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 미리듣기

/// 한 곡만 재생하는 미리듣기 플레이어.
@MainActor
final class MusicPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(id: UUID, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        do {
            // 무음 스위치가 켜져 있어도 들리게.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingID = id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - 음악 선택 시트(조립 화면)

struct MusicPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @Query(sort: \MusicTrack.addedAt, order: .reverse) private var tracks: [MusicTrack]
    @StateObject private var player = MusicPreviewPlayer()
    let selectedID: UUID?
    let onSelect: (MusicTrack?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Label("음악 없음", systemImage: "speaker.slash")
                            Spacer()
                            if selectedID == nil { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                }
                Section {
                    ForEach(tracks) { track in
                        // 행을 누르면 선택, 오른쪽 ▶(테두리 없는 버튼)은 미리듣기만.
                        HStack {
                            MusicTrackRow(track: track, analyzing: library.analyzing.contains(track.id),
                                          isPlaying: player.playingID == track.id) {
                                player.toggle(id: track.id, url: library.fileURL(for: track))
                            }
                            if selectedID == track.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(track)
                            dismiss()
                        }
                    }
                } footer: {
                    if tracks.isEmpty { Text("음원이 없습니다. 아래에서 가져오세요.") }
                }
                Section {
                    NavigationLink {
                        MusicLibraryView()
                    } label: {
                        Label("음원 가져오기·관리", systemImage: "music.note.list")
                    }
                }
            }
            .navigationTitle("음악 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .onDisappear { player.stop() }
        }
    }
}
