// 촬영 탭 상태와 연결: 카메라 프레임 → 라이브 보정 → Metal 프리뷰, 프리셋·인물 모드·열 상태 반영, 촬영 후 풀해상도 후처리 대기열.
import AVFoundation
import Combine
import CoreImage
import Foundation
import Photos
import SwiftUI
import UIKit

/// 촬영 탭 ViewModel.
///
/// 큐 규칙:
/// - 이 객체의 상태(`@Published`)는 메인에서만 바뀐다.
/// - 카메라 프레임 콜백(비디오 큐)은 `LivePipeline`·`MetalPreviewView.Coordinator`만 만진다(둘 다 잠금 보호).
///   콜백은 `nonisolated static` 함수에서 만들어 메인 액터 격리를 물려받지 않게 한다.
/// - 후처리 렌더·저장은 `Task.detached`에서 한 장씩(순차) 한다. 촬영은 후처리를 기다리지 않는다.
///
/// "보이는 대로 저장": 프리뷰와 후처리는 같은 `PresetParams`·`PipelineContext`로 `EnhancePipeline.apply`를 부른다.
/// 셔터를 누른 순간의 설정을 tag로 보관했다가 그 사진의 후처리에 쓴다.
@MainActor
final class CaptureViewModel: ObservableObject {
    /// 후처리 대기 설정을 이 개수보다 많이 보관하지 않는다(촬영 실패로 남은 항목 정리).
    static let maxPendingSnapshots = 30
    static let thumbnailSize = CGSize(width: 200, height: 200)

    let camera = CameraService()
    let pipeline = LivePipeline()
    let preview = MetalPreviewView.Coordinator()

    // MARK: 화면 상태

    /// 프리셋 스트립 선택 표시.
    @Published private(set) var choice: PresetChoice = .auto
    /// 프리뷰·후처리에 쓰는 현재 보정값.
    @Published private(set) var params = PresetParams()
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var previewMaxDimension: CGFloat = PreviewQuality.baseDimension
    /// 마지막 촬영 사진(보정 후처리가 끝나면 보정본으로 다시 읽는다).
    @Published private(set) var lastThumbnail: UIImage?
    /// 후처리 대기 + 진행 중인 장 수(배지).
    @Published private(set) var processingCount = 0
    @Published var errorMessage: String?
    /// 측정용 초당 프리뷰 프레임 수·버린 프레임 수(DEBUG 빌드 표시).
    @Published private(set) var stats: String = ""

    // MARK: 내부 상태

    private var services: AppServices?
    private var cameraReady = false
    private var isActive = false
    private var pinchBaseZoom: CGFloat = 1
    private var lastCapturedID: String?
    private var captureTag = 0
    private var snapshots: [Int: CaptureSnapshot] = [:]
    private var jobs: [PostProcessJob] = []
    private var worker: Task<Void, Never>?
    private var workerBusy = false
    private var thumbnailTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// 셔터 순간의 보정 설정.
    private struct CaptureSnapshot {
        let params: PresetParams
        let context: PipelineContext
    }

    /// 후처리 한 건.
    private struct PostProcessJob {
        let localID: String
        let params: PresetParams
        let context: PipelineContext
    }

    init() {
        // CameraService의 메시지(@Published, 메인에서 변경)를 이 객체의 변경으로 전달해 화면이 갱신되게 한다.
        camera.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 열 상태 변화 알림은 임의 스레드에서 온다 → 메인으로.
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateThermalState() }
            .store(in: &cancellables)
    }

    // MARK: 연결

    /// 앱 서비스 주입과 카메라·파이프라인 연결. 여러 번 불러도 안전하다.
    func configure(services: AppServices) {
        guard self.services == nil else { return }
        self.services = services
        camera.photoSaver = services.photoSaver
        camera.locationProvider = services.locationProvider
        camera.frameHandler = Self.makeFrameHandler(camera: camera, pipeline: pipeline, preview: preview)
        camera.postCaptureHandler = Self.makeSavedHandler(for: self)
        updateThermalState()   // 설정 반영 포함
    }

    /// 비디오 큐에서 실행되는 프레임 콜백. 메인 액터 객체를 캡처하지 않는다.
    nonisolated private static func makeFrameHandler(camera: CameraService,
                                                     pipeline: LivePipeline,
                                                     preview: MetalPreviewView.Coordinator) -> (CVPixelBuffer, CMTime) -> Void {
        return { [weak camera, weak pipeline, weak preview] buffer, _ in
            guard let camera, let pipeline, let preview else { return }
            // 2차 백프레셔: 이전 프레임이 GPU에서 끝나지 않았으면 이 프레임은 버린다.
            guard preview.beginFrame() else { return }
            let image: CIImage? = autoreleasepool {
                pipeline.process(buffer, orientation: camera.frameOrientation)
            }
            if let image {
                preview.submit(image)
            } else {
                preview.cancelFrame()
            }
        }
    }

    /// 촬영 원본 저장 완료 콜백(임의 스레드) → 메인으로 옮긴다.
    nonisolated private static func makeSavedHandler(for vm: CaptureViewModel) -> (String, Int) -> Void {
        return { [weak vm] localID, tag in
            Task { @MainActor in vm?.handleSaved(localID: localID, tag: tag) }
        }
    }

    // MARK: 생명주기

    /// 카메라 권한을 받은 뒤 호출. 세션 구성·시작.
    func startCamera() {
        cameraReady = true
        camera.configureIfNeeded()
        resume()
    }

    /// 화면이 보일 때(포그라운드·촬영 탭).
    func resume() {
        guard cameraReady, !isActive else { return }
        isActive = true
        pipeline.isEnabled = true
        preview.setActive(true)
        camera.start()
        startStats()
    }

    /// 백그라운드로 가거나 다른 탭으로 갈 때. 프레임 처리·그리기 예약을 멈추고 세션을 정지한다.
    func pause() {
        guard isActive else { return }
        isActive = false
        pipeline.isEnabled = false
        preview.setActive(false)
        camera.stop()
        statsTask?.cancel()
        statsTask = nil
    }

    // MARK: 프리셋·인물 모드·열 상태

    /// 화면의 프리셋 목록·앱 선택 프리셋과 동기화한다(목록 변경·다른 화면에서 선택 변경 시).
    /// 앱 선택 프리셋이 없거나 지워졌으면 자동 보정. "원본"은 앱 상태에 저장하지 않으므로 선택돼 있으면 유지한다.
    func syncPresets(_ presets: [Preset]) {
        guard let services else { return }
        if let id = services.selectedPresetID, let preset = presets.first(where: { $0.id == id }) {
            apply(choice: .preset(id), params: preset.params)
        } else if choice == .original {
            return
        } else {
            apply(choice: .auto, params: PresetParams())
        }
    }

    /// 프리셋 스트립에서 선택. 앱 선택 프리셋(`AppServices.selectedPresetID`)을 앨범 화면과 공유한다.
    func select(choice: PresetChoice, params: PresetParams) {
        apply(choice: choice, params: params)
        switch choice {
        case .preset(let id): services?.selectedPresetID = id
        case .auto, .original: services?.selectedPresetID = nil
        }
    }

    /// 인물 모드 스위치 변경 등으로 파이프라인 컨텍스트가 바뀌었을 때.
    func refreshContext() {
        pushSettings()
    }

    private func apply(choice: PresetChoice, params: PresetParams) {
        self.choice = choice
        self.params = params
        pushSettings()
    }

    private func updateThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        previewMaxDimension = PreviewQuality.maxDimension(for: thermalState)
        pushSettings()
    }

    /// 현재 params·컨텍스트·해상도를 라이브 파이프라인에 한 번에 넘긴다.
    private func pushSettings() {
        guard let services else { return }
        pipeline.update(LiveSettings(params: params,
                                     context: services.pipelineContext(),
                                     maxDimension: previewMaxDimension))
    }

    // MARK: 포커스·줌

    func focus(at devicePoint: CGPoint) {
        camera.focus(at: devicePoint)
    }

    /// 핀치 중: 시작 배율 × 제스처 배율.
    func pinchChanged(_ magnification: CGFloat) {
        camera.setZoom(factor: pinchBaseZoom * magnification) { [weak self] actual in
            self?.zoomFactor = actual
        }
    }

    func pinchEnded() {
        pinchBaseZoom = zoomFactor
    }

    // MARK: 촬영

    /// 셔터. 지금의 보정 설정을 보관하고 촬영을 요청한다. 후처리를 기다리지 않으므로 연속 촬영 가능.
    func capture() {
        captureTag &+= 1
        if let services {
            snapshots[captureTag] = CaptureSnapshot(params: params, context: services.pipelineContext())
            pruneSnapshots()
        }
        camera.capturePhoto(tag: captureTag)
    }

    private func pruneSnapshots() {
        guard snapshots.count > Self.maxPendingSnapshots else { return }
        let excess = snapshots.keys.sorted().prefix(snapshots.count - Self.maxPendingSnapshots)
        for key in excess { snapshots.removeValue(forKey: key) }
    }

    /// 원본이 저장됐다. 썸네일을 갱신하고, 보정이 "원본"이 아니면 후처리 대기열에 넣는다.
    private func handleSaved(localID: String, tag: Int) {
        lastCapturedID = localID
        loadThumbnail(localID: localID)
        guard let snapshot = snapshots.removeValue(forKey: tag) else { return }
        guard snapshot.params != .identity else { return }   // 원본: 후처리 없음
        jobs.append(PostProcessJob(localID: localID, params: snapshot.params, context: snapshot.context))
        updateProcessingCount()
        startWorkerIfNeeded()
    }

    // MARK: 후처리 대기열 (순차)

    private func startWorkerIfNeeded() {
        guard worker == nil, let saver = services?.photoSaver else { return }
        worker = Task { [weak self] in
            while let job = self?.dequeueJob() {
                let error = await Self.run(job, saver: saver)
                self?.finish(job, error: error)
            }
            self?.worker = nil
        }
    }

    private func dequeueJob() -> PostProcessJob? {
        guard !jobs.isEmpty else {
            workerBusy = false
            updateProcessingCount()
            return nil
        }
        workerBusy = true
        let job = jobs.removeFirst()
        updateProcessingCount()
        return job
    }

    private func finish(_ job: PostProcessJob, error: String?) {
        workerBusy = false
        updateProcessingCount()
        if let error {
            errorMessage = error
        } else if job.localID == lastCapturedID {
            loadThumbnail(localID: job.localID)   // 보정본으로 다시 읽는다
        }
    }

    private func updateProcessingCount() {
        processingCount = jobs.count + (workerBusy ? 1 : 0)
    }

    /// 풀해상도 후처리 한 장. 메인 밖(분리 태스크)에서 렌더·저장한다. 실패 시 사용자 메시지, 성공 시 nil.
    /// 원본은 이미 저장돼 있고, 보정본은 같은 에셋에 비파괴 편집으로 얹는다(PhotoSaver 경유, PLAN §3.4).
    nonisolated private static func run(_ job: PostProcessJob, saver: PhotoSaver) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [job.localID], options: nil)
            guard let asset = assets.firstObject else {
                return "촬영한 사진을 찾지 못해 보정을 적용하지 못했습니다."
            }
            do {
                try await saver.saveNonDestructive(asset: asset, params: job.params,
                                                   horizonAngle: nil, context: job.context)
                return nil
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return "보정 저장 실패(원본은 저장됨): \(message)"
            }
        }.value
    }

    // MARK: 썸네일

    private func loadThumbnail(localID: String) {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return }
            let image = await PhotoImageLoader.image(for: asset, targetSize: Self.thumbnailSize, contentMode: .aspectFill)
            guard !Task.isCancelled, let image else { return }
            self?.lastThumbnail = image
        }
    }

    // MARK: 측정

    /// 1초마다 그린 프레임·버린 프레임 수를 갱신한다(실기기 30fps 확인용).
    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let s = self.preview.takeStats()
                let cameraDropped = self.camera.takeDroppedFrameCount()
                self.stats = "\(s.rendered)fps · 버림 \(s.dropped)+\(cameraDropped) · \(Int(self.previewMaxDimension))px"
            }
        }
    }

    // MARK: 메시지

    /// 화면 하단 알림 문구(저장 완료·오류).
    var toastMessage: String? {
        errorMessage ?? camera.lastError ?? camera.lastSavedMessage
    }

    func clearToast() {
        errorMessage = nil
        camera.lastError = nil
        camera.lastSavedMessage = nil
    }
}
