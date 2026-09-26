// 음원 라이브러리(R3-S5): 앱 Documents/Music/ 폴더의 음원 파일 관리(파일 앱·YouTube 링크 가져오기, 삭제·이름 변경)와 가져온 뒤 박자 검출 1회.
import AVFoundation
import Foundation
import SwiftData
import YouTubeKit

/// 음원 가져오기 오류. 문구는 `UserMessage.text(for:)`가 만든다.
enum MusicImportError: Error, Equatable {
    /// YouTube 링크가 아니거나 영상 ID를 찾지 못함.
    case invalidLink
    /// 오디오 스트림이 없음(m4a 스트림 없음 포함).
    case noStream
    /// 내려받기 실패(네트워크).
    case downloadFailed(String)
    /// YouTube에서 스트림 주소를 뽑지 못함(구조 변경 가능성).
    case extractionFailed
    /// 파일을 읽을 수 없음(오디오 트랙 없음·손상).
    case unreadableFile
    /// 파일 앱 접근 권한(보안 스코프)을 얻지 못함.
    case accessDenied
}

/// 조립 시 음원 상태(순수 판정, 테스트 대상).
enum MusicAvailability: Equatable {
    /// 음악을 고르지 않음.
    case none
    /// 음악 파일 있음.
    case available
    /// 고른 음악의 레코드나 파일이 사라짐 → 경고 후 음악 없이 진행.
    case missing
}

@MainActor
final class MusicLibrary: ObservableObject {
    /// 박자 검출 중인 곡 id(목록에 "분석 중" 표시).
    @Published private(set) var analyzing: Set<UUID> = []

    /// 음원 폴더(Documents/Music/). 없으면 만든다.
    nonisolated static var folderURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Music", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func fileURL(for track: MusicTrack) -> URL { Self.fileURL(fileName: track.fileName) }

    nonisolated static func fileURL(fileName: String) -> URL {
        folderURL.appendingPathComponent(fileName)
    }

    // MARK: 가져오기 — 파일 앱

    /// 파일 앱에서 고른 음원을 Music/ 폴더로 복사하고 레코드를 만든다(아직 insert 전 — `add(_:context:)`로 넣는다).
    func importFile(_ url: URL) async throws -> MusicTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = Self.fileURL(fileName: fileName)
        do {
            // 큰 파일일 수 있으니 복사는 메인 밖에서.
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: url, to: dest)
            }.value
        } catch {
            throw scoped ? MusicImportError.unreadableFile : MusicImportError.accessDenied
        }
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        do {
            let info = try await Self.loadInfo(url: dest)
            return MusicTrack(title: info.title ?? fallbackTitle, fileName: fileName,
                              durationSeconds: info.duration, sourceURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    // MARK: 가져오기 — YouTube

    /// YouTube 링크 → 오디오(m4a) 스트림 추출(YouTubeKit) → 내려받아 Music/<videoID>.m4a → 레코드(insert 전).
    /// `progress`는 내려받기 진행률(0~1, 메인 스레드에서 부른다).
    func importYouTube(url: URL, progress: @escaping (Double) -> Void) async throws -> MusicTrack {
        guard let videoID = Self.videoID(from: url.absoluteString) else { throw MusicImportError.invalidLink }

        // TODO(검증): YouTubeKit API 이름 — `YouTube(videoID:)`, `streams`(async throws),
        // `filterAudioOnly()`, `fileExtension == .m4a`, `highestAudioBitrateStream()`, `stream.url`, `metadata?.title`.
        // 0.2.x README 기준 형태로 썼다. 빌드 오류가 나면 패키지 소스(Sources/YouTubeKit)에서 이름을 맞춘다.
        let video = YouTube(videoID: videoID)
        let remoteURL: URL
        do {
            let streams = try await video.streams
            let audio = streams.filterAudioOnly()
            guard !audio.isEmpty else { throw MusicImportError.noStream }
            // AVFoundation은 webm(opus)을 읽지 못하므로 m4a(AAC)만 쓴다.
            guard let stream = audio.filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream() else {
                throw MusicImportError.noStream
            }
            remoteURL = stream.url
        } catch let error as MusicImportError {
            throw error
        } catch {
            throw MusicImportError.extractionFailed
        }

        let fileName = "\(videoID).m4a"
        let dest = Self.fileURL(fileName: fileName)
        let temp = try await Downloader.download(from: remoteURL) { value in
            Task { @MainActor in progress(value) }
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            throw MusicImportError.downloadFailed(error.localizedDescription)
        }
        progress(1)

        // TODO(검증): `metadata`가 async throws 프로퍼티인지(0.2.x). 제목을 못 얻으면 videoID.
        let title = (try? await video.metadata)?.title
        let info: (title: String?, duration: Double)
        do {
            info = try await Self.loadInfo(url: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw MusicImportError.extractionFailed
        }
        let name = [title, info.title].compactMap { $0 }.first { !$0.isEmpty } ?? videoID
        return MusicTrack(title: name, fileName: fileName, durationSeconds: info.duration,
                          sourceURL: "https://youtu.be/\(videoID)")
    }

    // MARK: 레코드

    /// 가져온 곡을 저장하고 박자 검출을 백그라운드에서 한 번 돌린다. 같은 파일(YouTube 같은 영상)이 있으면 기존 레코드를 갱신.
    @discardableResult
    func add(_ track: MusicTrack, context: ModelContext) -> MusicTrack {
        let fileName = track.fileName
        let existing = (try? context.fetch(FetchDescriptor<MusicTrack>(predicate: #Predicate { $0.fileName == fileName })))?.first
        let target: MusicTrack
        if let existing {
            existing.title = track.title
            existing.durationSeconds = track.durationSeconds
            existing.sourceURL = track.sourceURL
            existing.bpm = nil
            existing.beats = []
            existing.beatsAnalyzed = false
            target = existing
        } else {
            context.insert(track)
            target = track
        }
        try? context.save()
        analyzeBeats(target, context: context)
        return target
    }

    /// 박자 검출(1회). 무거운 계산은 `Task.detached(priority: .utility)`, 결과 기록은 메인.
    func analyzeBeats(_ track: MusicTrack, context: ModelContext) {
        guard !analyzing.contains(track.id) else { return }
        let id = track.id
        let url = fileURL(for: track)
        analyzing.insert(id)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> BeatDetector.Result? in
                try? await BeatDetector.analyze(url: url)
            }.value
            // 메인: SwiftData 기록.
            track.bpm = result?.bpm
            track.beats = result?.beats ?? []
            track.beatsAnalyzed = true
            try? context.save()
            self?.analyzing.remove(id)
        }
    }

    /// 아직 분석하지 않은 곡을 분석한다(목록 화면 진입 시, 예전에 넣은 곡 대비).
    func analyzePending(_ tracks: [MusicTrack], context: ModelContext) {
        for track in tracks where !track.beatsAnalyzed
            && FileManager.default.fileExists(atPath: fileURL(for: track).path) {
            analyzeBeats(track, context: context)
        }
    }

    /// 파일과 레코드를 지운다.
    func delete(_ track: MusicTrack, context: ModelContext) {
        try? FileManager.default.removeItem(at: fileURL(for: track))
        context.delete(track)
        try? context.save()
    }

    /// 이름 변경(표시 제목만. 파일명은 그대로).
    func rename(_ track: MusicTrack, to title: String, context: ModelContext) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        track.title = trimmed
        try? context.save()
    }

    // MARK: 순수 함수

    /// 문자열(주변 텍스트·공백 허용)에서 YouTube 영상 ID(11자)를 찾는다.
    /// youtube.com/watch?v= (다른 쿼리 뒤 &v= 포함), m.·music.youtube.com, youtu.be/, shorts/, embed/, live/.
    nonisolated static func videoID(from string: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9-])(?:youtube\.com/(?:watch\?(?:[^\s#]*?&)?v=|shorts/|embed/|live/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[idRange])
    }

    /// 조립 시 음원 상태 판정. `trackID`가 없으면 none, 레코드나 파일이 없으면 missing.
    nonisolated static func availability(trackID: UUID?, trackExists: Bool, fileExists: Bool) -> MusicAvailability {
        guard trackID != nil else { return .none }
        return trackExists && fileExists ? .available : .missing
    }

    /// 파일의 제목(메타데이터)·길이.
    nonisolated static func loadInfo(url: URL) async throws -> (title: String?, duration: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MusicImportError.unreadableFile }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MusicImportError.unreadableFile }
        var title: String?
        if let metadata = try? await asset.load(.commonMetadata),
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first {
            title = try? await item.load(.stringValue)
        }
        return (title?.trimmingCharacters(in: .whitespacesAndNewlines), duration)
    }
}

// MARK: - 내려받기(진행률)

/// URLSession 다운로드 작업을 진행률과 함께 async로 감싼다. 끝난 파일은 임시 폴더로 옮겨 돌려준다.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var movedURL: URL?

    private init(progress: @escaping (Double) -> Void) {
        self.progress = progress
    }

    static func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = Downloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                delegate.continuation = cont
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 이 콜백이 끝나면 location 파일이 지워지므로 바로 옮긴다.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return   // didCompleteWithError에서 상태 코드로 실패 처리
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID().uuidString).m4a")
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            movedURL = temp
        } catch {
            movedURL = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error {
            cont.resume(throwing: MusicImportError.downloadFailed(error.localizedDescription))
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            cont.resume(throwing: MusicImportError.downloadFailed("HTTP \(http.statusCode)"))
        } else if let movedURL {
            cont.resume(returning: movedURL)
        } else {
            cont.resume(throwing: MusicImportError.downloadFailed("파일 저장 실패"))
        }
    }
}
