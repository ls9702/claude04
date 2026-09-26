// 촬영 화면 [원본]/[인물 ▾]/[배경 ▾] 메뉴: 세 모드가 서로 배타적인지, 인물은 자동 보정 위에 강도 값이 얹히는지.
import XCTest
@testable import TripShot

@MainActor
final class CaptureLookTests: XCTestCase {

    private func makeVM() -> (CaptureViewModel, AppServices, () -> Void) {
        let suite = "CaptureLookTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let services = AppServices(defaults: defaults)
        let vm = CaptureViewModel()
        vm.configure(services: services)
        return (vm, services, { defaults.removePersistentDomain(forName: suite) })
    }

    func testOriginalTurnsOffPortrait() {
        let (vm, services, cleanup) = makeVM(); defer { cleanup() }
        vm.selectPortrait(.strong)
        vm.selectOriginal()
        XCTAssertEqual(vm.look, .original)
        XCTAssertFalse(services.portraitModeEnabled)
        XCTAssertEqual(vm.choice, .original)
    }

    func testPortraitUsesAutoWithStrength() {
        let (vm, services, cleanup) = makeVM(); defer { cleanup() }
        vm.selectOriginal()
        vm.selectPortrait(.strong)
        XCTAssertEqual(vm.look, .portrait)
        XCTAssertTrue(services.portraitModeEnabled)
        XCTAssertEqual(vm.choice, .auto, "원본에서 인물로 가면 자동 보정 위에 얹는다")
        XCTAssertEqual(services.portraitStrength, .strong)
        XCTAssertEqual(vm.portraitStrengthSelection, .strong)
    }

    func testSceneTurnsOffPortrait() {
        let (vm, services, cleanup) = makeVM(); defer { cleanup() }
        vm.selectPortrait(.normal)
        let id = UUID()
        vm.selectScene(choice: .preset(id), params: PresetParams())
        XCTAssertEqual(vm.look, .scene)
        XCTAssertFalse(services.portraitModeEnabled)
        XCTAssertEqual(vm.choice, .preset(id))
        XCTAssertEqual(services.selectedPresetID, id)
    }
}
