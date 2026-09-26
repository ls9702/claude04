// 촬영 중 기기 상태(열·배터리·저전력 모드·저장 공간) 관찰과 경고 배너 규칙(순수 함수 `DeviceStatus`).
import Combine
import Foundation
import UIKit

// MARK: - 경고 규칙 (순수)

/// 배터리 상태(테스트용 값 타입). `level`은 0~1, 알 수 없으면 음수(시뮬레이터 등).
struct BatteryStatus: Equatable {
    var level: Float
    var isCharging: Bool
}

/// 촬영 화면 상단 배너 한 건.
struct DeviceWarning: Equatable, Identifiable {
    enum Kind: Int, CaseIterable {
        case thermalCritical, lowDisk, thermalSerious, lowBattery, lowPower
    }

    /// 심각도. 배너 색: critical = 빨강, caution = 노랑, info = 회색.
    enum Level: Int, Comparable {
        case info, caution, critical
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    let level: Level
    let message: String

    var id: Kind { kind }
}

enum DeviceStatus {
    /// 이 비율 이하(반올림 %)이고 충전 중이 아니면 배터리 경고.
    static let lowBatteryPercent = 10
    /// 사진 저장 여유 공간이 이보다 작으면 경고(10진 1GB — iOS 설정 앱의 표기와 같다).
    static let lowDiskBytes: Int64 = 1_000_000_000
    /// 저전력 모드의 프리뷰 프레임 레이트.
    static let lowPowerFrameRate: Double = 24

    /// 현재 상태의 경고 목록. **심각한 것부터** 정렬된다(화면은 첫 번째만 보여 준다).
    /// - Parameters:
    ///   - battery: nil이거나 level < 0이면 배터리 경고 없음.
    ///   - diskFreeBytes: nil이면(측정 전·실패) 저장 공간 경고 없음.
    static func warnings(thermal: ProcessInfo.ThermalState,
                         battery: BatteryStatus?,
                         lowPower: Bool,
                         diskFreeBytes: Int64?) -> [DeviceWarning] {
        var result: [DeviceWarning] = []
        switch thermal {
        case .critical:
            result.append(DeviceWarning(kind: .thermalCritical, level: .critical,
                                        message: "기기가 매우 뜨겁습니다. 잠시 쉬어 주세요"))
        case .serious:
            result.append(DeviceWarning(kind: .thermalSerious, level: .caution,
                                        message: "기기가 뜨겁습니다. 프리뷰 화질을 낮췄습니다"))
        default:
            break
        }
        if let battery, battery.level >= 0, !battery.isCharging {
            let percent = Int((battery.level * 100).rounded())
            if percent <= lowBatteryPercent {
                result.append(DeviceWarning(kind: .lowBattery, level: .caution,
                                            message: "배터리 \(percent)% — 충전해 주세요"))
            }
        }
        if lowPower {
            result.append(DeviceWarning(kind: .lowPower, level: .info,
                                        message: "저전력 모드: 프리뷰 24fps"))
        }
        if let diskFreeBytes, diskFreeBytes < lowDiskBytes {
            result.append(DeviceWarning(kind: .lowDisk, level: .caution,
                                        message: "저장 공간이 1GB 미만입니다. 사진이 저장되지 않을 수 있어요"))
        }
        // 심각도 내림차순, 같은 심각도는 Kind 순서(열 위험 → 저장 공간 → 열 → 배터리 → 저전력).
        return result.sorted { a, b in
            a.level != b.level ? a.level > b.level : a.kind.rawValue < b.kind.rawValue
        }
    }

    /// 실제로 카메라에 줄 프레임 레이트: 설정값(30/24), 저전력 모드면 24 이하.
    static func effectiveFrameRate(preferred: Double, lowPower: Bool) -> Double {
        lowPower ? min(preferred, lowPowerFrameRate) : preferred
    }
}

// MARK: - 관찰자

/// 기기 상태 관찰. 촬영 탭 ViewModel이 하나 갖고, 열 상태는 여기서 받아 프리뷰 해상도에 반영한다.
///
/// 큐 규칙: 알림은 임의 스레드에서 오므로 모두 메인으로 옮겨 `@Published`를 바꾼다.
/// 저장 공간 조회(파일 시스템)는 분리 태스크에서 하고 결과만 메인에 반영한다.
@MainActor
final class DeviceStatusMonitor: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    /// 0~1, 알 수 없으면 -1.
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown
    @Published private(set) var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// 사진 저장에 쓸 수 있는 여유 공간(바이트). 측정 전이면 nil.
    @Published private(set) var diskFreeBytes: Int64?

    private var cancellables: Set<AnyCancellable> = []
    private var diskTask: Task<Void, Never>?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        readBattery()

        let center = NotificationCenter.default
        center.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.thermalState = ProcessInfo.processInfo.thermalState }
            .store(in: &cancellables)
        center.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .merge(with: center.publisher(for: UIDevice.batteryStateDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.readBattery() }
            .store(in: &cancellables)
        // 시그니처: Notification.Name.NSProcessInfoPowerStateDidChange (ProcessInfo.isLowPowerModeEnabled 변경)
        center.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .store(in: &cancellables)
    }

    /// 지금 보여 줄 경고(심각한 것부터).
    var warnings: [DeviceWarning] {
        let charging = batteryState == .charging || batteryState == .full
        return DeviceStatus.warnings(thermal: thermalState,
                                     battery: BatteryStatus(level: batteryLevel, isCharging: charging),
                                     lowPower: isLowPowerMode,
                                     diskFreeBytes: diskFreeBytes)
    }

    /// 저장 공간 다시 읽기(촬영 탭 진입·촬영 후). 파일 시스템 조회는 메인 밖에서.
    func refreshDiskSpace() {
        diskTask?.cancel()
        diskTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) { Self.availableDiskBytes() }.value
            guard !Task.isCancelled else { return }
            self?.diskFreeBytes = bytes
        }
    }

    /// "중요한 용도"(사용자가 요청한 저장) 기준 여유 공간. 시스템이 지울 수 있는 캐시 공간을 포함한다.
    nonisolated static func availableDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func readBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
    }
}
