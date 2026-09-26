// R1-S3 앨범 보정 화면 ViewModel 테스트: 사진별 보정값·프리셋 적용·슬라이더, 복원, 일괄 저장 요약, 취소 동작.
import Foundation
import Photos
import XCTest
@testable import TripShot

/// localID로 성공/실패를 정하는 가짜 저장기. PHAsset 경로는 쓰지 않는다.
private final class FakeSaver: PhotoSaving, @unchecked Sendable {
    struct Call: Equatable {
        let localID: String
        let mode: SaveMode
        let params: PresetParams
    }

    enum FakeError: LocalizedError {
        case failed
        var errorDescription: String? { "가짜 실패" }
    }

    let failingIDs: Set<String>
    /// 각 저장 호출 시작 시 불린다(취소 타이밍 제어용).
    var onSave: ((String) async -> Void)?

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.withLock { _calls }
    }

    init(failingIDs: Set<String> = []) {
        self.failingIDs = failingIDs
    }

    func saveNonDestructive(asset: PHAsset, params: PresetParams, horizonAngle: Double?) async throws {
        XCTFail("테스트에서는 PHAsset 경로를 쓰지 않는다")
    }

    func saveAsCopy(asset: PHAsset, params: PresetParams, horizonAngle: Double?) async throws -> String {
        XCTFail("테스트에서는 PHAsset 경로를 쓰지 않는다")
        return ""
    }

    func save(item: PhotoItem, mode: SaveMode, params: PresetParams) async throws {
        if let onSave { await onSave(item.localID) }
        // async 컨텍스트에서는 lock()/unlock() 직접 호출 대신 withLock(동기 클로저)을 쓴다(Swift 6 경고 제거).
        lock.withLock { _calls.append(Call(localID: item.localID, mode: mode, params: params)) }
        if failingIDs.contains(item.localID) { throw FakeError.failed }
    }
}

final class EnhanceViewModelTests: XCTestCase {

    // MARK: 도구

    private func items(_ ids: [String]) -> [PhotoItem] {
        ids.map { PhotoItem(localID: $0, displayName: "사진 \($0)", asset: nil) }
    }

    private func params(exposure: Double) -> PresetParams {
        var p = PresetParams()
        p.exposure = exposure
        return p
    }

    // MARK: 사진별 보정값

    @MainActor
    func testUntouchedPhotosUseDefault() {
        let vm = EnhanceViewModel()
        vm.setItems(items(["a", "b"]))
        let id = UUID()
        let p = params(exposure: 40)
        vm.setDefault(params: p, choice: .preset(id))

        XCTAssertEqual(vm.params(for: "a"), p)
        XCTAssertEqual(vm.params(for: "b"), p)
        XCTAssertEqual(vm.choice(for: "a"), .preset(id))
        XCTAssertEqual(vm.currentParams, p)
        XCTAssertTrue(vm.paramsByID.isEmpty, "기본값은 사진별 딕셔너리에 복사하지 않는다")
    }

    @MainActor
    func testApplyPresetOnlyAffectsCurrentPhoto() {
        let vm = EnhanceViewModel()
        vm.setItems(items(["a", "b"]))
        let presetID = UUID()
        let p = params(exposure: -20)
        vm.applyPreset(p, choice: .preset(presetID))

        XCTAssertEqual(vm.params(for: "a"), p)
        XCTAssertEqual(vm.choice(for: "a"), .preset(presetID))
        XCTAssertEqual(vm.params(for: "b"), PresetParams(), "다른 사진은 기본값 그대로")
        XCTAssertEqual(vm.choice(for: "b"), .auto)

        vm.showNext()
        XCTAssertEqual(vm.currentIndex, 1)
        vm.applyPreset(.identity, choice: .original)
        XCTAssertEqual(vm.params(for: "b"), .identity)
        XCTAssertEqual(vm.params(for: "a"), p, "앞 사진 값은 유지")
    }

    @MainActor
    func testSliderChangeKeepsOtherFieldsAndChoice() {
        let vm = EnhanceViewModel()
        vm.setItems(items(["a", "b"]))
        let presetID = UUID()
        var base = PresetParams()
        base.vibrance = 25
        base.lutName = "mono"
        vm.setDefault(params: base, choice: .preset(presetID))

        var edited = vm.currentParams
        edited.exposure = 30
        vm.updateCurrentParams(edited)

        XCTAssertEqual(vm.params(for: "a").exposure, 30)
        XCTAssertEqual(vm.params(for: "a").vibrance, 25, "슬라이더는 해당 필드만 바꾼다")
        XCTAssertEqual(vm.params(for: "a").lutName, "mono")
        XCTAssertEqual(vm.choice(for: "a"), .preset(presetID), "기준 프리셋 표시는 유지")

        // 이후 기본 프리셋이 바뀌어도 손댄 사진은 영향 없음.
        vm.setDefault(params: .identity, choice: .original)
        XCTAssertEqual(vm.params(for: "a").exposure, 30)
        XCTAssertEqual(vm.choice(for: "a"), .preset(presetID))
        XCTAssertEqual(vm.params(for: "b"), .identity)
    }

    @MainActor
    func testApplyCurrentToAll() {
        let vm = EnhanceViewModel()
        vm.setItems(items(["a", "b", "c"]))
        let p = params(exposure: 55)
        vm.applyPreset(p, choice: .auto)
        vm.applyCurrentToAll()
        for id in ["a", "b", "c"] {
            XCTAssertEqual(vm.params(for: id), p)
            XCTAssertEqual(vm.choice(for: id), .auto)
        }
    }

    @MainActor
    func testRestoredParamsBecomeInitialValueUnlessTouched() {
        let vm = EnhanceViewModel()
        vm.setItems(items(["a", "b"]))
        let restored = AdjustmentPayload(params: params(exposure: 12), horizonAngle: nil)

        XCTAssertTrue(vm.applyRestored(restored, for: "b"))
        XCTAssertEqual(vm.params(for: "b"), restored.params)
        XCTAssertNil(vm.choice(for: "b"), "복원 값은 어느 프리셋도 아님")

        // 사용자가 먼저 바꾼 사진은 늦게 온 복원 값이 덮어쓰지 않는다.
        var edited = vm.currentParams
        edited.contrast = 40
        vm.updateCurrentParams(edited)
        XCTAssertFalse(vm.applyRestored(restored, for: "a"))
        XCTAssertEqual(vm.params(for: "a").contrast, 40)
    }

    func testDecodePayloadChecksFormatIdentifier() throws {
        let payload = AdjustmentPayload(params: params(exposure: -33), horizonAngle: 0.01)
        let data = try JSONEncoder().encode(payload)

        XCTAssertEqual(PhotoImageLoader.decodePayload(formatIdentifier: PhotoSaver.adjustmentFormatIdentifier, data: data), payload)
        XCTAssertNil(PhotoImageLoader.decodePayload(formatIdentifier: "com.other.app", data: data))
        XCTAssertNil(PhotoImageLoader.decodePayload(formatIdentifier: PhotoSaver.adjustmentFormatIdentifier, data: Data("x".utf8)))
    }

    func testIdentityParamsDisableEveryStage() {
        let p = PresetParams.identity
        XCTAssertFalse(p.auto)
        XCTAssertFalse(p.autoHorizon)
        XCTAssertNil(p.lutName)
        XCTAssertFalse(p.portrait.enabled)
        for value in [p.exposure, p.contrast, p.highlights, p.shadows, p.temperature, p.vibrance,
                      p.sharpness, p.clarity, p.lowLight, p.vignette] {
            XCTAssertEqual(value, 0)
        }
    }

    // MARK: 선택·이동

    func testOrderedIDsKeepsOrderAndSkipsMissing() {
        let result = EnhanceViewModel.orderedIDs(requested: ["c", nil, "a", "x", "c", "b"],
                                                 available: ["a", "b", "c"])
        XCTAssertEqual(result.found, ["c", "a", "b"])
        XCTAssertEqual(result.skipped, 2, "nil 식별자와 보관함에 없는 항목")
    }

    @MainActor
    func testNavigationStaysInBounds() {
        let vm = EnhanceViewModel()
        vm.setItems(items(["a", "b"]))
        vm.showPrevious()
        XCTAssertEqual(vm.currentIndex, 0)
        vm.showNext()
        vm.showNext()
        XCTAssertEqual(vm.currentIndex, 1)
        vm.select(index: 5)
        XCTAssertEqual(vm.currentIndex, 1)
        vm.setItems(items(["z"]))
        XCTAssertEqual(vm.currentIndex, 0, "목록을 바꾸면 첫 사진부터")
        XCTAssertEqual(vm.currentItem?.localID, "z")
    }

    // MARK: 저장 요약

    func testSummaryStrings() {
        var single = BatchSaveResult(total: 1)
        single.succeededIDs = ["a"]
        XCTAssertEqual(single.summary, "사진 앱에 저장했습니다.")

        var singleFail = BatchSaveResult(total: 1)
        singleFail.failures = [.init(localID: "a", displayName: "A", message: "권한 없음")]
        XCTAssertEqual(singleFail.summary, "저장 실패: 권한 없음")
        XCTAssertNil(singleFail.failureDetail)

        var batch = BatchSaveResult(total: 4)
        batch.succeededIDs = ["a", "b", "d"]
        batch.failures = [.init(localID: "c", displayName: "C", message: "x")]
        XCTAssertEqual(batch.summary, "3장 저장, 1장 실패")
        XCTAssertEqual(batch.failureDetail, "실패: C")

        var cancelled = BatchSaveResult(total: 5)
        cancelled.succeededIDs = ["a", "b"]
        cancelled.cancelled = true
        XCTAssertEqual(cancelled.remaining, 3)
        XCTAssertEqual(cancelled.summary, "취소됨 — 2장 저장, 0장 실패, 3장 남음")
    }

    func testFailureDetailTruncates() {
        var result = BatchSaveResult(total: 8)
        result.failures = (1...7).map { .init(localID: "\($0)", displayName: "P\($0)", message: "x") }
        XCTAssertEqual(result.failureDetail, "실패: P1, P2, P3, P4, P5 외 2장")
    }

    func testBatchProgressLabel() {
        let progress = BatchProgress(done: 2, total: 8, currentName: "x")
        XCTAssertEqual(progress.label, "2/8")
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(BatchProgress(done: 0, total: 0, currentName: "").fraction, 0)
    }

    // MARK: 저장 실행

    @MainActor
    func testPerformSaveSkipsFailuresAndPassesPerPhotoParams() async {
        let saver = FakeSaver(failingIDs: ["b"])
        let vm = EnhanceViewModel(saver: saver)
        let list = items(["a", "b", "c"])
        vm.setItems(list)
        let p = params(exposure: 70)
        vm.applyPreset(p, choice: .auto)   // "a"만 변경

        let result = await vm.performSave(list, mode: .nonDestructive)

        XCTAssertEqual(result.succeededIDs, ["a", "c"])
        XCTAssertEqual(result.failures.map(\.localID), ["b"])
        XCTAssertEqual(result.failures.first?.message, "가짜 실패")
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.summary, "2장 저장, 1장 실패")
        XCTAssertEqual(saver.calls.map(\.localID), ["a", "b", "c"], "순차 저장")
        XCTAssertEqual(saver.calls.first?.params, p)
        XCTAssertEqual(saver.calls.last?.params, PresetParams())
        XCTAssertTrue(saver.calls.allSatisfy { $0.mode == .nonDestructive })
        XCTAssertNil(vm.progress, "끝나면 진행 상태 해제")
        XCTAssertFalse(vm.isSaving)
    }

    @MainActor
    func testCancelStopsAfterCurrentPhoto() async {
        let saver = FakeSaver()
        let vm = EnhanceViewModel(saver: saver)
        let list = items(["a", "b", "c", "d"])
        vm.setItems(list)
        saver.onSave = { @MainActor id in
            // "b" 저장 도중 취소 → "b"는 끝까지 저장되고 "c"부터 중단. cancelBatch()는 동기(메인 액터)라 await 불필요.
            if id == "b" { vm.cancelBatch() }
        }

        let result = await vm.performSave(list, mode: .copy)

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.succeededIDs, ["a", "b"])
        XCTAssertEqual(result.remaining, 2)
        XCTAssertEqual(saver.calls.map(\.localID), ["a", "b"])
        XCTAssertEqual(result.summary, "취소됨 — 2장 저장, 0장 실패, 2장 남음")
        XCTAssertNil(vm.progress)
    }

    @MainActor
    func testCancelFlagResetsForNextBatch() async {
        let saver = FakeSaver()
        let vm = EnhanceViewModel(saver: saver)
        let list = items(["a", "b"])
        vm.setItems(list)
        saver.onSave = { @MainActor id in if id == "a" { vm.cancelBatch() } }
        let first = await vm.performSave(list, mode: .nonDestructive)
        XCTAssertTrue(first.cancelled)

        saver.onSave = nil
        let second = await vm.performSave(list, mode: .nonDestructive)
        XCTAssertFalse(second.cancelled, "이전 취소 요청이 다음 일괄 저장에 남지 않는다")
        XCTAssertEqual(second.succeeded, 2)
    }

    @MainActor
    func testCancelWithoutBatchIsNoOp() async {
        let saver = FakeSaver()
        let vm = EnhanceViewModel(saver: saver)
        let list = items(["a"])
        vm.setItems(list)
        vm.cancelBatch()   // 저장 중이 아닐 때는 무시
        let result = await vm.performSave(list, mode: .nonDestructive)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.summary, "사진 앱에 저장했습니다.")
    }

    @MainActor
    func testPerformSaveWithoutSaverFailsEveryItem() async {
        let vm = EnhanceViewModel()
        let list = items(["a", "b"])
        let result = await vm.performSave(list, mode: .nonDestructive)
        XCTAssertEqual(result.failed, 2)
        XCTAssertEqual(result.summary, "0장 저장, 2장 실패")
    }
}
