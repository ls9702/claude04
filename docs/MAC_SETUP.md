# Mac 설정·빌드·설치 가이드 (MacBook Air M2 → iPhone 12 Pro)

이 저장소의 코드는 Linux 환경에서 작성되어 **빌드는 Mac에서만** 할 수 있다. 아래 순서대로 한 번만 설정하면 이후에는 §4의 3단계만 반복한다.

## 1. 최초 1회 설정

1. **macOS 업데이트**: 시스템 설정 → 일반 → 소프트웨어 업데이트. iOS 27 기기에 설치하려면 iOS 27 SDK가 포함된 최신 Xcode가 필요하고, 그 Xcode는 최신 macOS를 요구한다.
2. **Xcode 설치**: App Store에서 Xcode 설치(약 10GB). 첫 실행 시 "iOS" 플랫폼 구성요소를 추가로 받는다.
3. **명령줄 도구**: 터미널에서 `xcode-select --install`. Xcode 설치 후 `sudo xcode-select -s /Applications/Xcode.app`, `sudo xcodebuild -runFirstLaunch`, `xcodebuild -downloadPlatform iOS`(시뮬레이터 런타임).
   **Xcode 26 이상은 Metal 컴파일러가 별도 구성요소**다: `xcodebuild -downloadComponent MetalToolchain`. 없으면 `.metal` 파일 빌드에서 `cannot execute tool 'metal'` 오류.
4. **Homebrew + XcodeGen** (프로젝트 파일 생성 도구):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install xcodegen
   ```
   XcodeGen 없이 Xcode에서 직접 프로젝트를 만들고 싶으면 §6 참고.
5. **iPhone 개발자 모드**: iPhone 설정 → 개인정보 보호 및 보안 → 개발자 모드 켬 → 재시동. (iPhone을 Mac에 케이블로 연결한 뒤에야 메뉴가 보일 수 있다.)
6. **Xcode에 Apple ID 등록**: Xcode → Settings → Accounts → + → 본인 Apple ID(무료).

## 2. 저장소 받기

```bash
git clone https://github.com/ls9702/claude04.git
cd claude04
git checkout claude/health-management-app-plan-bcq1hg
```

## 3. 프로젝트 생성 (코드 구조가 바뀔 때마다 다시 실행)

```bash
xcodegen generate
open TripShot.xcodeproj
```

Xcode가 열리면:
1. 왼쪽에서 프로젝트(TripShot) → TARGETS TripShot → **Signing & Capabilities**.
2. **Team**에서 본인 Apple ID(Personal Team) 선택. Bundle Identifier가 `com.ls9702.tripshot`인지 확인(중복 오류가 나면 뒤에 숫자를 붙인다).
3. 패키지 해석이 자동으로 돌며 YouTubeKit을 받는다(인터넷 필요).

## 4. iPhone에 설치 (반복)

1. iPhone을 케이블로 연결, 잠금 해제. "이 컴퓨터를 신뢰" 허용.
2. Xcode 상단 기기 선택에서 본인 iPhone 선택.
3. **⌘R** (Run). 첫 설치 시 iPhone에서 "신뢰하지 않는 개발자" 경고가 나오면:
   iPhone 설정 → 일반 → VPN 및 기기 관리 → 개발자 앱 → 본인 Apple ID → 신뢰.
4. 앱 실행 → 카메라·마이크·사진 권한 허용.

### 7일 갱신 (무료 계정)
무료 서명은 설치 시점부터 **7일**간 유효하다. 만료되면 앱 아이콘을 눌러도 열리지 않는다.
- 만료 전후 언제든 위 §4의 1~3을 다시 하면 갱신된다(약 1분). **앱 데이터는 유지**된다(같은 번들 ID로 덮어쓰기).
- 여행 출발 전날 갱신해 두면 7일 여행 동안 문제없다. 그보다 긴 여행이면 노트북을 가져가거나 유료 계정(연 129,000원)으로 전환한다.
- 무료 계정은 동시에 앱 3개까지만 서명 가능하다.

## 5. 테스트 실행
Xcode에서 **⌘U**. `TripShotTests`가 템플릿 JSON 디코딩과 프리셋 직렬화를 검사한다.

## 6. XcodeGen 없이 수동으로 프로젝트 만들기 (대안)
1. Xcode → File → New → Project → iOS App. Product Name `TripShot`, Interface SwiftUI, Language Swift, Storage **SwiftData**, Bundle ID `com.ls9702.tripshot`.
2. 저장 위치를 이 저장소 폴더로 지정하되, Xcode가 만든 `TripShot/` 폴더 안의 기본 파일(ContentView.swift, TripShotApp.swift, Item.swift)은 삭제.
3. Finder에서 저장소의 `TripShot/` 하위 폴더들(App, Capture, …, Resources, Assets.xcassets)을 Xcode 내비게이터의 TripShot 그룹으로 드래그. "Create folder references"가 아니라 **"Create groups"** 선택, Target에 TripShot 체크.
4. Project → Package Dependencies → + → `https://github.com/alexeichhorn/YouTubeKit` 추가.
5. Target → Info에 `project.yml`의 `info.properties`에 있는 권한 문구(NSCameraUsageDescription 등)를 추가.
6. Deployment Target을 iOS 26.0으로.

## 7. 빌드 오류가 나면
Xcode 왼쪽 ⚠️ 아이콘(Issue Navigator)에서 오류를 복사해 채팅으로 보내 주면 수정한다. 스크린샷도 좋다. 다음을 함께 알려주면 빠르다: Xcode 버전(Xcode → About), macOS 버전, iOS 버전.

## 8. 흔한 문제
| 증상 | 해결 |
|---|---|
| "Failed to register bundle identifier" | Bundle ID 뒤에 숫자 추가 (예: `com.ls9702.tripshot2`) |
| "Untrusted Developer" | §4-3의 신뢰 설정 |
| 기기가 목록에 안 보임 | 케이블 재연결, iPhone 잠금 해제, 개발자 모드 확인 |
| "Unable to install… maximum number of apps" | 무료 계정 앱 3개 제한. 다른 테스트 앱 삭제 |
| 패키지 해석 실패 | 인터넷 확인 후 File → Packages → Reset Package Caches |

## 9. Mac에서 Claude Code 세션으로 작업하기
1. 저장소 폴더에서 `claude` 실행. `CLAUDE.md`가 자동으로 읽혀 규약을 안다.
2. 첫 지시 예: **"docs/HANDOFF.md의 'Mac 세션이 처음 할 일'을 순서대로 진행하고 결과를 BUILD_LOG.md에 기록해 줘"**
3. iPhone 설치용 UDID: `xcrun devicectl list devices` 결과의 Identifier를 `scripts/device.local`에 저장(커밋되지 않음).
4. 시뮬레이터 이름이 다르면 `SIM="platform=iOS Simulator,name=iPhone 16" scripts/build.sh`처럼 지정.
   `test.sh`는 테스트 전에 시뮬레이터를 부팅하고 앱 권한(위치·카메라·사진·마이크)을 미리 허용한다 — 테스트 호스트가 띄운 권한 대화상자가 남으면 다음 xcodebuild가 10분 이상 멈추기 때문.
5. 작업 후 `scripts/sync.sh`로 push. 클라우드 세션이 그 결과를 이어받는다.

## 10. 저조도 모델 변환 (R1-S7, Zero-DCE++ → Core ML)
앱은 모델이 없어도 빌드·동작한다(감마·섀도우 폴백). 모델을 넣으면 야경 프리셋(저조도 70)의 저장 결과가 Zero-DCE++로 개선된다.
라이선스: Zero-DCE++는 **연구용**(PLAN §7) — 개인 사용 앱에만 쓴다.

1. Python 환경(3.10~3.12 권장. 3.13은 torch/coremltools 휠이 없을 수 있음):
   ```bash
   python3 -m venv ~/.venvs/tripshot-ml && source ~/.venvs/tripshot-ml/bin/activate
   pip install torch coremltools pillow numpy
   ```
2. 원 저장소 클론(가중치 포함, 저장소 밖에 둔다). **Zero-DCE++ 코드·가중치는 `Zero-DCE` 저장소가 아니라 별도 저장소 `Zero-DCE_extension`에 있다**:
   ```bash
   git clone --depth 1 https://github.com/Li-Chongyi/Zero-DCE_extension.git ~/src/Zero-DCE_extension
   ls ~/src/Zero-DCE_extension/Zero-DCE++/snapshots_Zero_DCE++/Epoch99.pth   # 있어야 함 (약 52KB)
   ```
3. 변환(저장소 루트에서). `--check`에 어두운 사진을 주면 PyTorch와 Core ML의 곡선 맵 A 오차를 출력한다:
   ```bash
   python3 tools/convert_zero_dce.py --repo ~/src/Zero-DCE_extension \
       --out TripShot/Resources/ML/ZeroDCEpp.mlpackage --size 512 --check ~/Pictures/night.jpg
   ```
   - 확인: "가중치 로드 … 파라미터 약 10,000개", "A 맵 비교: 최대 오차" 0.02 이하(FLOAT16). 크면 `--fp32`로 다시 변환.
   - `model.py`의 레이어 이름·forward가 스크립트의 `CurveNet`과 다르면(`AttributeError: e_conv…`) `CurveNet.forward`를 원본에 맞게 고친다.
   - `--size`는 `LowLightEnhancer.modelInputSize`(512)와 같아야 한다.
4. `TripShot/Resources/ML/ZeroDCEpp.mlpackage`(수십 KB 예상)를 **커밋**한다. `.mlmodelc`(컴파일 결과)는 gitignore됨.
5. `scripts/build.sh` 후 확인:
   - Xcode 내비게이터에서 `ZeroDCEpp.mlpackage`가 **파일 하나**(Core ML 아이콘)로 보이고 TripShot 타깃의 Compile Sources에 들어 있는지.
     빌드 결과 앱 번들에 `ZeroDCEpp.mlmodelc`가 있는지: `find ~/Library/Developer/Xcode/DerivedData -name ZeroDCEpp.mlmodelc`.
   - XcodeGen이 `.mlpackage`를 폴더(하위 파일 여러 개)로 잡으면 `project.yml`에서 폴더 소스에서 빼고 파일로 추가한다:
     ```yaml
     sources:
       - path: TripShot
         excludes:
           - "**/.gitkeep"
           - "Resources/ML/*.mlpackage/**"
           - "Resources/ML/*.mlpackage"
       - path: TripShot/Resources/ML/ZeroDCEpp.mlpackage
         type: file
         buildPhase: sources
     ```
   - Xcode가 `ZeroDCEpp` Swift 클래스를 자동 생성하지만 앱은 쓰지 않는다(`MLModel`로 직접 호출).
6. 테스트: `scripts/test.sh` → `LowLightTests.testBundledModelEnhancesDarkImage`가 건너뛰지 않고 통과하는지(모델 없으면 XCTSkip).
7. 실기기: 설정 탭 "정보"의 **저조도 모델: 있음** 확인 → 야경 프리셋으로 어두운 장면 촬영·저장. 저장 3초 이내, 과노출·색 틀어짐·노이즈 증폭을 BUILD_LOG에 기록.
   Console.app에서 서브시스템 `com.ls9702.tripshot`, 카테고리 `lowlight`로 추론 시간·폴백 이유를 볼 수 있다.
