// R1-S2 저장·메타데이터 테스트: GPS 변환·역변환, 보존 속성 선택, 촬영 날짜, 인코더 메타 기록, 편집 기록 라운드트립.
import CoreGraphics
import CoreLocation
import ImageIO
import XCTest
@testable import TripShot

final class MetadataTests: XCTestCase {

    // MARK: 도구

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func location(lat: Double, lon: Double, alt: Double, iso: String = "2026-01-02T03:04:05Z") -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                   altitude: alt, horizontalAccuracy: 5, verticalAccuracy: 3,
                   timestamp: date(iso))
    }

    private func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    /// 4×4 sRGB 회색 CGImage.
    private func smallImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    // MARK: gpsDictionary

    func testGPSDictionarySeoul() {
        let gps = ImageMetadata.gpsDictionary(from: location(lat: 37.5665, lon: 126.978, alt: 38))
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "N")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "E")
        XCTAssertEqual(double(gps[kCGImagePropertyGPSLatitude])!, 37.5665, accuracy: 1e-9)
        XCTAssertEqual(double(gps[kCGImagePropertyGPSLongitude])!, 126.978, accuracy: 1e-9)
        XCTAssertEqual(double(gps[kCGImagePropertyGPSAltitude])!, 38, accuracy: 1e-9)
        XCTAssertEqual(int(gps[kCGImagePropertyGPSAltitudeRef]), 0)
        XCTAssertEqual(gps[kCGImagePropertyGPSDateStamp] as? String, "2026:01:02")
        XCTAssertEqual(gps[kCGImagePropertyGPSTimeStamp] as? String, "03:04:05.00")
        XCTAssertEqual(double(gps[kCGImagePropertyGPSHPositioningError])!, 5, accuracy: 1e-9)
    }

    func testGPSDictionarySouthWest() {
        let gps = ImageMetadata.gpsDictionary(from: location(lat: -33.87, lon: -151.21, alt: 10))
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
        XCTAssertEqual(double(gps[kCGImagePropertyGPSLatitude])!, 33.87, accuracy: 1e-9)
        XCTAssertEqual(double(gps[kCGImagePropertyGPSLongitude])!, 151.21, accuracy: 1e-9)
    }

    func testGPSDictionaryBelowSeaLevel() {
        let gps = ImageMetadata.gpsDictionary(from: location(lat: 31.5, lon: 35.5, alt: -430))
        XCTAssertEqual(int(gps[kCGImagePropertyGPSAltitudeRef]), 1)
        XCTAssertEqual(double(gps[kCGImagePropertyGPSAltitude])!, 430, accuracy: 1e-9)
    }

    func testGPSDictionaryOmitsInvalidOptionalFields() {
        // speed·course가 -1(무효)이면 기록하지 않는다.
        let gps = ImageMetadata.gpsDictionary(from: location(lat: 1, lon: 1, alt: 0))
        XCTAssertNil(gps[kCGImagePropertyGPSSpeed])
        XCTAssertNil(gps[kCGImagePropertyGPSTrack])
    }

    // MARK: location(from:)

    func testLocationRoundTrip() {
        let original = location(lat: 37.5665, lon: 126.978, alt: 38)
        let back = ImageMetadata.location(from: ImageMetadata.gpsDictionary(from: original))
        XCTAssertNotNil(back)
        XCTAssertEqual(back!.coordinate.latitude, 37.5665, accuracy: 1e-6)
        XCTAssertEqual(back!.coordinate.longitude, 126.978, accuracy: 1e-6)
        XCTAssertEqual(back!.altitude, 38, accuracy: 1e-6)
        XCTAssertEqual(back!.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 0.01)
    }

    func testLocationRoundTripSouthWestBelowSea() {
        let original = location(lat: -33.87, lon: -151.21, alt: -12)
        let back = ImageMetadata.location(from: ImageMetadata.gpsDictionary(from: original))!
        XCTAssertEqual(back.coordinate.latitude, -33.87, accuracy: 1e-6)
        XCTAssertEqual(back.coordinate.longitude, -151.21, accuracy: 1e-6)
        XCTAssertEqual(back.altitude, -12, accuracy: 1e-6)
    }

    func testLocationFromEmptyIsNil() {
        XCTAssertNil(ImageMetadata.location(from: [:]))
    }

    // MARK: preservedProperties / withPixelSize

    func testPreservedPropertiesKeepsMetaAndDropsGeometry() {
        let source: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.8] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple",
                                             kCGImagePropertyTIFFOrientation: 6] as [CFString: Any],
            kCGImagePropertyPixelWidth: 4032,
            kCGImagePropertyPixelHeight: 3024,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyDPIWidth: 72,
            kCGImagePropertyDPIHeight: 72,
            kCGImagePropertyColorModel: "RGB",
            kCGImagePropertyDepth: 8,
        ]
        let out = ImageMetadata.preservedProperties(from: source)

        XCTAssertNotNil(out[kCGImagePropertyExifDictionary])
        XCTAssertNotNil(out[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(out[kCGImagePropertyTIFFDictionary])
        XCTAssertNil(out[kCGImagePropertyPixelWidth])
        XCTAssertNil(out[kCGImagePropertyPixelHeight])
        XCTAssertNil(out[kCGImagePropertyDPIWidth])
        XCTAssertNil(out[kCGImagePropertyDPIHeight])
        XCTAssertNil(out[kCGImagePropertyColorModel])
        XCTAssertNil(out[kCGImagePropertyDepth])
        XCTAssertEqual(int(out[kCGImagePropertyOrientation]), 1)

        let tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(int(tiff?[kCGImagePropertyTIFFOrientation]), 1)
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Apple")
        let exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(double(exif?[kCGImagePropertyExifFNumber]) ?? 0, 1.8, accuracy: 1e-9)
    }

    func testWithPixelSizeUpdatesExifDimensions() {
        let source: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 4032,
                                             kCGImagePropertyExifPixelYDimension: 3024,
                                             kCGImagePropertyExifFNumber: 1.8] as [CFString: Any],
        ]
        let out = ImageMetadata.withPixelSize(source, width: 3000, height: 4000)
        let exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(int(exif?[kCGImagePropertyExifPixelXDimension]), 3000)
        XCTAssertEqual(int(exif?[kCGImagePropertyExifPixelYDimension]), 4000)
        XCTAssertNotNil(exif?[kCGImagePropertyExifFNumber])
    }

    // MARK: creationDate

    func testCreationDateWithOffset() {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:03:04 05:06:07",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+09:00"] as [CFString: Any],
        ]
        XCTAssertEqual(ImageMetadata.creationDate(from: props), date("2026-03-03T20:06:07Z"))
    }

    func testCreationDateWithoutOffsetUsesLocalTime() {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:03:04 05:06:07"] as [CFString: Any],
        ]
        XCTAssertNotNil(ImageMetadata.creationDate(from: props))
    }

    func testCreationDateFallsBackToTIFF() {
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2026:03:04 05:06:07"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifOffsetTime: "+00:00"] as [CFString: Any],
        ]
        XCTAssertEqual(ImageMetadata.creationDate(from: props), date("2026-03-04T05:06:07Z"))
    }

    func testCreationDateMissingIsNil() {
        XCTAssertNil(ImageMetadata.creationDate(from: [:]))
    }

    // MARK: ImageEncoder

    func testFormatOfUTI() {
        XCTAssertEqual(ImageEncoder.format(ofUTI: "public.heic"), .heif)
        XCTAssertEqual(ImageEncoder.format(ofUTI: "public.heif"), .heif)
        XCTAssertEqual(ImageEncoder.format(ofUTI: "public.jpeg"), .jpeg)
        XCTAssertEqual(ImageEncoder.format(ofUTI: "public.png"), .jpeg)
        XCTAssertEqual(ImageEncoder.format(ofUTI: ""), .jpeg)
    }

    /// 원본 속성(방향 6, GPS) → 보존 속성 → 인코딩 → 다시 읽기.
    private func encodedProperties(format: ImageEncoder.Format) throws -> [CFString: Any]? {
        let gps = ImageMetadata.gpsDictionary(from: location(lat: 37.5665, lon: 126.978, alt: 38))
        let source: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6] as [CFString: Any],
        ]
        let props = ImageMetadata.withPixelSize(ImageMetadata.preservedProperties(from: source), width: 4, height: 4)
        let data = try ImageEncoder.encode(smallImage(), format: format, properties: props)
        return ImageMetadata.properties(of: data)
    }

    func testJPEGEncodingKeepsGPSAndUprightOrientation() throws {
        let props = try encodedProperties(format: .jpeg)
        XCTAssertNotNil(props)
        let gps = props?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(double(gps?[kCGImagePropertyGPSLatitude]) ?? 0, 37.5665, accuracy: 1e-4)
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitudeRef] as? String, "N")
        XCTAssertEqual(int(props?[kCGImagePropertyOrientation]), 1)
    }

    func testHEIFEncodingKeepsGPS() throws {
        let props: [CFString: Any]?
        do {
            props = try encodedProperties(format: .heif)
        } catch {
            // 시뮬레이터(특히 일부 Mac 환경)에는 HEVC 인코더가 없을 수 있다.
            throw XCTSkip("시뮬레이터 HEIF 미지원")
        }
        let gps = props?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(double(gps?[kCGImagePropertyGPSLatitude]) ?? 0, 37.5665, accuracy: 1e-4)
        XCTAssertEqual(int(props?[kCGImagePropertyOrientation]), 1)
    }

    func testJPEGEncodingIsJPEG() throws {
        let data = try ImageEncoder.encode(smallImage(), format: .jpeg, properties: [:])
        XCTAssertEqual(ImageMetadata.typeIdentifier(of: data), "public.jpeg")
    }

    // MARK: AdjustmentPayload

    func testAdjustmentPayloadRoundTrip() throws {
        var params = PresetParams()
        params.exposure = 12
        params.lutName = "mono"
        params.autoHorizon = true
        let payload = AdjustmentPayload(params: params, horizonAngle: -0.05)
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(AdjustmentPayload.self, from: data)
        XCTAssertEqual(back, payload)
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(PhotoSaver.adjustmentFormatIdentifier, "com.ls9702.tripshot.preset")
    }
}
