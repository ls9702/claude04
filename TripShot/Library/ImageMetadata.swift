// 이미지 메타데이터(EXIF·GPS·TIFF 등) 읽기·골라 복사·GPS 변환을 담당하는 순수 함수 모음 (PLAN §3.4).
import CoreLocation
import Foundation
import ImageIO

/// 이미지 메타데이터 도구. 상태가 없고 모든 함수는 입력만 보고 결과를 만든다(파일·사진 보관함을 건드리지 않음).
enum ImageMetadata {

    // MARK: 읽기

    /// 이미지 데이터(JPEG/HEIF 등)의 첫 번째 이미지 속성 딕셔너리. 읽을 수 없으면 nil.
    static func properties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return props
    }

    /// 이미지 데이터의 UTI(예: "public.heic", "public.jpeg"). 읽을 수 없으면 nil.
    static func typeIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }

    // MARK: 보존할 속성 고르기

    /// 원본에서 그대로 옮길 하위 딕셔너리 키. 촬영 정보·위치·카메라 정보가 여기에 모두 들어 있다.
    static let preservedKeys: [CFString] = [
        kCGImagePropertyExifDictionary,
        kCGImagePropertyGPSDictionary,
        kCGImagePropertyTIFFDictionary,
        kCGImagePropertyIPTCDictionary,
        kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyMakerAppleDictionary,
    ]

    /// 원본 속성에서 **보존할 키만** 골라 새 딕셔너리를 만든다.
    /// - 보존: Exif, GPS, TIFF, IPTC, ExifAux, MakerApple.
    /// - 제외: 픽셀 크기·DPI·색 모델·프로파일 이름·비트 깊이(렌더 결과에 맞게 인코더가 다시 쓴다).
    /// - 방향: 렌더 결과는 항상 `.up`이므로 최상위 Orientation과 TIFF Orientation을 모두 1로 명시한다.
    ///   (원본 방향 값이 남아 있으면 이미 똑바로 세운 픽셀이 한 번 더 돌아가 보인다.)
    static func preservedProperties(from source: [CFString: Any]) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        for key in preservedKeys {
            if let value = source[key] { result[key] = value }
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        result[kCGImagePropertyOrientation] = 1
        return result
    }

    /// Exif의 PixelXDimension/PixelYDimension을 새 크기로 바꾼 사본. Exif가 없으면 새로 만든다.
    /// 렌더 결과 크기가 원본과 다를 수 있으므로(수평 보정 크롭 등) 인코딩 직전에 호출한다.
    static func withPixelSize(_ properties: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var result = properties
        var exif = (result[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = width
        exif[kCGImagePropertyExifPixelYDimension] = height
        result[kCGImagePropertyExifDictionary] = exif
        return result
    }

    /// CFString 키 딕셔너리 → String 키 딕셔너리(하위 딕셔너리까지). `AVCapturePhotoSettings.metadata`처럼
    /// `[String: Any]`를 요구하는 API에 넘길 때 쓴다.
    static func stringKeyed(_ dict: [CFString: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            if let sub = value as? [CFString: Any] {
                result[key as String] = stringKeyed(sub)
            } else {
                result[key as String] = value
            }
        }
        return result
    }

    // MARK: GPS

    /// CLLocation → EXIF GPS 딕셔너리(`kCGImagePropertyGPSDictionary`의 값). 순수 함수.
    /// - 위도·경도·고도는 절대값 + Ref(N/S, E/W, 0 해발 위/1 아래)로 쓴다(EXIF 규격).
    /// - 시각은 UTC로 DateStamp "yyyy:MM:dd", TimeStamp "HH:mm:ss.SS".
    /// - 고도는 verticalAccuracy ≥ 0(유효)일 때만, 오차는 horizontalAccuracy ≥ 0일 때만,
    ///   속도(km/h)는 speed ≥ 0일 때만, 이동 방향은 course ≥ 0일 때만 기록한다.
    static func gpsDictionary(from location: CLLocation) -> [CFString: Any] {
        var gps: [CFString: Any] = [:]
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        gps[kCGImagePropertyGPSLatitude] = abs(lat)
        gps[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(lon)
        gps[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"

        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = location.altitude >= 0 ? 0 : 1
        }

        gps[kCGImagePropertyGPSDateStamp] = utcFormatter("yyyy:MM:dd").string(from: location.timestamp)
        gps[kCGImagePropertyGPSTimeStamp] = utcFormatter("HH:mm:ss.SS").string(from: location.timestamp)

        if location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = location.horizontalAccuracy
        }
        if location.speed >= 0 {
            gps[kCGImagePropertyGPSSpeed] = location.speed * 3.6   // m/s → km/h
            gps[kCGImagePropertyGPSSpeedRef] = "K"
        }
        if location.course >= 0 {
            // course는 "이동 방향"이므로 EXIF GPSTrack(이동 방향)에 기록한다.
            // GPSImgDirection은 "카메라가 향한 방향"이라 의미가 다르다(나침반 heading이 있을 때 쓸 자리).
            gps[kCGImagePropertyGPSTrack] = location.course
            gps[kCGImagePropertyGPSTrackRef] = "T"   // 진북 기준
        }
        return gps
    }

    /// EXIF GPS 딕셔너리 → CLLocation(역변환). 위도·경도가 없으면 nil. 순수 함수.
    /// - 날짜·시각이 없으면 `fallbackTimestamp`를 쓴다.
    /// - 수평 오차가 없으면 0(유효한 좌표로 취급), 고도가 없으면 verticalAccuracy -1(고도 무효).
    static func location(from gps: [CFString: Any], fallbackTimestamp: Date = Date(timeIntervalSince1970: 0)) -> CLLocation? {
        guard var lat = double(gps[kCGImagePropertyGPSLatitude]),
              var lon = double(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -abs(lat) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -abs(lon) }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }

        var altitude: Double = 0
        var verticalAccuracy: Double = -1
        if let alt = double(gps[kCGImagePropertyGPSAltitude]) {
            let below = int(gps[kCGImagePropertyGPSAltitudeRef]) == 1
            altitude = below ? -abs(alt) : abs(alt)
            verticalAccuracy = 0
        }
        let horizontalAccuracy = double(gps[kCGImagePropertyGPSHPositioningError]).map { max(0, $0) } ?? 0

        let timestamp = gpsTimestamp(date: gps[kCGImagePropertyGPSDateStamp] as? String,
                                     time: gps[kCGImagePropertyGPSTimeStamp] as? String) ?? fallbackTimestamp

        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: altitude,
                          horizontalAccuracy: horizontalAccuracy,
                          verticalAccuracy: verticalAccuracy,
                          timestamp: timestamp)
    }

    /// GPS DateStamp("yyyy:MM:dd") + TimeStamp("HH:mm:ss" 또는 "HH:mm:ss.SS", UTC) → Date.
    static func gpsTimestamp(date: String?, time: String?) -> Date? {
        guard let date, let time,
              let day = utcFormatter("yyyy:MM:dd").date(from: date) else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return day.addingTimeInterval(h * 3600 + m * 60 + s)
    }

    // MARK: 촬영 날짜

    /// 속성 딕셔너리에서 촬영 시각을 읽는다. 순수 함수.
    /// 1) Exif DateTimeOriginal + OffsetTimeOriginal(있으면 그 시간대, 없으면 기기 로컬 시간대)
    /// 2) 없으면 TIFF DateTime + Exif OffsetTime
    static func creationDate(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        if let original = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = exifDate(original, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String) {
            return date
        }
        if let dateTime = tiff?[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifDate(dateTime, offset: exif?[kCGImagePropertyExifOffsetTime] as? String) {
            return date
        }
        return nil
    }

    /// "yyyy:MM:dd HH:mm:ss" + 선택적 오프셋("+09:00") → Date. 오프셋이 없거나 해석 불가면 로컬 시간대.
    static func exifDate(_ string: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let seconds = offsetSeconds(offset), let zone = TimeZone(secondsFromGMT: seconds) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = TimeZone.current
        }
        // 일부 기기는 소수 초("05:06:07.123")를 붙이므로 앞 19자만 쓴다.
        return formatter.date(from: String(string.prefix(19)))
    }

    /// "+09:00" / "-05:30" / "Z" → 초. 형식이 다르면 nil.
    static func offsetSeconds(_ offset: String) -> Int? {
        let s = offset.trimmingCharacters(in: .whitespaces)
        if s == "Z" { return 0 }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let body = s.dropFirst().split(separator: ":")
        guard body.count == 2, let h = Int(body[0]), let m = Int(body[1]),
              (0...18).contains(h), (0..<60).contains(m) else { return nil }
        let total = h * 3600 + m * 60
        return sign == "-" ? -total : total
    }

    // MARK: 내부 도구

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// NSNumber·Double·Int·String 어느 쪽으로 와도 Double로 읽는다(ImageIO는 보통 NSNumber).
    private static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
