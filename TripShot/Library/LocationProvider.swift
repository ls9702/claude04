// 촬영 위치를 사진에 기록하기 위한 Core Location 래퍼("앱 사용 중" 권한만, 거부 시 조용히 nil).
import CoreLocation
import Foundation

/// 마지막 위치를 `last`로 제공한다. 권한이 없거나 위치를 못 얻으면 오류 없이 `last == nil`로 둔다(PLAN §3.4).
/// 메인 스레드에서 만든다(CLLocationManager 델리게이트 콜백이 생성 스레드의 런루프로 온다).
final class LocationProvider: NSObject, CLLocationManagerDelegate, ObservableObject {
    @Published private(set) var last: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager: CLLocationManager
    /// start()가 권한 결정 전에 불렸으면, 권한이 허용되는 즉시 갱신을 시작한다.
    private var wantsUpdates = false

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    /// "앱 사용 중" 권한 요청. 이미 결정됐으면 아무것도 하지 않는다.
    func requestWhenInUse() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// 위치 갱신 시작. 권한이 아직 없으면 요청만 하고, 허용되면 델리게이트에서 시작한다.
    func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break   // 거부·제한: 위치 없이 동작
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        if authorized && wantsUpdates {
            manager.startUpdatingLocation()
        }
        onMain {
            self.authorizationStatus = status
            if !authorized { self.last = nil }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 정확도가 무효(음수)인 값은 버린다.
        guard let newest = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        onMain { self.last = newest }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 일시적 실패(kCLErrorLocationUnknown)는 무시하고, 마지막 값은 그대로 둔다. 거부는 권한 콜백에서 처리.
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
