# 빌드·테스트 로그 (Mac 세션이 기록, 최신이 위)

형식:
```
## YYYY-MM-DD HH:MM · 커밋 <hash> · build.sh | test.sh | install-device.sh
결과: 성공 / 실패
환경: macOS x.y, Xcode x.y, iOS x.y (기기)
오류 요약: (실패 시, 파일:줄 — 메시지. 전체 로그는 붙이지 말고 핵심만)
실기기 관찰: (설치 후 동작·성능·메타데이터 확인 결과)
```

---

## 2026-09-26 10:30 · 커밋 f61c7ac(+fix) · build.sh | test.sh | 모델 변환 · 시뮬레이터
결과: **성공** (build 오류 0 · test **121/121** 통과, skip 0 · Zero-DCE++ 모델 변환·번들 확인). 실기기 설치는 **아직**(아래)
환경: macOS 26.6.2, Xcode 27.0 (27A266a) + **Metal Toolchain 27A266a 추가 설치**, iOS 27.0 시뮬레이터 iPhone 17. Python 3.12 venv(torch 2.14, coremltools 9.x)
오류 요약 (Mac에서 수정, `fix(R1-S7)` 커밋):
- 빌드: `error: cannot execute tool 'metal' due to missing Metal Toolchain` — Xcode 26+는 Metal 컴파일러가 별도 다운로드. `xcodebuild -downloadComponent MetalToolchain` 후 해결. MAC_SETUP §1에 추가 필요(아래 메모)
- `TripShot/Enhance/LowLight.swift:84` — **iOS 27 시뮬레이터에서 Core ML GPU 경로(.all / .cpuAndGPU)가 이 FP16 mlprogram 출력을 전부 0으로 반환** → `testBundledModelEnhancesDarkImage` 실패(출력 = 입력). `.cpuOnly`로는 정상(A −0.336~−0.216, PyTorch와 일치). `#if targetEnvironment(simulator)`에서만 `.cpuOnly`로 변경. 실기기는 `.all` 그대로 — **iPhone 12 Pro에서 실제 출력이 0이 아닌지 확인 필요**(설정 탭 "저조도 모델: 있음" + 야경 저장 결과)
- `scripts/test.sh` — 테스트 호스트 앱이 띄운 **위치 권한 대화상자가 홈 화면에 남아** 다음 xcodebuild가 종료 대기로 10분 이상 멈춤(2회 재현). 테스트 전에 시뮬레이터 부팅 + `simctl privacy grant`(location·camera·photos·microphone)로 해결, 57초에 완료
- `docs/MAC_SETUP.md` §10, `tools/convert_zero_dce.py` 주석 — Zero-DCE++ 코드·가중치는 `Zero-DCE` 저장소가 아니라 **`Zero-DCE_extension`** 저장소에 있음. 주소 정정
모델 변환: `tools/convert_zero_dce.py` 스크립트는 원본 `model.py`와 일치, 수정 없이 동작. 파라미터 10,561개, 합성 야경 샘플에서 PyTorch vs Core ML A 맵 최대 오차 **0.00156**(평균 0.00076, FP16 기준 0.02 이내). `ZeroDCEpp.mlpackage` 52KB 커밋. XcodeGen이 파일 하나로 인식해 `project.yml` 수정 불필요, 앱 번들에 `ZeroDCEpp.mlmodelc` 포함 확인
남은 경고(미수정): `UIRequiresFullScreen` deprecated · `EnhanceViewModelTests.swift:277,296` "no 'async' operations occur within 'await'"(클로저 안 `await vm.cancelBatch()`; 컴파일러가 이 줄 때문에 -quiet 모드에서 `error: … exit code 0 but produced no further output`을 찍지만 빌드·테스트는 정상)
시뮬레이터 관찰: 121개 모두 0.3초 이내. 실기기 측정 항목(fps·발열·인물 워프·10장 일괄·저조도 3초)은 시뮬레이터로 불가
실기기 관찰: **미실시** — 개발자 모드·UDID 등록 후 `scripts/install-device.sh` 예정. HANDOFF "Mac 세션이 할 일" 4번 항목 그대로 남음
메모(MAC_SETUP 보강 제안): §1에 "Xcode 26+는 `xcodebuild -downloadComponent MetalToolchain`" 추가, §9에 "시뮬레이터 테스트 전 `simctl privacy grant`는 test.sh가 자동 처리" 추가 → 이번 커밋에 반영

## 2026-09-25 23:55 · 커밋 e0250fc(+fix) · build.sh | test.sh | 시뮬레이터 실행
결과: **성공** (build 오류 0 · test 59/59 통과 · 시뮬레이터 런치 정상). 실기기 설치는 이번 체크포인트에서 생략(아래 참고)
환경: macOS 26.6.2, Xcode 27.0 (27A266a), iOS 27.0 시뮬레이터 iPhone 17. XcodeGen 2.46.0. YouTubeKit 패키지 해석 정상
오류 요약 (Mac에서 수정, `fix(R1-S0)` 커밋):
- `project.yml` — TripShotTests 타깃에 `GENERATE_INFOPLIST_FILE`이 없어 테스트 번들 코드 서명 실패("target does not have an Info.plist"). 설정 추가
- `TripShot/Library/Models.swift:89` — `ShotSpec`의 합성 Codable은 `id: UUID = UUID()` 기본값이 있어도 JSON에 `id` 키를 요구 → `default-templates.json`(id 없음) 디코딩 실패 → `testDefaultTemplatesDecode` 실패. **앱에서도 기본 템플릿 3종 대신 fallback 1종("자유")만 로드되던 실제 버그.** `init(from:)`를 직접 구현해 `id`·`hint`를 선택 키로 처리
남은 경고 (동작 영향 없음, 미수정):
- `UIRequiresFullScreen` iOS 26부터 deprecated (project.yml info). 제거해도 무방
- `TripShotTests/EnhanceViewModelTests.swift:46,48` — FakeSaver가 async 컨텍스트에서 `NSLock.lock()` 사용. Swift 6 모드에서는 오류가 되므로 언젠가 `withLock` 등으로 교체 권장
- 테스트 수: HANDOFF에는 S1 25 + S2 21 + S3 17 = 63으로 적혀 있으나 실제 실행된 테스트는 59개(템플릿 2 포함)
시뮬레이터 관찰: 런치 즉시 촬영 탭, 사진/쇼츠 세그먼트, 탭 4개(촬영·보정·쇼츠·설정) 표시, 위치 권한 문구 정상. SwiftData 시드 크래시 없음. 시뮬레이터는 카메라가 없어 프리뷰는 검정
실기기 관찰: **미실시** — 사용자 결정으로 폰 설치는 R1-S4(라이브 보정 프리뷰, 카메라 중심) 체크포인트로 미룸. 촬영·GPS 기록·일괄 10장 성능·프리셋 전환 지연은 그때 측정

