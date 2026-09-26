// 촬영 탭 상태와 연결: 카메라 프레임 → 라이브 보정 → Metal 프리뷰, 프리셋·인물 모드(강도 칩·얼굴 마커·원본 보기·셀피 제안)·열 상태 반영, 촬영 후 풀해상도 후처리 대기열.
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
    /// 라이브 인물 보정용 얼굴 추적(비디오 큐 전용 상태 + 잠금 보호 얼굴 수). 3프레임마다 검출.
    let faceTracker = SmoothedFaceTracker()

    // MARK: 화면 상태

    /// 프리셋 스트립 선택 표시.
    @Published private(set) var choice: PresetChoice = .auto
    /// 프리뷰·후처리에 쓰는 현재 보정값.
    @Published private(set) var params = PresetParams()
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var previewMaxDimension: CGFloat = PreviewQuality.baseDimension
    /// 마지막 촬영 사진(보정 후처리가 끝나면 보정본으로 다시 읽는다).
    @Published private(set) var lastThumbnail: UIImage?
    /// 후처리 대기 + 진행 중인 장 수(배지).
    @Published private(set) var processingCount = 0
    @Published var errorMessage: String?
    /// 측정용 초당 프리뷰 프레임 수·버린 프레임 수(DEBUG 빌드 표시).
    @Published private(set) var stats: String = ""
    /// 라이브 프리뷰에서 인물 보정 중인 얼굴 수(0이면 표시 없음). 1초마다 트래커에서 읽는다.
    @Published private(set) var detectedFaceCount = 0
    /// 라이브 얼굴 마커(프리뷰 이미지 정규화 좌표 0~1, 원점 좌하단). 0.25초마다 트래커에서 읽는다. 뷰 좌표 변환은 뷰에서.
    @Published private(set) var faceMarkers: [CGRect] = []
    /// 마커를 계산한 프리뷰 이미지 크기(aspect-fill 배치용). 0이면 3:4로 본다.
    @Published private(set) var faceMarkerImageSize: CGSize = .zero
    /// 원본 보기(프리뷰 길게 누르기) 중인지.
    @Published private(set) var isBypassed = false
    /// 전면 카메라 전환 시 인물 모드 켜기 제안(한 번만).
    @Published var showPortraitSuggestion = false

    // MARK: 내부 상태

    private var services: AppServices?
    private var cameraReady = false
    private var isActive = false
    /// 핀치 시작 시점의 표시 배율(핀치 중에만 값이 있다).
    private var pinchBaseZoom: CGFloat?
    private var lastCapturedID: String?
    private var captureTag = 0
    private var snapshots: [Int: CaptureSnapshot] = [:]
    private var jobs: [PostProcessJob] = []
    private var worker: Task<Void, Never>?
    private var workerBusy = false
    private var thumbnailTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var markerTask: Task<Void, Never>?
    /// 원본 보기를 끝낸 시각(`systemUptime`). 길게 누르기를 뗀 직후 UIKit 탭이 포커스로 들어오지 않게 한다.
    private var bypassEndedAt: TimeInterval = 0
    /// 직전 카메라 방향(전면 전환 감지용).
    private var wasFrontCamera = false
    private let defaults: UserDefaults
    static let portraitSuggestionKey = "portraitSuggestionShown"
    /// 원본 보기를 뗀 뒤 이 시간 안의 탭은 무시한다.
    static let tapSuppressionAfterBypass: TimeInterval = 0.35
    /// 얼굴 마커 갱신 간격.
    static let markerInterval: Duration = .milliseconds(250)
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // CameraService의 메시지(@Published, 메인에서 변경)를 이 객체의 변경으로 전달해 화면이 갱신되게 한다.
        camera.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 카메라 전환(전면 ↔ 후면)이 끝나면: 탭 좌표용 미러 플래그, 얼굴 트래커 초기화(좌표가 뒤바뀜),
        // 설정 재전송(자동 보정 분석을 새 카메라 프레임으로 다시 하도록 버전을 올린다).
        camera.$isFrontCamera
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] front in self?.cameraDidSwitch(front: front) }
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
        startMarkers()
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
        markerTask?.cancel()
        markerTask = nil
        detectedFaceCount = 0
        faceMarkers = []
        setBypass(false)
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
        if services?.portraitModeEnabled != true {
            faceTracker.reset()
            detectedFaceCount = 0
            faceMarkers = []
        }
        pushSettings()
    }

    // MARK: 인물 강도

    /// 강도 칩 표시: 현재 인물 값과 정확히 같은 단계. nil이면 "직접".
    var portraitStrengthSelection: PortraitStrength? { PortraitStrength.matching(params.portrait) }

    /// 강도 칩 선택: 앱 상태(앨범과 공유)에 저장하고 현재 params의 `portrait`만 교체한다(프리셋의 다른 값 유지).
    func selectPortraitStrength(_ strength: PortraitStrength) {
        services?.selectPortraitStrength(strength)
        refreshPortrait()
    }

    /// 앱의 강도·직접 값이 바뀌었을 때(앨범 화면에서 바꾼 경우 포함) 현재 params의 인물 값을 다시 계산한다.
    func refreshPortrait() {
        guard let services else { return }
        let portrait = services.effectivePortrait(base: params.portrait)
        guard portrait != params.portrait else { return }
        params.portrait = portrait
        pushSettings()
    }

    /// 프리셋 선택·동기화: 프리셋의 portrait 위에 칩·직접 값을 덮어쓴다(`AppServices.effectivePortrait`).
    private func apply(choice: PresetChoice, params: PresetParams) {
        var p = params
        if let services { p.portrait = services.effectivePortrait(base: p.portrait) }
        self.choice = choice
        self.params = p
        pushSettings()
    }

    private func updateThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        previewMaxDimension = PreviewQuality.maxDimension(for: thermalState)
        pushSettings()
    }

    /// 현재 params·컨텍스트·해상도를 라이브 파이프라인에 한 번에 넘긴다.
    /// 라이브는 인물 보정 경량 경로(`.live`: 평활 트래커 + 가우시안), 셔터 후처리는 `.full`(capture()의 스냅샷).
    private func pushSettings() {
        guard let services else { return }
        pipeline.update(LiveSettings(params: params,
                                     context: services.pipelineContext(quality: .live, liveTracker: faceTracker),
                                     maxDimension: previewMaxDimension))
    }

    // MARK: 포커스·줌·렌즈

    /// 탭 포커스. 원본 보기 중이거나 방금 끝났으면(길게 누르기를 뗀 탭) 무시하고 false.
    @discardableResult
    func focus(at devicePoint: CGPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isBypassed, now - bypassEndedAt >= Self.tapSuppressionAfterBypass else { return false }
        camera.focus(at: devicePoint)
        return true
    }

    // MARK: 원본 보기 (라이브 전/후)

    /// 프리뷰를 길게 누르는 동안 true: 라이브 파이프라인이 보정을 건너뛰고 원본 프레임을 보여 준다.
    func setBypass(_ on: Bool) {
        guard on != isBypassed else { return }
        isBypassed = on
        pipeline.isBypassed = on
        if !on { bypassEndedAt = ProcessInfo.processInfo.systemUptime }
    }

    /// 현재 표시 배율(0.5× = 초광각, 1× = 광각). 카메라 서비스 값을 그대로 보여 준다.
    var zoomFactor: CGFloat { camera.zoomFactor }
    /// 렌즈 버튼(표시 배율). 초광각·망원이 없는 기기·전면에서는 해당 버튼이 빠진다.
    var lensFactors: [CGFloat] { camera.availableDisplayFactors }
    var isFrontCamera: Bool { camera.isFrontCamera }

    /// 핀치 중: 시작 배율 × 제스처 배율(표시 배율 0.5~10 안으로 카메라 서비스가 자른다).
    func pinchChanged(_ magnification: CGFloat) {
        let base = pinchBaseZoom ?? camera.zoomFactor
        pinchBaseZoom = base
        camera.setZoom(displayFactor: base * magnification)
    }

    func pinchEnded() {
        pinchBaseZoom = nil
    }

    /// 렌즈 버튼(0.5×·1×·2×): 해당 표시 배율로 즉시 전환(가상 기기가 렌즈를 고른다).
    func selectLens(_ displayFactor: CGFloat) {
        camera.setZoom(displayFactor: displayFactor)
    }

    /// 전면 ↔ 후면 전환. 세션 재구성은 카메라 서비스가 세션 큐에서 한다(프리뷰는 잠깐 멈출 수 있다).
    func toggleCamera() {
        pinchBaseZoom = nil
        camera.switchCamera(to: camera.isFrontCamera ? .back : .front)
    }

    private func cameraDidSwitch(front: Bool) {
        preview.isMirrored = front
        faceTracker.reset()
        detectedFaceCount = 0
        faceMarkers = []
        pushSettings()
        let becameFront = front && !wasFrontCamera
        wasFrontCamera = front
        if becameFront, Self.shouldSuggestPortrait(portraitEnabled: services?.portraitModeEnabled ?? false,
                                                   alreadyShown: defaults.bool(forKey: Self.portraitSuggestionKey)) {
            showPortraitSuggestion = true
        }
    }

    // MARK: 셀피 인물 모드 제안

    /// 전면으로 바뀌었을 때 제안할지: 인물 모드가 꺼져 있고 아직 묻지 않았을 때만. 순수 함수.
    nonisolated static func shouldSuggestPortrait(portraitEnabled: Bool, alreadyShown: Bool) -> Bool {
        !portraitEnabled && !alreadyShown
    }

    /// 제안에 답함(켜기/나중에). 어느 쪽이든 다시 묻지 않는다.
    func answerPortraitSuggestion(enable: Bool) {
        defaults.set(true, forKey: Self.portraitSuggestionKey)
        showPortraitSuggestion = false
        if enable { services?.portraitModeEnabled = true }
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

    /// 1초마다 그린 프레임·버린 프레임 수를 갱신한다(실기기 30fps 확인용). 인물 보정 얼굴 수도 여기서 읽는다.
    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let s = self.preview.takeStats()
                let cameraDropped = self.camera.takeDroppedFrameCount()
                let faces = self.faceTracker.faceCount
                if faces != self.detectedFaceCount { self.detectedFaceCount = faces }
                self.stats = "\(s.rendered)fps · 버림 \(s.dropped)+\(cameraDropped) · \(Int(self.previewMaxDimension))px"
            }
        }
    }

    // MARK: 얼굴 마커

    /// 0.25초마다 트래커의 얼굴 사각형을 읽어 마커를 갱신한다(1초 통계 루프와 별도). 1초 넘게 갱신이 없으면 빈 배열.
    private func startMarkers() {
        markerTask?.cancel()
        markerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.markerInterval)
                guard let self, !Task.isCancelled else { return }
                let enabled = self.services?.portraitModeEnabled == true && !self.isBypassed
                let snapshot = self.faceTracker.lastFaceRects
                let rects = enabled ? snapshot.rects : []
                if rects != self.faceMarkers { self.faceMarkers = rects }
                if !rects.isEmpty, snapshot.imageSize != self.faceMarkerImageSize {
                    self.faceMarkerImageSize = snapshot.imageSize
                }
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
