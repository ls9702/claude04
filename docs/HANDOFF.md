# 세션 핸드오프 보드

두 세션(클라우드 = 지휘·서브에이전트 작성·리뷰 / Mac = 빌드 위주)이 공유하는 현재 상태. **작업 전 읽고, 작업 후 갱신한다.**

## ▶ 다음 시작 지점
**Mac 세션 (익일) — 빌드 체크포인트 R1-S4~S6, 실기기 첫 설치**: `git pull` → `scripts/build.sh` → `scripts/test.sh`(약 109개 예상) → `scripts/install-device.sh` → 아래 "Mac 세션이 할 일" 측정 → `docs/BUILD_LOG.md`. 먼저 볼 것: `default.metallib` 생성(`testSkinLikelihoodKernel`, `testWarpKernelChangesOnlyInsideRadius`), 프리뷰 상하 방향, fps.
**클라우드 세션 다음 단계**: **R1-S7 저조도** — Zero-DCE++ Core ML 변환은 Mac에서 해야 하므로, 클라우드는 모델 래퍼·타일 처리·야경 프리셋 연결 코드와 변환 스크립트(`tools/convert_zero_dce.py`)를 작성하고 Mac 세션이 변환·번들 추가. 실기기 결과가 오면 그 수정부터.

## 진행 중
| 세션 | 단계 | 상태 | 시작 | 메모 |
|---|---|---|---|---|
| 클라우드 | R1-S7 | 작성 중 (Opus 5.5 서브에이전트 위임) | 09-26 | Zero-DCE++ 변환 스크립트·Core ML 래퍼·타일·폴백. 모델 변환은 Mac |
| Mac | R1-S0~S3 | 빌드 체크포인트 완료(09-25) | 09-25 | 시뮬레이터 빌드·테스트 통과. 실기기 미설치(R1-S4 때). 상세 BUILD_LOG |

## 단계 상태
| 단계 | 상태 | 커밋 | 비고 |
|---|---|---|---|
| R1-S0 골격 | 빌드·테스트 통과(시뮬레이터) | 8318c82 | Mac fix: 테스트 타깃 Info.plist, ShotSpec 디코더(BUILD_LOG 09-25) |
| R1-S1 보정 엔진 | 빌드·테스트 통과(시뮬레이터) | 09805c2 | REVIEW_LOG 참고 |
| R1-S2 저장·메타데이터 | 빌드·테스트 통과(시뮬레이터) · 실기기 GPS 미확인 | 8d105f9 | REVIEW_LOG 참고 |
| R1-S3 앨범 보정 화면 | 빌드·테스트 통과(시뮬레이터) · 실기기 성능 미측정 | b33f8b2 | 빌드 체크포인트 통과(09-25). 총 테스트 59개 |
| R1-S4 라이브 보정 프리뷰 | 작성·리뷰 완료 · 빌드 미검증 | 6ae044e | **빌드 체크포인트 — 실기기 첫 설치**. 테스트 17개 추가 |
| R1-S5 인물 모드 ① 피부 | 작성·리뷰 완료 · 빌드 미검증 | 4e4e910 | Metal 커널(project.yml 플래그 추가). 테스트 17개 추가 |
| R1-S6 인물 모드 ② 윤곽 | 작성·리뷰 완료 · 빌드 미검증 | ecb4dec | **빌드 체크포인트** — S4~S6 한 번에 실기기 검증. 테스트 16개 추가 |
| R1-S7 저조도 | 대기 | | Mac에서 Core ML 변환 |
| R1-S8 릴리즈 1 마무리 | 대기 | | **릴리즈 1** |
| R2-S1 ~ R2-S5 | 릴리즈 1 이후 | | **릴리즈 2** |

## Mac 세션이 할 일 (빌드 체크포인트 R1-S4~S6 — 실기기 첫 설치)
1. `git pull` → `scripts/build.sh` → 컴파일 오류는 `docs/REVIEW_LOG.md` S4·S5·S6 "컴파일 확신이 낮은 지점"부터 → `fix(R1-Sn): …` 커밋
2. `scripts/test.sh` (약 109개). Metal 커널 테스트 2개가 실패하면 `project.yml`의 `MTL_COMPILER_FLAGS`/`MTLLINKER_FLAGS`와 `.metal` 컴파일 여부부터
3. `docs/MAC_SETUP.md` §4 → `scripts/install-device.sh`
4. iPhone 12 Pro 측정·확인 (BUILD_LOG에 기록):
   - **S4 라이브**: 상단 DEBUG 통계 fps(자동/흑백/음식 프리셋), 콘솔 "프리뷰 프레임 크기", 프리뷰 방향(뒤집힘이면 `MetalPreviewView`의 `isFlipped`만 반전), 색·채도, 탭 포커스 위치, 핀치 줌, 촬영 → 사진 앱 "편집됨"·되돌리기·위치·날짜, 가로 촬영 방향, 연속 5장, 10분 발열
   - **S5 피부**: 인물 모드 켜고 셀피 fps(1명/여럿), 얼굴 배지, 턱선·이마·눈가 마스크 경계, 붉은 잡티 처리, 치아, 저장본이 프리뷰와 비슷한지
   - **S6 윤곽**: 윤곽 20·100에서 턱선 주변 배경 휨, 눈 100에서 눈썹·안경 왜곡, 기울인 얼굴 대칭, 라이브 워프 떨림, 두 얼굴 겹침
   - 보정 탭: 10장 일괄 저장 시간, 슬라이더 반응(검출이 렌더마다 돌아 느리면 REVIEW_LOG S5 권고대로 캐시)
5. 튜닝 값(`PreviewQuality.baseDimension`, `LivePipeline.autoRefreshInterval`, `WarpPlan` 상수, `SkinSmoothing` 상수, 기본 faceSlim)은 직접 바꿔 커밋해도 됨. 이 파일 갱신

## 논의 필요 (설계 변경 제안·질문)
- (없음)

## 결정 이력
- 09-25 릴리즈 1 = 카메라, 릴리즈 2 = 동영상. 단계별 진행, 주 단위 재개. 각 단계는 클라우드 세션에서 Opus 5.5 서브에이전트 작성 + Fable 리뷰, Mac은 빌드 위주(코드 수정 가능) (`CLAUDE.md`, `PLAN.md` §8·§11)
