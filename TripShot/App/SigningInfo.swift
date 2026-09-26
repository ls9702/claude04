// 무료 서명(7일) 만료 예정일 계산: 설치일 기록, 프로비저닝 프로파일 만료일 읽기, 남은 일수(순수 함수).
import Foundation

/// 무료 Apple ID 서명은 설치 후 7일간 유효하다(PLAN §1 전제). 설정 탭 "정보"에 만료 예정일·남은 일수를 보여 준다.
///
/// 우선순위: 앱 번들의 `embedded.mobileprovision` 만료일(정확) → 없으면 설치일 + 7일(추정).
/// 설치일은 "이 빌드를 처음 실행한 날"이다. 재설치하면 앱 데이터(UserDefaults)는 남으므로 첫 실행 한 번만 기록하면
/// 두 번째 설치부터 틀린다 → 빌드 스탬프(빌드 번호 + 실행 파일 수정 시각)가 바뀌면 새 설치로 보고 다시 기록한다.
enum SigningInfo {
    /// 무료 서명 유효 기간(일).
    static let freeSigningDays = 7

    /// 설치일 + 7일.
    static func expiry(installDate: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: freeSigningDays, to: installDate)
            ?? installDate.addingTimeInterval(TimeInterval(freeSigningDays) * 86_400)
    }

    /// 만료일까지 남은 날(달력 날짜 차이). 오늘 만료면 0, 지났으면 음수.
    static func daysRemaining(until expiry: Date, now: Date = .now, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 설정 표시 문구. 예: "3일 남음", "오늘 만료", "만료됨 — Mac에서 다시 설치".
    static func remainingText(days: Int) -> String {
        if days > 0 { return "\(days)일 남음" }
        if days == 0 { return "오늘 만료" }
        return "만료됨 — Mac에서 다시 설치"
    }

    // MARK: 설치일

    /// 빌드 스탬프가 저장된 것과 다르면(새 설치) 지금을 설치일로 기록한다. 같으면 저장된 설치일.
    static func recordInstallDate(defaults: UserDefaults, dateKey: String, stampKey: String,
                                  currentStamp: String, now: Date = .now) -> Date {
        let saved = defaults.object(forKey: dateKey) as? Date
        if let saved, defaults.string(forKey: stampKey) == currentStamp {
            return saved
        }
        defaults.set(now, forKey: dateKey)
        defaults.set(currentStamp, forKey: stampKey)
        return now
    }

    /// 이번 설치를 구분하는 값: 빌드 번호 + 실행 파일 수정 시각(초).
    /// TODO(검증): Xcode로 같은 빌드를 재설치해도 실행 파일 수정 시각이 바뀌는지 실기기 확인(안 바뀌면 설치일이 갱신되지 않음 —
    /// 이 경우에도 프로비저닝 만료일이 있으면 그것을 쓰므로 표시는 맞다).
    static func currentBuildStamp(bundle: Bundle = .main) -> String {
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        var modified: TimeInterval = 0
        if let path = bundle.executablePath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attributes[.modificationDate] as? Date {
            modified = date.timeIntervalSince1970.rounded()
        }
        return "\(build)-\(Int(modified))"
    }

    // MARK: 프로비저닝 프로파일

    /// 이 앱 번들의 프로파일 만료일(한 번만 읽는다). 설치 중에는 바뀌지 않는다.
    static let bundleProvisioningExpiry: Date? = provisioningExpiry()

    /// 앱 번들의 `embedded.mobileprovision` 만료일. 시뮬레이터·App Store 빌드에는 파일이 없어 nil.
    static func provisioningExpiry(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parseProvisioningExpiry(data)
    }

    /// 프로파일은 CMS 서명 안에 XML plist가 평문으로 들어 있다. `<?xml` ~ `</plist>` 구간만 잘라 `ExpirationDate`를 읽는다.
    static func parseProvisioningExpiry(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// 표시할 만료일: 프로파일 만료일이 있으면 그것, 없으면 설치일 + 7일. 두 번째 값은 추정 여부.
    static func effectiveExpiry(installDate: Date, provisioning: Date?) -> (date: Date, isEstimate: Bool) {
        if let provisioning { return (provisioning, false) }
        return (expiry(installDate: installDate), true)
    }
}
