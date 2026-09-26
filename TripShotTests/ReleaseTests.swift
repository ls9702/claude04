// R1-S8c 릴리즈 1 마무리 테스트: 백업 JSON 라운드트립·병합 규칙, 기기 경고 경계값, 사용자 오류 문구, 무료 서명 만료 계산, 프리뷰 멈춤 감시.
import Foundation
import XCTest
@testable import TripShot

final class ReleaseTests: XCTestCase {

    // MARK: 도구

    private func preset(_ name: String, exposure: Double = 0, builtIn: Bool = false, order: Int = 0) -> PresetExport {
        var p = PresetParams()
        p.exposure = exposure
        return PresetExport(name: name, params: p, isBuiltIn: builtIn, sortOrder: order)
    }

    private func sampleDocument() -> BackupDocument {
        var night = PresetParams()
        night.lowLight = 70
        night.lutName = "mono"
        night.portrait.backgroundBlur = 40
        var custom = PortraitParams()
        custom.skinSmooth = 55
        custom.skinBrighten = 30
        // ISO8601은 초 단위까지만 담으므로 소수 초가 없는 시각을 쓴다.
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return Backup.make(
            presets: [PresetExport(name: "야경", params: night, isBuiltIn: true, sortOrder: 2),
                      preset("내 필름", exposure: 15, order: 6)],
            templates: [TemplateExport(name: "15초 여행", shots: [ShotSpec(name: "풍경", hint: "넓게", targetSeconds: 3)],
                                       isBuiltIn: true, sortOrder: 0)],
            formats: [FormatExport(name: "세로 9:16", width: 1080, height: 1920, safeTop: 0.15, safeBottom: 0.2,
                                   safeRight: 0.15, isBuiltIn: true, sortOrder: 0)],
            settings: SettingsExport(portraitModeEnabled: true, portraitStrength: "strong", customPortrait: custom,
                                     selectedPresetName: "내 필름", preferredFrameRate: 24),
            now: date)
    }

    // MARK: 백업

    func testBackupRoundTrip() throws {
        let doc = sampleDocument()
        let data = try Backup.encode(doc)
        let back = try Backup.decode(data)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.version, Backup.currentVersion)
        // 날짜는 ISO8601 문자열로 기록된다.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"exportedAt\" : \"20"), text)
    }

    func testBackupDecodeRejectsNewerVersionAndGarbage() {
        var doc = sampleDocument()
        doc.version = Backup.currentVersion + 1
        let data = try! Backup.encode(doc)
        XCTAssertThrowsError(try Backup.decode(data)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(Backup.currentVersion + 1))
        }
        XCTAssertThrowsError(try Backup.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? BackupError, .invalidFormat)
        }
    }

    func testBackupDecodeToleratesMissingSections() throws {
        // 설정·규격이 없는 최소 문서도 읽힌다(필드 추가·이전 백업 호환).
        let json = #"{"version":1,"exportedAt":"2026-09-26T10:00:00Z","presets":[],"templates":[]}"#
        let doc = try Backup.decode(Data(json.utf8))
        XCTAssertTrue(doc.formats.isEmpty)
        XCTAssertEqual(doc.settings, SettingsExport())
    }

    func testBackupFileName() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 26; comps.hour = 7; comps.minute = 5
        comps.timeZone = TimeZone(identifier: "Asia/Seoul")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(Backup.fileName(for: date, timeZone: TimeZone(identifier: "Asia/Seoul")!),
                       "TripShot-백업-20260926-0705.json")
    }

    func testMergePlanUpdatesSameNameAndInsertsNew() {
        let existing = [BackupExistingItem(name: "내 필름", isBuiltIn: false),
                        BackupExistingItem(name: "다른 것", isBuiltIn: false)]
        let incoming = [preset("내 필름", exposure: 30), preset("새 프리셋", exposure: 10)]
        let plan = Backup.mergePlan(existing: existing, incoming: incoming)
        XCTAssertEqual(plan.update.map(\.name), ["내 필름"])
        XCTAssertEqual(plan.update.first?.params.exposure, 30)
        XCTAssertEqual(plan.insert.map(\.name), ["새 프리셋"])
    }

    func testMergePlanUpdatesBuiltInValues() {
        // 기본 프리셋(같은 이름)은 새로 넣지 않고 값만 갱신 대상.
        let existing = [BackupExistingItem(name: "야경", isBuiltIn: true)]
        let plan = Backup.mergePlan(existing: existing, incoming: [preset("야경", exposure: -20, builtIn: true)])
        XCTAssertEqual(plan.update.count, 1)
        XCTAssertEqual(plan.update.first?.params.exposure, -20)
        XCTAssertTrue(plan.insert.isEmpty)
    }

    func testMergePlanUsesFirstOfDuplicateNames() {
        let plan = Backup.mergePlan(existing: [], incoming: [preset("A", exposure: 1), preset("A", exposure: 2)])
        XCTAssertEqual(plan.insert.count, 1)
        XCTAssertEqual(plan.insert.first?.params.exposure, 1)
    }

    func testRestoreSummaryMessage() {
        XCTAssertEqual(RestoreSummary(presets: 3, templates: 2, formats: 0).message, "프리셋 3개, 템플릿 2개 복원")
        XCTAssertEqual(RestoreSummary(presets: 1, templates: 0, formats: 4).message, "프리셋 1개, 템플릿 0개, 규격 4개 복원")
    }

    // MARK: 기기 경고

    private func kinds(thermal: ProcessInfo.ThermalState = .nominal, battery: BatteryStatus? = nil,
                       lowPower: Bool = false, disk: Int64? = nil) -> [DeviceWarning.Kind] {
        DeviceStatus.warnings(thermal: thermal, battery: battery, lowPower: lowPower, diskFreeBytes: disk).map(\.kind)
    }

    func testThermalWarningsFourStates() {
        XCTAssertEqual(kinds(thermal: .nominal), [])
        XCTAssertEqual(kinds(thermal: .fair), [])
        XCTAssertEqual(kinds(thermal: .serious), [.thermalSerious])
        XCTAssertEqual(kinds(thermal: .critical), [.thermalCritical])
        let serious = DeviceStatus.warnings(thermal: .serious, battery: nil, lowPower: false, diskFreeBytes: nil)
        XCTAssertEqual(serious.first?.message, "기기가 뜨겁습니다. 프리뷰 화질을 낮췄습니다")
        XCTAssertEqual(serious.first?.level, .caution)
        let critical = DeviceStatus.warnings(thermal: .critical, battery: nil, lowPower: false, diskFreeBytes: nil)
        XCTAssertEqual(critical.first?.message, "기기가 매우 뜨겁습니다. 잠시 쉬어 주세요")
        XCTAssertEqual(critical.first?.level, .critical)
    }

    func testBatteryWarningBoundary() {
        XCTAssertEqual(kinds(battery: BatteryStatus(level: 0.10, isCharging: false)), [.lowBattery])
        XCTAssertEqual(kinds(battery: BatteryStatus(level: 0.11, isCharging: false)), [])
        XCTAssertEqual(kinds(battery: BatteryStatus(level: 0.05, isCharging: true)), [], "충전 중이면 경고 없음")
        XCTAssertEqual(kinds(battery: BatteryStatus(level: -1, isCharging: false)), [], "알 수 없음(시뮬레이터)")
    }

    func testLowPowerWarningAndFrameRate() {
        XCTAssertEqual(kinds(lowPower: true), [.lowPower])
        XCTAssertEqual(DeviceStatus.effectiveFrameRate(preferred: 30, lowPower: true), 24)
        XCTAssertEqual(DeviceStatus.effectiveFrameRate(preferred: 30, lowPower: false), 30)
        XCTAssertEqual(DeviceStatus.effectiveFrameRate(preferred: 24, lowPower: false), 24)
    }

    func testDiskWarningBoundary() {
        XCTAssertEqual(kinds(disk: 1_000_000_000), [], "정확히 1GB는 경고 없음")
        XCTAssertEqual(kinds(disk: 999_999_999), [.lowDisk])
        XCTAssertEqual(kinds(disk: nil), [], "측정 전")
    }

    func testWarningsSortedBySeverity() {
        let all = kinds(thermal: .critical, battery: BatteryStatus(level: 0.05, isCharging: false),
                        lowPower: true, disk: 10)
        XCTAssertEqual(all, [.thermalCritical, .lowDisk, .lowBattery, .lowPower])
        let noCritical = kinds(thermal: .serious, battery: BatteryStatus(level: 0.05, isCharging: false), lowPower: true)
        XCTAssertEqual(noCritical.first, .thermalSerious)
    }

    // MARK: 사용자 문구

    func testUserMessagePhotoPermission() {
        XCTAssertEqual(UserMessage.text(for: PhotoSaveError.notAuthorized),
                       "사진 보관함 권한이 없습니다. 설정 > TripShot > 사진에서 허용해 주세요.")
        // errorDescription도 같은 문구(기존 호출부 호환).
        XCTAssertEqual(PhotoSaveError.notAuthorized.errorDescription, UserMessage.photoPermission)
    }

    func testUserMessageEnhanceAndCamera() {
        XCTAssertTrue(UserMessage.text(for: EnhanceSaveError.assetUnavailable).hasPrefix("사진을 찾을 수 없습니다."))
        XCTAssertTrue(UserMessage.text(for: CameraError.deviceUnavailable).hasPrefix("카메라를 열 수 없습니다."))
        XCTAssertTrue(UserMessage.text(for: BackupError.invalidFormat).contains("백업 파일"))
    }

    func testUserMessageUnknownErrorFallsBackToDescription() {
        struct Custom: LocalizedError { var errorDescription: String? { "알 수 없는 문제" } }
        XCTAssertEqual(UserMessage.text(for: Custom()), "알 수 없는 문제")
    }

    func testPostProcessFailureHintAfterThreeFailures() {
        let two = UserMessage.postProcessFailure(reason: "x", consecutiveFailures: 2)
        XCTAssertTrue(two.contains("원본은 저장됨"))
        XCTAssertFalse(two.contains("인물 모드"))
        let three = UserMessage.postProcessFailure(reason: "x", consecutiveFailures: 3)
        XCTAssertTrue(three.contains("원본은 저장됨"))
        XCTAssertTrue(three.contains("인물 모드"))
    }

    func testBatchResultFirstFailureReason() {
        var batch = BatchSaveResult(total: 3)
        batch.succeededIDs = ["a"]
        batch.failures = [.init(localID: "b", displayName: "B", message: "권한 없음"),
                          .init(localID: "c", displayName: "C", message: "다른 이유")]
        XCTAssertEqual(batch.firstFailureReason, "사유: 권한 없음")
        var single = BatchSaveResult(total: 1)
        single.failures = [.init(localID: "a", displayName: "A", message: "권한 없음")]
        XCTAssertNil(single.firstFailureReason, "한 장 저장은 요약에 이미 사유가 있다")
    }

    // MARK: 무료 서명 만료

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        utcCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testSigningExpiryIsInstallPlusSevenDays() {
        let install = date(2026, 9, 20, 10)
        XCTAssertEqual(SigningInfo.expiry(installDate: install, calendar: utcCalendar), date(2026, 9, 27, 10))
    }

    func testSigningDaysRemaining() {
        let expiry = date(2026, 9, 27, 10)
        let cal = utcCalendar
        XCTAssertEqual(SigningInfo.daysRemaining(until: expiry, now: date(2026, 9, 20, 23), calendar: cal), 7)
        XCTAssertEqual(SigningInfo.daysRemaining(until: expiry, now: date(2026, 9, 24, 1), calendar: cal), 3)
        XCTAssertEqual(SigningInfo.daysRemaining(until: expiry, now: date(2026, 9, 27, 20), calendar: cal), 0)
        XCTAssertEqual(SigningInfo.daysRemaining(until: expiry, now: date(2026, 9, 29), calendar: cal), -2)
        XCTAssertEqual(SigningInfo.remainingText(days: 3), "3일 남음")
        XCTAssertEqual(SigningInfo.remainingText(days: 0), "오늘 만료")
        XCTAssertTrue(SigningInfo.remainingText(days: -1).hasPrefix("만료됨"))
    }

    func testInstallDateUpdatesOnlyWhenBuildStampChanges() {
        let suite = "ReleaseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SigningInfo.recordInstallDate(defaults: defaults, dateKey: "d", stampKey: "s",
                                                  currentStamp: "1-100", now: date(2026, 9, 1))
        XCTAssertEqual(first, date(2026, 9, 1))
        let same = SigningInfo.recordInstallDate(defaults: defaults, dateKey: "d", stampKey: "s",
                                                 currentStamp: "1-100", now: date(2026, 9, 3))
        XCTAssertEqual(same, date(2026, 9, 1), "같은 설치면 첫 실행일 유지")
        let reinstalled = SigningInfo.recordInstallDate(defaults: defaults, dateKey: "d", stampKey: "s",
                                                        currentStamp: "1-200", now: date(2026, 9, 8))
        XCTAssertEqual(reinstalled, date(2026, 9, 8), "재설치(스탬프 변경)면 새로 기록")
    }

    func testParseProvisioningExpiry() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>ExpirationDate</key><date>2026-10-03T08:00:00Z</date></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0x02])   // CMS 머리(가짜)
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xA0, 0x82]))
        let expiry = SigningInfo.parseProvisioningExpiry(data)
        XCTAssertEqual(expiry, date(2026, 10, 3, 8))
        XCTAssertNil(SigningInfo.parseProvisioningExpiry(Data("없음".utf8)))
        XCTAssertEqual(SigningInfo.effectiveExpiry(installDate: date(2026, 9, 1), provisioning: nil).isEstimate, true)
    }

    // MARK: 프레임 레이트 설정·멈춤 감시

    func testFrameRateNormalization() {
        XCTAssertEqual(AppServices.normalizedFrameRate(24), 24)
        XCTAssertEqual(AppServices.normalizedFrameRate(30), 30)
        XCTAssertEqual(AppServices.normalizedFrameRate(60), 30)
    }

    func testPreviewStallDetectorRestartsOnceThenNotifies() {
        var detector = PreviewStallDetector()
        detector.threshold = 3
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle)
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle)
        XCTAssertEqual(detector.record(renderedFrames: 0), .restart)
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle)
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle)
        XCTAssertEqual(detector.record(renderedFrames: 0), .notify)
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle)
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle)
        XCTAssertEqual(detector.record(renderedFrames: 0), .idle, "알림은 한 번만")
        // 프레임이 오면 처음부터.
        XCTAssertEqual(detector.record(renderedFrames: 20), .idle)
        XCTAssertFalse(detector.restartTried)
        // 세션 중단 중(nil)은 세지 않는다.
        _ = detector.record(renderedFrames: 0)
        _ = detector.record(renderedFrames: 0)
        XCTAssertEqual(detector.record(renderedFrames: nil), .idle)
        XCTAssertEqual(detector.zeroSeconds, 0)
    }

    @MainActor
    func testAppServicesFrameRatePersists() {
        let suite = "ReleaseTests-fps-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = AppServices(defaults: defaults)
        XCTAssertEqual(services.preferredFrameRate, 30)
        services.preferredFrameRate = 24
        XCTAssertEqual(AppServices(defaults: defaults).preferredFrameRate, 24)
        services.resetSettings()
        XCTAssertEqual(AppServices(defaults: defaults).preferredFrameRate, 30)
    }
}
