import XCTest
@testable import TripShot

final class TemplateTests: XCTestCase {
    func testDefaultTemplatesDecode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "default-templates", withExtension: "json")
            ?? Bundle.main.url(forResource: "default-templates", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let defs = try XCTUnwrap(TemplateLoader.decode(data))
        XCTAssertEqual(defs.count, 3)
        XCTAssertEqual(defs[0].totalSeconds, 15)
        XCTAssertEqual(defs[1].totalSeconds, 30)
        XCTAssertTrue(defs[2].shots.isEmpty)
    }

    func testPresetParamsRoundTrip() throws {
        var p = PresetParams()
        p.vibrance = 25; p.lutName = "mono"; p.portrait.faceSlim = 40
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PresetParams.self, from: data)
        XCTAssertEqual(p, back)
    }
}
