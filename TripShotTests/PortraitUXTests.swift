// R1-S8b 인물 모드 기능·UX 테스트: 강도 칩 값·일치 판정, 칩/직접/프리셋 우선 규칙, 배경 흐림 합성, 라이브 원본 보기, 마커·확대 좌표 변환, 프리셋 JSON 호환.
import CoreGraphics
import CoreImage
import CoreVideo
import XCTest
@testable import TripShot

final class PortraitUXTests: XCTestCase {

    // MARK: 공용 도구

    private static let ctx = CIContext(options: [
        .workingColorSpace: EnhanceRenderer.workingColorSpace,
        .cacheIntermediates: false,
    ])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 두 회색(0.2/0.8)이 `cell` 픽셀 간격으로 번갈아 나오는 체스판.
    private func checkerboard(size: CGFloat, cell: CGFloat) -> CIImage {
        let f = CIFilter(name: "CICheckerboardGenerator")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        f.setValue(CIColor(red: 0.2, green: 0.2, blue: 0.2), forKey: "inputColor0")
        f.setValue(CIColor(red: 0.8, green: 0.8, blue: 0.8), forKey: "inputColor1")
        f.setValue(cell, forKey: "inputWidth")
        f.setValue(1.0, forKey: "inputSharpness")
        return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// RGBA8 바이트(행 0 = 이미지 위쪽).
    private func pixels(_ image: CIImage) -> [UInt8] {
        let rect = image.extent
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            Self.ctx.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 4, bounds: rect,
                            format: .RGBA8, colorSpace: Self.sRGB)
        }
        return bytes
    }

    /// CIImage 좌표(원점 좌하단)의 (x, y) 픽셀 R 값(0~255).
    private func red(_ bytes: [UInt8], width: Int, height: Int, x: Int, y: Int) -> Int {
        Int(bytes[((height - 1 - y) * width + x) * 4])
    }

    /// 가운데 흰 사각형(사람) + 나머지 검정(배경) 마스크.
    private func centerSquareMask(size: CGFloat, inset: CGFloat) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: full)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: full.insetBy(dx: inset, dy: inset))
        return white.composited(over: black)
    }

    // MARK: F1 강도 값

    func testStrengthValues() {
        let n = PortraitStrength.natural.params
        XCTAssertEqual([n.skinSmooth, n.faceSlim, n.eyeEnlarge, n.teethWhiten, n.skinBrighten], [20, 10, 0, 10, 0])
        let m = PortraitStrength.normal.params
        XCTAssertEqual([m.skinSmooth, m.faceSlim, m.eyeEnlarge, m.teethWhiten, m.skinBrighten], [40, 20, 10, 20, 10])
        let s = PortraitStrength.strong.params
        XCTAssertEqual([s.skinSmooth, s.faceSlim, s.eyeEnlarge, s.teethWhiten, s.skinBrighten], [60, 35, 20, 30, 20])
        for strength in PortraitStrength.allCases {
            XCTAssertTrue(strength.params.enabled)
            XCTAssertEqual(strength.params.backgroundBlur, 0, "배경 흐림은 칩에 묶지 않는다")
        }
        XCTAssertEqual(PortraitStrength.allCases.map(\.title), ["자연", "보통", "강함"])
    }

    func testStrengthMatching() {
        for strength in PortraitStrength.allCases {
            XCTAssertEqual(PortraitStrength.matching(strength.params), strength)
        }
        var p = PortraitStrength.normal.params
        p.backgroundBlur = 70
        p.enabled = false
        XCTAssertEqual(PortraitStrength.matching(p), .normal, "배경 흐림·enabled는 비교하지 않는다")
        p.skinSmooth = 41
        XCTAssertNil(PortraitStrength.matching(p), "하나라도 다르면 직접")
        XCTAssertNil(PortraitStrength.matching(PortraitParams()), "기본값(피부 30)은 어느 단계도 아니다")
    }

    // MARK: F1 우선 규칙

    func testEffectivePortraitUsesStrengthOverPreset() {
        var preset = PortraitParams()
        preset.skinSmooth = 90
        preset.faceSlim = 90
        preset.backgroundBlur = 40
        let out = PortraitStrength.effective(base: preset, strength: .natural, custom: nil)
        XCTAssertEqual(out.skinSmooth, 20)
        XCTAssertEqual(out.faceSlim, 10)
        XCTAssertEqual(out.backgroundBlur, 40, "칩에 없는 배경 흐림은 프리셋 값 유지")
        XCTAssertTrue(out.enabled)
    }

    func testEffectivePortraitCustomWinsOverStrength() {
        var custom = PortraitParams()
        custom.skinSmooth = 77
        custom.backgroundBlur = 15
        var base = PortraitParams()
        base.backgroundBlur = 40
        let out = PortraitStrength.effective(base: base, strength: .strong, custom: custom)
        XCTAssertEqual(out.skinSmooth, 77)
        // Background blur is a per-photo value; it comes from base, not from the custom values.
        XCTAssertEqual(out.backgroundBlur, 40)
    }

    func testEffectivePortraitKeepsOriginalDisabled() {
        // "원본"(identity)은 portrait.enabled = false → 인물 값을 덮어쓰지 않아 여전히 identity.
        let identity = PresetParams.identity
        let out = PortraitStrength.effective(base: identity.portrait, strength: .strong, custom: nil)
        XCTAssertEqual(out, identity.portrait)
    }

    @MainActor
    func testAppServicesStrengthPersistsAndClearsCustom() {
        let suite = "PortraitUXTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let services = AppServices(defaults: defaults)
        XCTAssertEqual(services.portraitStrength, .normal, "기본은 보통")
        XCTAssertNil(services.customPortrait)

        var custom = PortraitParams()
        custom.skinSmooth = 55
        services.customPortrait = custom
        XCTAssertEqual(services.effectivePortrait(base: PortraitParams()).skinSmooth, 55)

        services.selectPortraitStrength(.strong)
        XCTAssertNil(services.customPortrait, "칩 선택 시 직접 값 해제")
        XCTAssertEqual(services.effectivePortrait(base: PortraitParams()).skinSmooth, 60)

        let reloaded = AppServices(defaults: defaults)
        XCTAssertEqual(reloaded.portraitStrength, .strong, "마지막 선택 기억")
        XCTAssertNil(reloaded.customPortrait)
    }

    @MainActor
    func testEnhanceViewModelAppliesPortraitOverrideToPresetAndDefault() {
        let vm = EnhanceViewModel(portraitOverride: { base in
            PortraitStrength.effective(base: base, strength: .strong, custom: nil)
        })
        var preset = PresetParams()
        preset.exposure = 30
        preset.portrait.skinSmooth = 5
        vm.setDefault(params: preset, choice: .auto)
        XCTAssertEqual(vm.defaultParams.portrait.skinSmooth, 60, "칩 값이 프리셋 인물 값보다 우선")
        XCTAssertEqual(vm.defaultParams.exposure, 30, "프리셋의 다른 값 유지")

        vm.setItems([PhotoItem(localID: "a", displayName: "a", asset: nil)])
        vm.applyPreset(preset, choice: .auto)
        XCTAssertEqual(vm.currentParams.portrait.skinSmooth, 60)

        var p = PortraitStrength.natural.params
        p.backgroundBlur = 30
        vm.updateCurrentPortrait(p)
        XCTAssertEqual(vm.currentParams.portrait, p)
        XCTAssertEqual(vm.currentParams.exposure, 30, "칩 선택은 portrait만 교체")

        // 원본은 그대로 identity.
        vm.applyPreset(.identity, choice: .original)
        XCTAssertEqual(vm.currentParams, .identity)
    }

    // MARK: F5 배경 흐림 — 직렬화

    func testBackgroundBlurDecodesMissingKeyAsZero() throws {
        let json = #"{"enabled":true,"skinSmooth":30,"faceSlim":20,"eyeEnlarge":0,"teethWhiten":0}"#
        let p = try JSONDecoder().decode(PortraitParams.self, from: Data(json.utf8))
        XCTAssertEqual(p.backgroundBlur, 0)
        var q = PortraitParams()
        q.backgroundBlur = 42
        let round = try JSONDecoder().decode(PortraitParams.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(round.backgroundBlur, 42)
    }

    func testBackgroundBlurSliderKind() {
        XCTAssertEqual(AdjustmentKind.portrait.last, .backgroundBlur, "인물 목록 마지막")
        XCTAssertEqual(AdjustmentKind.backgroundBlur.title, "배경 흐림")
        XCTAssertEqual(AdjustmentKind.backgroundBlur.systemImage, "person.crop.rectangle")
        XCTAssertEqual(AdjustmentKind.backgroundBlur.range, 0...100)
        var p = PresetParams()
        p[keyPath: AdjustmentKind.backgroundBlur.keyPath] = 33
        XCTAssertEqual(p.portrait.backgroundBlur, 33)
    }

    func testPortraitStageActiveWithBlurOnly() {
        var p = PortraitParams()
        p.skinSmooth = 0; p.faceSlim = 0; p.eyeEnlarge = 0; p.teethWhiten = 0; p.skinBrighten = 0
        XCTAssertFalse(PortraitStage.isActive(p))
        p.backgroundBlur = 10
        XCTAssertTrue(PortraitStage.isActive(p))
        XCTAssertFalse(PortraitStage.isFaceActive(p), "배경 흐림만이면 얼굴 검출 불필요(라이브 트래커도 돌지 않음)")
    }

    // MARK: F5 배경 흐림 — 합성

    func testBackgroundBlurZeroStrengthIsIdentity() {
        let input = checkerboard(size: 64, cell: 4)
        let mask = centerSquareMask(size: 64, inset: 16)
        XCTAssertTrue(BackgroundBlur.apply(input, personMask: mask, strength: 0) === input)
        XCTAssertTrue(BackgroundBlur.apply(input, personMask: mask, strength: -1) === input)
    }

    func testProcessWithoutPersonMaskReturnsInput() {
        // 얼굴 없음 + 분리 결과 nil(사람 없음) → 입력 그대로.
        let input = checkerboard(size: 64, cell: 4)
        var p = PortraitParams()
        p.backgroundBlur = 80
        let result = PortraitStage.process(input, faces: [], params: p, quality: .full, kernels: nil,
                                           segmenter: { _ in nil })
        XCTAssertTrue(result.image === input)
        XCTAssertNil(result.skinMask)
    }

    func testProcessLiveNeverSegments() {
        let input = checkerboard(size: 64, cell: 4)
        var p = PortraitParams()
        p.backgroundBlur = 80
        var called = false
        let result = PortraitStage.process(input, faces: [], params: p, quality: .live, kernels: nil,
                                           segmenter: { _ in called = true; return nil })
        XCTAssertFalse(called, "라이브는 인물 분리 금지")
        XCTAssertTrue(result.image === input)
    }

    func testBackgroundBlurKeepsPersonAndBlursBackground() {
        let size: CGFloat = 256
        let input = checkerboard(size: size, cell: 4)
        let mask = centerSquareMask(size: size, inset: 64)   // 64..192 = 사람
        let out = BackgroundBlur.apply(input, personMask: mask, strength: 1)
        XCTAssertEqual(out.extent, input.extent)

        let w = Int(size), h = Int(size)
        let a = pixels(input), b = pixels(out)
        // 중심(사람): 원본과 같다.
        for (x, y) in [(128, 128), (100, 150), (150, 100)] {
            XCTAssertEqual(red(b, width: w, height: h, x: x, y: y), red(a, width: w, height: h, x: x, y: y), accuracy: 2,
                           "사람 영역 (\(x), \(y))은 원본 유지")
        }
        // 모서리(배경): 반경 ≈ 3px 블러로 체스판 값이 중간값 쪽으로 이동.
        var changed = 0
        for (x, y) in [(10, 10), (245, 10), (10, 245), (245, 245), (1, 30), (30, 1)] {
            let before = red(a, width: w, height: h, x: x, y: y)
            let after = red(b, width: w, height: h, x: x, y: y)
            let mid = (red(a, width: w, height: h, x: 0, y: 0) + red(a, width: w, height: h, x: 4, y: 0)) / 2
            if abs(after - mid) < abs(before - mid) - 5 { changed += 1 }
        }
        XCTAssertGreaterThanOrEqual(changed, 4, "배경 모서리는 흐려져 중간값에 가까워져야 한다")
    }

    func testProcessAppliesBlurFromSegmenter() {
        let size: CGFloat = 128
        let input = checkerboard(size: size, cell: 2)
        let mask = centerSquareMask(size: size, inset: 32)
        var p = PortraitParams()
        p.backgroundBlur = 100
        let result = PortraitStage.process(input, faces: [], params: p, quality: .full, kernels: nil,
                                           segmenter: { _ in mask })
        XCTAssertFalse(result.image === input)
        let w = Int(size), h = Int(size)
        let a = pixels(input), b = pixels(result.image)
        XCTAssertEqual(red(b, width: w, height: h, x: 64, y: 64), red(a, width: w, height: h, x: 64, y: 64), accuracy: 2)
    }

    func testMaskScaledToInputExtent() {
        let small = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 64))
        let extent = CGRect(x: 10, y: 20, width: 300, height: 400)
        let scaled = BackgroundBlur.scaled(small, to: extent)
        XCTAssertEqual(scaled.extent, extent)
    }

    func testHasPersonThreshold() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let empty = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: rect)
        XCTAssertFalse(BackgroundBlur.hasPerson(empty))
        XCTAssertTrue(BackgroundBlur.hasPerson(centerSquareMask(size: 16, inset: 4)))
    }

    func testMaskReturnsNilForLiveQuality() {
        let input = checkerboard(size: 32, cell: 4)
        XCTAssertNil(BackgroundBlur.mask(for: input, quality: .live))
    }

    func testPreviewContextPicksPreviewStage() {
        var context = PipelineContext()
        var used = ""
        context.portraitStage = { img, _ in used = "full"; return PortraitResult(image: img, skinMask: nil) }
        context.portraitPreviewStage = { img, _ in used = "preview"; return PortraitResult(image: img, skinMask: nil) }
        let input = checkerboard(size: 16, cell: 4)
        _ = EnhancePipeline.applyPortrait(PresetParams(), to: input, hook: context.resolvedPortraitStage)
        XCTAssertEqual(used, "full", "저장 경로(isPreview false)는 저장용 hook")
        context.isPreview = true
        _ = EnhancePipeline.applyPortrait(PresetParams(), to: input, hook: context.resolvedPortraitStage)
        XCTAssertEqual(used, "preview")
    }

    // MARK: U2 라이브 원본 보기

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess && buffer != nil)
        return buffer!
    }

    func testLivePipelineBypassSkipsPipeline() {
        let pipeline = LivePipeline()
        var stages: [EnhanceStage] = []
        var context = PipelineContext()
        context.onStage = { stage, _ in stages.append(stage) }
        pipeline.update(LiveSettings(params: PresetParams(), context: context, maxDimension: 100))

        pipeline.isBypassed = true
        XCTAssertTrue(pipeline.isBypassed)
        let out = pipeline.process(makeBuffer(width: 200, height: 160))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.extent.width, 100, "원본 보기도 다운샘플은 한다")
        XCTAssertEqual(out?.extent.height, 80)
        XCTAssertTrue(stages.isEmpty, "원본 보기 중에는 파이프라인을 건너뛴다")

        pipeline.isBypassed = false
        _ = pipeline.process(makeBuffer(width: 200, height: 160))
        XCTAssertEqual(stages, EnhanceStage.allCases, "떼면 다시 보정")
    }

    func testLivePipelineBypassStillRespectsDisabled() {
        let pipeline = LivePipeline()
        pipeline.isBypassed = true
        pipeline.isEnabled = false
        XCTAssertNil(pipeline.process(makeBuffer(width: 32, height: 32)))
    }

    // MARK: U1 마커 좌표

    func testNormalizedFaceRects() {
        let extent = CGRect(x: 0, y: 0, width: 300, height: 400)
        let face = DetectedFace(boundingBox: CGRect(x: 30, y: 100, width: 60, height: 80), landmarks: FaceLandmarks())
        let rects = SmoothedFaceTracker.normalizedRects([face], in: extent)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(rects[0].minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rects[0].width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rects[0].height, 0.2, accuracy: 1e-9)
        XCTAssertTrue(SmoothedFaceTracker.normalizedRects([face], in: .null).isEmpty)
    }

    func testTrackerFaceRectsEmptyAfterReset() {
        let tracker = SmoothedFaceTracker()
        XCTAssertTrue(tracker.lastFaceRects.rects.isEmpty, "갱신 전(1초 이상 없음)은 빈 배열")
        tracker.reset()
        XCTAssertTrue(tracker.lastFaceRects.rects.isEmpty)
    }

    func testMarkerViewRectFlipsYAndFillsView() {
        // 이미지 3:4, 뷰 300×400(잘림 없음). 정규화 (0.1, 0.7, 0.2, 0.2) → 위에서 0.1 지점.
        let r = FaceMarkerGeometry.viewRect(normalized: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2),
                                            imageSize: CGSize(width: 300, height: 400),
                                            viewSize: CGSize(width: 300, height: 400), mirrored: false)
        XCTAssertEqual(r.minX, 30, accuracy: 1e-6)
        XCTAssertEqual(r.minY, 40, accuracy: 1e-6)
        XCTAssertEqual(r.width, 60, accuracy: 1e-6)
        XCTAssertEqual(r.height, 80, accuracy: 1e-6)
    }

    func testMarkerViewRectMirroredAndCropped() {
        // 뷰가 더 넓음(400×400) → aspect-fill로 이미지 400×533.3, 위아래 66.7씩 잘림.
        let n = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.25)
        let r = FaceMarkerGeometry.viewRect(normalized: n, imageSize: CGSize(width: 3, height: 4),
                                            viewSize: CGSize(width: 400, height: 400), mirrored: true)
        let fillH = 400.0 * 4 / 3
        XCTAssertEqual(r.minX, (1 - 0.3) * 400, accuracy: 1e-6, "미러면 x 반전")
        XCTAssertEqual(r.minY, (400 - fillH) / 2 + 0.25 * fillH, accuracy: 1e-6)
        XCTAssertEqual(r.width, 80, accuracy: 1e-6)
        XCTAssertEqual(r.height, 0.25 * fillH, accuracy: 1e-6)
    }

    func testMarkerViewRectDefaultsToThreeByFour() {
        let a = FaceMarkerGeometry.viewRect(normalized: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            imageSize: .zero, viewSize: CGSize(width: 300, height: 400), mirrored: false)
        XCTAssertEqual(a, CGRect(x: 0, y: 0, width: 300, height: 400))
    }

    // MARK: U3 얼굴 확대

    func testFaceZoomCentersFace() {
        // 이미지 1000×1000을 뷰 400×400에 fit. 얼굴 정규화 (0.6, 0.6, 0.2, 0.2) → 뷰 (240, 80, 80, 80), 중심 (280, 120).
        let face = CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
        let z = FaceZoomGeometry.transform(face: face, imageSize: CGSize(width: 1000, height: 1000),
                                           viewSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(z.scale, 400 / (80 * 1.6), accuracy: 1e-6)
        // 얼굴 중심이 변환 후 뷰 중심에 온다: c + (f − c)·s + offset = c.
        let fx: CGFloat = 280, fy: CGFloat = 120
        XCTAssertEqual(200 + (fx - 200) * z.scale + z.offset.width, 200, accuracy: 1e-6)
        XCTAssertEqual(200 + (fy - 200) * z.scale + z.offset.height, 200, accuracy: 1e-6)
    }

    func testFaceZoomClampsScale() {
        let big = FaceZoomGeometry.transform(face: CGRect(x: 0, y: 0, width: 1, height: 1),
                                             imageSize: CGSize(width: 3, height: 4), viewSize: CGSize(width: 300, height: 400))
        XCTAssertEqual(big.scale, 1, "확대만(축소 없음)")
        let tiny = FaceZoomGeometry.transform(face: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001),
                                              imageSize: CGSize(width: 3, height: 4), viewSize: CGSize(width: 300, height: 400))
        XCTAssertEqual(tiny.scale, FaceZoomGeometry.maxScale)
        let none = FaceZoomGeometry.transform(face: .zero, imageSize: CGSize(width: 3, height: 4),
                                              viewSize: CGSize(width: 300, height: 400))
        XCTAssertEqual(none.scale, 1)
        XCTAssertEqual(none.offset, .zero)
    }

    // MARK: U6 셀피 제안

    func testShouldSuggestPortrait() {
        XCTAssertTrue(CaptureViewModel.shouldSuggestPortrait(portraitEnabled: false, alreadyShown: false))
        XCTAssertFalse(CaptureViewModel.shouldSuggestPortrait(portraitEnabled: true, alreadyShown: false))
        XCTAssertFalse(CaptureViewModel.shouldSuggestPortrait(portraitEnabled: false, alreadyShown: true))
    }
}
