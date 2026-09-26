// 앨범 보정 화면의 상태와 로직: 사진 목록·사진별 보정값(인물 강도 반영)·다운샘플 프리뷰 렌더·프리뷰 얼굴 검출(확대 토글)·저장(단일·일괄)·취소.
import Foundation
import Photos
import SwiftUI
import UIKit

// MARK: - 모델

/// 보정 대상 사진 한 장. 테스트에서는 PHAsset을 만들 수 없으므로 `asset`은 옵셔널이다.
struct PhotoItem: Identifiable {
    let localID: String
    let displayName: String
    let asset: PHAsset?
    var id: String { localID }
}

/// 프리셋 스트립에서 고른 항목.
enum PresetChoice: Equatable {
    /// 보정 없음(원본 그대로).
    case original
    /// 자동 보정 기본값(`PresetParams()`).
    case auto
    /// 저장된 프리셋.
    case preset(UUID)
}

/// 저장 방식.
enum SaveMode: Equatable {
    /// 같은 에셋에 비파괴 편집(사진 앱에서 되돌리기 가능).
    case nonDestructive
    /// 새 에셋으로 사본 저장.
    case copy
}

enum EnhanceSaveError: LocalizedError {
    case assetUnavailable
    case saverUnavailable

    /// 사용자 문구는 `UserMessage`에서 한 곳으로 관리한다.
    var errorDescription: String? { UserMessage.text(for: self) }
}

/// 일괄 저장 진행 상태(UI 표시용).
struct BatchProgress: Equatable {
    var done: Int
    var total: Int
    var currentName: String
    var cancelRequested = false

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var label: String { "\(done)/\(total)" }
}

/// 저장 결과. 실패한 장은 건너뛰고 끝에 요약한다.
struct BatchSaveResult: Equatable {
    struct Failure: Equatable {
        let localID: String
        let displayName: String
        let message: String
    }

    var total: Int
    var succeededIDs: [String] = []
    var failures: [Failure] = []
    /// 사용자가 취소해 남은 장을 처리하지 않았음.
    var cancelled = false

    var succeeded: Int { succeededIDs.count }
    var failed: Int { failures.count }
    var remaining: Int { max(0, total - succeeded - failed) }

    /// 알림 제목 줄. 예: "3장 저장, 1장 실패" / "취소됨 — 2장 저장, 0장 실패, 5장 남음".
    var summary: String {
        if total == 1 && !cancelled {
            if succeeded == 1 { return "사진 앱에 저장했습니다." }
            if let failure = failures.first { return "저장 실패: \(failure.message)" }
        }
        let base = "\(succeeded)장 저장, \(failed)장 실패"
        return cancelled ? "취소됨 — \(base), \(remaining)장 남음" : base
    }

    /// 실패한 사진 이름(최대 5개). 실패가 없거나 한 장짜리 저장이면 nil.
    var failureDetail: String? {
        guard !failures.isEmpty, total > 1 else { return nil }
        let names = failures.prefix(5).map(\.displayName).joined(separator: ", ")
        let more = failures.count > 5 ? " 외 \(failures.count - 5)장" : ""
        return "실패: \(names)\(more)"
    }

    /// 일괄 저장 알림에 덧붙일 첫 번째 실패 사유. 실패가 없거나 한 장짜리 저장(요약에 이미 사유가 있음)이면 nil.
    var firstFailureReason: String? {
        guard total > 1, let first = failures.first else { return nil }
        return "사유: \(first.message)"
    }
}

// MARK: - 저장 추상화

/// 사진 저장 추상화. `PhotoSaver`가 채택하고, 테스트는 가짜 구현을 주입한다.
/// ViewModel은 `save(item:mode:params:)`만 부른다. 기본 구현은 `item.asset`으로 위 두 함수를 호출하고,
/// 가짜 구현은 이 함수를 직접 구현해 localID로 성공/실패를 정한다(테스트에서 PHAsset을 만들 수 없으므로).
protocol PhotoSaving: AnyObject {
    func saveNonDestructive(asset: PHAsset, params: PresetParams, horizonAngle: Double?) async throws
    func saveAsCopy(asset: PHAsset, params: PresetParams, horizonAngle: Double?) async throws -> String
    func save(item: PhotoItem, mode: SaveMode, params: PresetParams) async throws
    /// 파이프라인 컨텍스트(인물 모드 hook 포함)를 지정하는 저장. 프리뷰와 같은 컨텍스트로 저장해 "보이는 대로 저장"을 지킨다.
    func save(item: PhotoItem, mode: SaveMode, params: PresetParams, context: PipelineContext?) async throws
}

extension PhotoSaving {
    func save(item: PhotoItem, mode: SaveMode, params: PresetParams) async throws {
        guard let asset = item.asset else { throw EnhanceSaveError.assetUnavailable }
        switch mode {
        case .nonDestructive:
            try await saveNonDestructive(asset: asset, params: params, horizonAngle: nil)
        case .copy:
            _ = try await saveAsCopy(asset: asset, params: params, horizonAngle: nil)
        }
    }

    /// 기본 구현: 컨텍스트를 받지 못하는 저장기(테스트 대역 등)는 컨텍스트 없이 저장한다.
    func save(item: PhotoItem, mode: SaveMode, params: PresetParams, context: PipelineContext?) async throws {
        try await save(item: item, mode: mode, params: params)
    }
}

extension PhotoSaver: PhotoSaving {
    /// PhotoSaver는 컨텍스트를 렌더에 그대로 넘긴다(nil이면 렌더러 공유 컨텍스트).
    func save(item: PhotoItem, mode: SaveMode, params: PresetParams, context: PipelineContext?) async throws {
        guard let asset = item.asset else { throw EnhanceSaveError.assetUnavailable }
        switch mode {
        case .nonDestructive:
            try await saveNonDestructive(asset: asset, params: params, horizonAngle: nil, context: context)
        case .copy:
            _ = try await saveAsCopy(asset: asset, params: params, horizonAngle: nil, context: context)
        }
    }
}

extension PresetParams {
    /// "원본" 항목: 모든 단계가 무적용(파이프라인 출력 = 입력).
    static var identity: PresetParams {
        var p = PresetParams()
        p.auto = false
        p.exposure = 0
        p.contrast = 0
        p.highlights = 0
        p.shadows = 0
        p.temperature = 0
        p.vibrance = 0
        p.sharpness = 0
        p.clarity = 0
        p.lowLight = 0
        p.lutName = nil
        p.vignette = 0
        p.autoHorizon = false
        // "원본"은 인물 모드 스위치가 켜져 있어도 인물 보정을 하지 않는다(촬영 후처리도 identity면 건너뛴다).
        p.portrait.enabled = false
        return p
    }
}

// MARK: - ViewModel

/// 앨범 보정 화면 상태. UI는 이 객체를 그리기만 한다.
///
/// 메모리 원칙: 풀해상도 이미지를 절대 보관하지 않는다. 프리뷰는 PhotoKit에서 긴 변 1024px로 받은 이미지만 쓰고
/// (최대 10장 캐시), 저장은 `PhotoSaver`가 원본 파일에서 직접 읽어 한 장씩 렌더한다.
@MainActor
final class EnhanceViewModel: ObservableObject {
    /// 프리뷰 긴 변(픽셀). 렌더러의 공간 반경 기준 해상도와 같다.
    static let previewDimension: CGFloat = 1024
    /// 슬라이더 변경 후 렌더까지 기다리는 시간.
    static let renderDebounceNanoseconds: UInt64 = 80_000_000
    static let sourceCacheLimit = 10

    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var currentIndex = 0
    /// 사진별로 사용자가 정한(또는 이전 편집에서 복원한) 보정값. 없으면 `defaultParams`를 쓴다.
    @Published private(set) var paramsByID: [String: PresetParams] = [:]
    /// 사진별 스트립 선택 표시. 값이 없고 `paramsByID`도 없으면 기본 선택, `paramsByID`만 있으면(복원 값) 선택 없음.
    @Published private(set) var choiceByID: [String: PresetChoice] = [:]
    /// 아직 손대지 않은 사진에 쓰는 기본값(앱의 선택 프리셋).
    @Published private(set) var defaultParams = PresetParams()
    @Published private(set) var defaultChoice: PresetChoice? = .auto
    /// 보정 적용 프리뷰(긴 변 ≤ 1024).
    @Published private(set) var previewImage: UIImage?
    /// 보정 전 다운샘플 원본(전/후 비교용).
    @Published private(set) var originalImage: UIImage?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isRendering = false
    @Published private(set) var previewError: String?
    /// 저장 진행 중이면 non-nil. 이 동안 편집 UI는 비활성.
    @Published private(set) var progress: BatchProgress?
    /// 이번 세션에서 비파괴 저장에 성공한 사진(썸네일 표시용).
    @Published private(set) var savedIDs: Set<String> = []
    @Published var alertMessage: String?
    /// 현재 사진 프리뷰(원본 다운샘플, 긴 변 ≤ 1024)의 얼굴 사각형. 정규화 좌표(0~1, 원점 좌하단), 넓이 큰 순.
    /// `wantsPreviewFaces`가 true일 때만 검출한다(얼굴 확대 토글용, R1-S8b U3).
    @Published private(set) var previewFaceRects: [CGRect] = []
    /// 프리뷰 얼굴 검출을 할지(인물 모드가 켜져 있을 때 뷰가 true로). 켜지는 순간 현재 사진을 검출한다.
    var wantsPreviewFaces = false {
        didSet {
            guard wantsPreviewFaces != oldValue else { return }
            if wantsPreviewFaces { detectPreviewFacesIfNeeded() } else { previewFaceRects = [] }
        }
    }

    private let renderer: EnhanceRenderer?
    private let saver: PhotoSaving?
    private let contextProvider: @MainActor () -> PipelineContext
    /// 프리셋 인물 값 위에 강도 칩·직접 값을 덮어쓰는 규칙(`AppServices.effectivePortrait`). 기본은 그대로.
    private let portraitOverride: @MainActor (PortraitParams) -> PortraitParams
    /// 프리뷰 얼굴 검출기(확대 토글). nil이면 검출하지 않는다(테스트).
    private let faceDetector: FaceDetector?
    /// 사진별 프리뷰 얼굴(정규화). 소스 캐시와 함께 비운다.
    private var faceRectsByID: [String: [CGRect]] = [:]
    private var faceTask: Task<Void, Never>?

    /// 사진별 다운샘플 원본 캐시(최대 10장, init에서 설정). 풀해상도는 넣지 않는다.
    private let sourceCache = NSCache<NSString, UIImage>()
    /// 프리뷰 원본으로 받을 버전. 이전 TripShot 편집이 있으면 `.unadjusted`(저장도 원본에서 다시 렌더하므로).
    private var sourceVersion: [String: PHImageRequestOptionsVersion] = [:]
    /// 이전 편집 조회를 이미 시작한 사진.
    private var restoreChecked: Set<String> = []
    /// 사용자가 직접 값을 바꾼 사진. 늦게 도착한 복원 값이 덮어쓰지 않게 한다.
    private var touchedIDs: Set<String> = []

    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var restoreTasks: [String: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var cancelRequested = false

    init(renderer: EnhanceRenderer? = nil,
         saver: PhotoSaving? = nil,
         contextProvider: @escaping @MainActor () -> PipelineContext = { PipelineContext() },
         portraitOverride: @escaping @MainActor (PortraitParams) -> PortraitParams = { $0 },
         faceDetector: FaceDetector? = nil) {
        self.renderer = renderer
        self.saver = saver
        self.contextProvider = contextProvider
        self.portraitOverride = portraitOverride
        self.faceDetector = faceDetector
        sourceCache.countLimit = Self.sourceCacheLimit
    }

    /// 앱 서비스 연결: 공유 렌더러·PhotoSaver, 렌더마다 인물 모드 스위치를 반영한 컨텍스트.
    convenience init(services: AppServices) {
        self.init(renderer: services.renderer,
                  saver: services.photoSaver,
                  contextProvider: { [weak services] in services?.pipelineContext() ?? PipelineContext() },
                  portraitOverride: { [weak services] base in services?.effectivePortrait(base: base) ?? base },
                  faceDetector: services.faceDetector)
    }

    // MARK: 조회

    var currentItem: PhotoItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var isSaving: Bool { progress != nil }
    var hasPrevious: Bool { currentIndex > 0 }
    var hasNext: Bool { currentIndex + 1 < items.count }

    func params(for id: String) -> PresetParams { paramsByID[id] ?? defaultParams }

    /// 스트립에 표시할 선택 항목. 손대지 않은 사진은 기본 선택, 슬라이더로 바꿔도 기준 프리셋은 유지,
    /// 이전 편집에서 복원한 값은 nil(어느 항목도 아님).
    func choice(for id: String) -> PresetChoice? {
        if let stored = choiceByID[id] { return stored }
        return paramsByID[id] == nil ? defaultChoice : nil
    }

    var currentParams: PresetParams { currentItem.map { params(for: $0.localID) } ?? defaultParams }
    var currentChoice: PresetChoice? { currentItem.flatMap { choice(for: $0.localID) } }

    // MARK: 사진 선택

    /// PhotosPicker 결과(`itemIdentifier`, 순서 유지)로 목록을 만든다.
    /// 식별자가 없는 항목·보관함에서 찾지 못한 항목(제한된 접근 등)은 건너뛰고 알린다.
    func loadSelection(identifiers: [String?]) async {
        guard await Permissions.requestPhotoLibrary() else {
            setItems([])
            alertMessage = UserMessage.photoPermission
            return
        }
        let wanted = identifiers.compactMap { $0 }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: wanted, options: nil)
        var byID: [String: PHAsset] = [:]
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            if asset.mediaType == .image { byID[asset.localIdentifier] = asset }
        }
        let ordered = Self.orderedIDs(requested: identifiers, available: Set(byID.keys))
        let newItems: [PhotoItem] = ordered.found.enumerated().compactMap { offset, id in
            guard let asset = byID[id] else { return nil }
            return PhotoItem(localID: id, displayName: Self.displayName(for: asset, index: offset), asset: asset)
        }
        setItems(newItems)
        if ordered.skipped > 0 {
            alertMessage = "\(ordered.skipped)장은 불러오지 못해 건너뛰었습니다. (공유 앨범·제한된 사진 접근 등)"
        }
    }

    /// 요청 순서를 유지하며 찾은 식별자만 남긴다(중복 제거). 순수 함수.
    nonisolated static func orderedIDs(requested: [String?], available: Set<String>) -> (found: [String], skipped: Int) {
        var found: [String] = []
        var seen: Set<String> = []
        var skipped = 0
        for id in requested {
            guard let id, available.contains(id) else { skipped += 1; continue }
            if seen.insert(id).inserted { found.append(id) }
        }
        return (found, skipped)
    }

    private static func displayName(for asset: PHAsset, index: Int) -> String {
        guard let date = asset.creationDate else { return "사진 \(index + 1)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 HH:mm"
        return formatter.string(from: date)
    }

    /// 목록 교체. 진행 중인 로드·렌더를 멈추고 첫 사진을 표시한다. 사진별 값은 식별자 기준으로 유지된다.
    func setItems(_ newItems: [PhotoItem]) {
        loadTask?.cancel()
        renderTask?.cancel()
        let keep = Set(newItems.map(\.localID))
        for (id, task) in restoreTasks where !keep.contains(id) {
            task.cancel()
            restoreTasks[id] = nil
            restoreChecked.remove(id)
        }
        items = newItems
        currentIndex = 0
        showCurrent()
    }

    /// 사용자가 이번 선택에서 직접 바꾼 보정값이 있는지(선택 해제 확인 알림용).
    /// 이전 편집에서 복원만 된 값(`applyRestored`)은 사진 보관함에 이미 있으므로 포함하지 않는다.
    var hasAdjustments: Bool { !touchedIDs.isEmpty }

    /// 선택 해제: 사진 목록과 사진별 보정값·선택 표시·복원 상태를 모두 비우고 초기 화면(사진 선택 전)으로 돌아간다.
    /// 저장 중에는 무시한다. 앱의 기본 프리셋(`defaultParams`)은 앱 상태이므로 그대로 둔다.
    func clearSelection() {
        guard !isSaving else { return }
        for task in restoreTasks.values { task.cancel() }
        restoreTasks = [:]
        setItems([])
        paramsByID = [:]
        choiceByID = [:]
        touchedIDs = []
        restoreChecked = []
        sourceVersion = [:]
        savedIDs = []
        sourceCache.removeAllObjects()
        faceRectsByID = [:]
        previewFaceRects = []
    }

    // MARK: 이동

    func select(index: Int) {
        guard items.indices.contains(index), index != currentIndex, !isSaving else { return }
        currentIndex = index
        showCurrent()
    }

    func showNext() { select(index: currentIndex + 1) }
    func showPrevious() { select(index: currentIndex - 1) }

    // MARK: 보정값

    /// 손대지 않은 사진에 쓸 기본값(앱의 선택 프리셋). 현재 사진이 기본값을 쓰고 있으면 다시 렌더한다.
    /// 인물 값은 강도 칩·직접 값을 덮어쓴다(`portraitOverride`) — 인물 모드가 켜져 있으면 칩이 프리셋보다 우선.
    func setDefault(params: PresetParams, choice: PresetChoice?) {
        var params = params
        params.portrait = portraitOverride(params.portrait)
        guard params != defaultParams || choice != defaultChoice else { return }
        defaultParams = params
        defaultChoice = choice
        if let id = currentItem?.localID, paramsByID[id] == nil {
            scheduleRender(debounce: false)
        }
    }

    /// 프리셋 스트립 선택을 현재 사진에 적용한다.
    /// 인물 값은 강도 칩·직접 값을 덮어쓴다(`portraitOverride`).
    func applyPreset(_ params: PresetParams, choice: PresetChoice) {
        guard let id = currentItem?.localID, !isSaving else { return }
        var params = params
        params.portrait = portraitOverride(params.portrait)
        paramsByID[id] = params
        choiceByID[id] = choice
        touchedIDs.insert(id)
        scheduleRender(debounce: false)
    }

    /// 슬라이더 변경. 기준 프리셋 선택 표시는 유지한다. 렌더는 디바운스.
    func updateCurrentParams(_ params: PresetParams) {
        guard let id = currentItem?.localID, !isSaving else { return }
        guard params != self.params(for: id) else { return }
        // 처음 손대는 사진이면 지금 보이는 기본 선택을 고정한다(이후 기본 프리셋이 바뀌어도 표시 유지).
        if choiceByID[id] == nil, paramsByID[id] == nil, let current = defaultChoice {
            choiceByID[id] = current
        }
        paramsByID[id] = params
        touchedIDs.insert(id)
        scheduleRender(debounce: true)
    }

    /// 강도 칩 선택 등: 현재 사진의 `portrait`만 바꾼다(프리셋의 다른 값 유지). 렌더는 즉시.
    func updateCurrentPortrait(_ portrait: PortraitParams) {
        guard let id = currentItem?.localID, !isSaving else { return }
        var params = self.params(for: id)
        guard params.portrait != portrait else { return }
        params.portrait = portrait
        updateCurrentParams(params)
        scheduleRender(debounce: false)
    }

    /// 현재 사진의 보정값을 목록의 모든 사진에 적용한다(일괄 저장 전에 사용).
    func applyCurrentToAll() {
        guard let id = currentItem?.localID, !isSaving else { return }
        let params = self.params(for: id)
        let choice = self.choice(for: id)
        for item in items {
            paramsByID[item.localID] = params
            choiceByID[item.localID] = choice
            touchedIDs.insert(item.localID)
        }
    }

    /// 이전 TripShot 편집에서 복원한 값을 초기값으로 넣는다. 사용자가 이미 값을 바꿨으면 무시하고 false.
    @discardableResult
    func applyRestored(_ payload: AdjustmentPayload, for id: String) -> Bool {
        guard !touchedIDs.contains(id) else { return false }
        paramsByID[id] = payload.params
        choiceByID[id] = nil
        return true
    }

    // MARK: 프리뷰

    /// 현재 사진을 표시한다: 캐시에 원본이 있으면 바로 렌더, 없으면 PhotoKit에서 다운샘플로 받는다.
    /// 처음 보는 사진이면 이전 편집 기록 조회도 비동기로 시작한다.
    func showCurrent() {
        loadTask?.cancel()
        renderTask?.cancel()
        previewError = nil
        isRendering = false
        guard let item = currentItem else {
            previewImage = nil
            originalImage = nil
            isLoadingPreview = false
            return
        }
        let id = item.localID
        startRestoreIfNeeded(item)
        faceTask?.cancel()
        previewFaceRects = faceRectsByID[id] ?? []

        if let cached = sourceCache.object(forKey: id as NSString) {
            isLoadingPreview = false
            originalImage = cached
            previewImage = nil
            scheduleRender(debounce: false)
            detectPreviewFacesIfNeeded()
            return
        }

        previewImage = nil
        originalImage = nil
        guard let asset = item.asset else {
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true
        let version = sourceVersion[id] ?? .current
        let size = CGSize(width: Self.previewDimension, height: Self.previewDimension)
        loadTask = Task { [weak self] in
            let image = await PhotoImageLoader.image(for: asset, targetSize: size, version: version)
            guard let self, !Task.isCancelled, self.currentItem?.localID == id else { return }
            self.isLoadingPreview = false
            guard let image else {
                self.previewError = "사진을 불러오지 못했습니다."
                return
            }
            self.sourceCache.setObject(image, forKey: id as NSString)
            self.originalImage = image
            self.scheduleRender(debounce: false)
            self.detectPreviewFacesIfNeeded()
        }
    }

    // MARK: 프리뷰 얼굴 (확대 토글)

    /// 현재 사진의 프리뷰 원본에서 얼굴을 한 번 검출한다(사진별 캐시). `wantsPreviewFaces`가 false거나 검출기가 없으면 아무 일 없음.
    /// 이전 편집이 복원돼 소스가 `.unadjusted`로 바뀌어도 얼굴 위치는 같다고 보고 캐시를 유지한다.
    func detectPreviewFacesIfNeeded() {
        guard wantsPreviewFaces, let detector = faceDetector, let item = currentItem else { return }
        let id = item.localID
        if let cached = faceRectsByID[id] {
            previewFaceRects = cached
            return
        }
        guard let source = sourceCache.object(forKey: id as NSString) else { return }
        faceTask?.cancel()
        faceTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) { () -> [CGRect] in
                Self.detectFaceRects(in: source, detector: detector)
            }
            let rects = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.faceRectsByID[id] = rects
            if self.currentItem?.localID == id { self.previewFaceRects = rects }
        }
    }

    /// 프리뷰 UIImage(방향 반영)에서 얼굴 → 정규화 사각형(넓이 큰 순). 메인 밖에서 부른다.
    nonisolated static func detectFaceRects(in image: UIImage, detector: FaceDetector) -> [CGRect] {
        guard let source = EnhanceRenderer.ciImage(from: image) else { return [] }
        let upright = source.oriented(EnhanceRenderer.cgOrientation(image.imageOrientation))
        let faces = detector.detect(in: upright, detectionMaxDimension: FaceDetector.defaultDetectionMaxDimension)
        return SmoothedFaceTracker.normalizedRects(faces, in: upright.extent)
    }

    /// 현재 사진의 프리뷰를 다시 렌더한다. 이전 렌더는 취소한다(동시에 여러 렌더를 걸지 않음).
    /// 무거운 렌더는 `Task.detached`에서, 결과 반영은 메인 액터에서.
    func scheduleRender(debounce: Bool = true) {
        renderTask?.cancel()
        guard let item = currentItem, let renderer,
              let source = sourceCache.object(forKey: item.localID as NSString) else {
            isRendering = false
            return
        }
        let id = item.localID
        let params = self.params(for: id)
        // 프리뷰 렌더: 배경 분리를 `.balanced`로(저장 경로는 이 플래그가 false라 `.accurate`).
        var context = contextProvider()
        context.isPreview = true
        let dimension = Self.previewDimension
        let delay = debounce ? Self.renderDebounceNanoseconds : 0
        isRendering = true
        renderTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            let job = Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard !Task.isCancelled else { return nil }
                return renderer.previewImage(from: source, params: params, maxDimension: dimension, context: context)
            }
            let rendered = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            guard let self, !Task.isCancelled, self.currentItem?.localID == id else { return }
            self.isRendering = false
            if let rendered {
                self.previewImage = rendered
            } else {
                self.previewImage = nil
                self.previewError = "보정 프리뷰를 만들지 못했습니다."
            }
        }
    }

    private func startRestoreIfNeeded(_ item: PhotoItem) {
        let id = item.localID
        guard let asset = item.asset, !restoreChecked.contains(id) else { return }
        restoreChecked.insert(id)
        restoreTasks[id] = Task { [weak self] in
            let payload = await PhotoImageLoader.previousAdjustment(for: asset)
            guard let self, !Task.isCancelled else { return }
            self.restoreTasks[id] = nil
            guard let payload else { return }
            // 이전 TripShot 편집이 있는 사진: 저장은 원본에서 다시 렌더하므로 프리뷰 원본도 편집 전 버전으로 바꾼다.
            self.sourceVersion[id] = .unadjusted
            self.sourceCache.removeObject(forKey: id as NSString)
            self.applyRestored(payload, for: id)
            if self.currentItem?.localID == id { self.showCurrent() }
        }
    }

    // MARK: 저장

    /// UI 진입점. `all`이면 목록 전체, 아니면 현재 사진만. 끝나면 요약 알림.
    func save(mode: SaveMode, all: Bool) {
        guard !isSaving else { return }
        let targets: [PhotoItem] = all ? items : (currentItem.map { [$0] } ?? [])
        guard !targets.isEmpty else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.performSave(targets, mode: mode)
            self.finishSave(result, mode: mode)
        }
    }

    /// 순차 저장(한 번에 한 장). 실패한 장은 건너뛴다. 취소 요청 시 **현재 장을 끝낸 뒤** 중단한다.
    /// 각 장의 저장은 분리된 Task에서 돌려 취소가 저장 도중에 끼어들지 않게 한다(PhotoKit 트랜잭션은 원자적).
    func performSave(_ targets: [PhotoItem], mode: SaveMode) async -> BatchSaveResult {
        var result = BatchSaveResult(total: targets.count)
        guard let first = targets.first else { return result }
        guard let saver else {
            let message = UserMessage.text(for: EnhanceSaveError.saverUnavailable)
            result.failures = targets.map {
                BatchSaveResult.Failure(localID: $0.localID, displayName: $0.displayName, message: message)
            }
            return result
        }

        // 저장 중에는 프리뷰 렌더를 멈춰 렌더러 잠금 경쟁·메모리 사용을 줄인다.
        renderTask?.cancel()
        isRendering = false
        cancelRequested = false
        progress = BatchProgress(done: 0, total: targets.count, currentName: first.displayName)

        for item in targets {
            if cancelRequested || Task.isCancelled {
                result.cancelled = true
                break
            }
            progress?.currentName = item.displayName
            let params = self.params(for: item.localID)
            // 프리뷰와 같은 컨텍스트(인물 모드 스위치 반영, `.full` 품질)로 저장한다. 장마다 새로 받아
            // 저장 도중 스위치를 바꾸면 다음 장부터 반영된다.
            let context = contextProvider()
            let job = Task.detached(priority: .userInitiated) {
                try await saver.save(item: item, mode: mode, params: params, context: context)
            }
            do {
                try await job.value
                result.succeededIDs.append(item.localID)
            } catch {
                let message = UserMessage.text(for: error)
                result.failures.append(.init(localID: item.localID, displayName: item.displayName, message: message))
            }
            progress?.done += 1
        }

        progress = nil
        cancelRequested = false
        return result
    }

    /// 일괄 저장 취소 요청. 진행 중인 장은 끝까지 저장된다.
    func cancelBatch() {
        guard progress != nil else { return }
        cancelRequested = true
        progress?.cancelRequested = true
    }

    private func finishSave(_ result: BatchSaveResult, mode: SaveMode) {
        saveTask = nil
        var message = result.summary
        if let detail = result.failureDetail { message += "\n" + detail }
        if let reason = result.firstFailureReason { message += "\n" + reason }
        alertMessage = message

        guard mode == .nonDestructive else {
            // 사본 저장은 원본 에셋이 그대로라 프리뷰를 바꿀 필요가 없다. 멈췄던 렌더만 재개.
            scheduleRender(debounce: false)
            return
        }
        // 비파괴 저장된 사진은 이제 "편집됨": 다음 프리뷰·저장은 편집 전 원본 기준이므로 원본을 다시 받는다.
        for id in result.succeededIDs {
            sourceVersion[id] = .unadjusted
            sourceCache.removeObject(forKey: id as NSString)
            savedIDs.insert(id)
            restoreChecked.insert(id)   // 방금 저장한 값이 곧 복원 값이므로 다시 조회하지 않는다
        }
        if let id = currentItem?.localID, result.succeededIDs.contains(id) {
            showCurrent()
        } else {
            scheduleRender(debounce: false)
        }
    }
}
