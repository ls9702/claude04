# 개인 건강관리 앱 (프로토타입) 개발 계획서

작성일: 2026-09-25 · 상태: **논의용 초안 (v0.1)** · 실행 전 합의 필요 항목은 §10 참조

---

## 1. 목표와 범위

### 1.1 한 줄 요약
모바일 브라우저에서 동작하는 반응형 웹앱(PWA)으로, 로그인한 사용자의 **걸음수·운동·이동 동선·식사 사진(AI 칼로리 계산)·체중 변화**를 기록·시각화하는 개인 건강관리 서비스. 서버는 **NAS 또는 라즈베리파이**에 Docker로 배포한다.

### 1.2 이번 과제 범위 (In scope)
| 구분 | 내용 |
|---|---|
| 타겟 | 모바일 HTTP 반응형 웹 (PWA). 데스크톱에서도 깨지지 않게. |
| 사용자 | 프로토타입 기본 5명 (시드 데이터), N명으로 확장 가능한 구조 |
| 서버 | NAS(Synology/QNAP 등) 또는 라즈베리파이 4/5, Docker Compose 배포 |
| AI | Google AI(Gemini) API로 음식 사진 → 음식명/양/칼로리/영양소 자동 추정 |
| 지도 | Google Maps로 이동 동선 표시 (웹 Geolocation API 기반 수집) |
| 확장성 | 추후 Android/iOS 네이티브 래핑(Capacitor) 가능한 구조 |

### 1.3 이번 과제 범위 밖 (Out of scope, 가이드만 제공)
- 스마트폰 ↔ NAS 실제 네트워크 연결 (DDNS, 포트포워딩, HTTPS 인증서) → **§8 연결 가이드**로 대체
- Android/iOS 스토어 배포, HealthKit/Health Connect 실제 연동 → **§9 확장 가이드**
- 다중 조직/관리자 콘솔, 결제, 소셜 기능

---

## 2. 핵심 제약과 그에 따른 설계 판단

웹앱이기 때문에 반드시 미리 짚고 가야 할 제약이 있다. 이 제약이 기능 설계를 결정한다.

| 제약 | 사실 | 설계 대응 |
|---|---|---|
| **걸음수 자동 수집 불가 (웹)** | 브라우저는 폰의 만보계(HealthKit/Health Connect)에 접근할 수 없다. Google Fit REST API는 2024년 이후 신규 사용이 중단됨. | ① 수동 입력(기본) ② 앱 열어둔 동안 가속도 센서(DeviceMotion)로 근사 카운트(실험 기능) ③ 건강앱 CSV/내보내기 파일 업로드 ④ 네이티브 전환 시 Capacitor 플러그인으로 교체 (§9). 서버 API는 `source` 필드(manual/sensor/import/healthkit/healthconnect)로 처음부터 설계. |
| **백그라운드 위치 추적 불가 (웹)** | 화면이 꺼지거나 탭이 백그라운드로 가면 `watchPosition`이 멈춘다. | "운동 세션 시작/종료" 모델로 설계. 사용자가 세션을 시작하면 화면 켜진 상태에서 추적(Wake Lock API로 화면 꺼짐 방지). 네이티브 전환 시 백그라운드 플러그인으로 교체. |
| **HTTPS 필수** | 카메라, 위치, PWA 설치, Wake Lock, 푸시 알림은 모두 **보안 컨텍스트(HTTPS)**에서만 동작. `localhost`만 예외. | 개발은 localhost, 실제 폰 테스트는 NAS에 HTTPS 필요 → §8에서 3가지 방법 제시 (Tailscale / Cloudflare Tunnel / 자체 인증서+DDNS). **이 항목이 폰 실기기 테스트의 선행 조건**이다. |
| **NAS/라즈베리파이 자원 제한** | ARM64 CPU, RAM 2~8GB. | 컨테이너 2개(app, db)로 최소화. DB는 프로토타입에서 SQLite 파일 → 확장 시 PostgreSQL로 교체 가능하게 ORM 사용. 이미지 리사이즈는 서버에서 처리 후 저장. |
| **AI 비용/지연** | Gemini 이미지 호출은 건당 과금·1~4초 소요. | 업로드 시 서버에서 1024px로 축소 후 전송, 결과 캐시. 사용자가 AI 결과를 **수정 가능**해야 함(추정치이므로). |

---

## 3. 기술 스택 (제안)

> 원칙: 프론트/백엔드 한 언어(TypeScript)로 타입 공유, ARM Docker 이미지 공식 지원, 학습·유지보수 부담 최소.

| 계층 | 선택 | 이유 / 대안 |
|---|---|---|
| 프론트엔드 | **React 18 + Vite + TypeScript + Tailwind CSS**, PWA(vite-plugin-pwa) | 가볍고 Capacitor로 그대로 네이티브 래핑 가능. 대안: Next.js(라즈베리파이엔 무거움), Vue. |
| 상태/데이터 | TanStack Query + Zustand | 서버 상태 캐싱, 오프라인 큐 구현 용이 |
| 차트 | Recharts | 체중·걸음·칼로리 추이 |
| 지도 | Google Maps JavaScript API (`@vis.gl/react-google-maps`) | 요구사항. 대안: Leaflet+OSM(무료, 키 불필요) — API 키 발급이 부담이면 전환 가능 |
| 백엔드 | **Node.js 20 + Fastify + TypeScript** | 경량·빠름. 대안: Python FastAPI(AI 생태계 친화적) — §10 논의 항목 |
| ORM/DB | **Prisma + SQLite**(프로토) → PostgreSQL(확장) | 스키마 하나로 두 DB 지원. 5명 규모엔 SQLite로 충분 |
| 인증 | 이메일+비밀번호, Argon2 해시, JWT(access 15분 + refresh 30일, httpOnly 쿠키) | 5명 프로토라 소셜 로그인 제외. 확장 시 OAuth 추가 |
| AI | **Google Gemini API** (`gemini-2.5-flash`, 이미지 입력 + JSON 스키마 응답) | 요구사항. 키는 서버에만 보관 |
| 파일 저장 | 로컬 볼륨 (`/data/uploads`), sharp로 리사이즈·EXIF 제거 | NAS 공유폴더를 볼륨으로 마운트 |
| 배포 | Docker Compose (linux/arm64 + amd64 멀티아키), Caddy 리버스 프록시(자동 HTTPS) | Synology Container Manager / Portainer / 라즈베리파이 모두 동일 파일 사용 |
| 저장소 구조 | pnpm 모노레포: `apps/web`, `apps/api`, `packages/shared`(타입·zod 스키마) | 프론트/백 계약을 코드로 공유 |
| 테스트 | Vitest(단위) + Playwright(모바일 뷰포트 E2E) | Playwright에서 iPhone/Pixel 에뮬레이션 |

---

## 4. 기능 명세

### 4.1 필수 기능 (요구사항에 명시)
| # | 기능 | 상세 |
|---|---|---|
| F1 | **로그인/사용자** | 이메일·비밀번호 로그인, 세션 유지, 로그아웃, 비밀번호 변경. 시드 유저 5명. `role: user/admin` 필드로 확장 대비. |
| F2 | **걸음수** | 일별 걸음수 기록(수동 입력, 센서 근사, 파일 가져오기). 일/주/월 차트, 목표 대비 달성률. |
| F3 | **운동 트래킹** | 운동 세션(걷기/달리기/자전거/기타) 시작→종료. 시간·거리·평균속도·소모칼로리(MET 공식). GPS 있으면 경로 저장. |
| F4 | **이동 동선(지도)** | 세션 중 Geolocation `watchPosition`으로 좌표 수집(5~10초 간격, 정확도 필터링). Google Maps에 폴리라인으로 표시. 일자별 동선 보기. |
| F5 | **식사 사진 → AI 칼로리** | 카메라 촬영/갤러리 선택 → 서버 업로드 → Gemini 분석 → 음식 항목 리스트(이름, 추정량, kcal, 탄/단/지) 반환 → 사용자 확인·수정 → 식사 기록 저장. 끼니(아침/점심/저녁/간식) 태깅. |
| F6 | **체중 변화** | 체중(+선택: 체지방률) 기록, 추이 차트, BMI 자동 계산, 목표 체중 대비 진행률. |

### 4.2 기본적으로 필요하다고 판단한 추가 기능
| # | 기능 | 이유 |
|---|---|---|
| F7 | **프로필/목표 설정** | 키·생년·성별·활동량 → BMR/TDEE 계산 → 일일 목표 칼로리·걸음·체중 목표. 모든 통계의 기준값. |
| F8 | **오늘 대시보드** | 첫 화면. 오늘 걸음/섭취 kcal/소모 kcal/물/체중을 한눈에. 목표 링 UI. |
| F9 | **수분 섭취** | 한 탭으로 +250ml. 건강앱의 표준 항목. |
| F10 | **수면 기록** | 취침/기상 시각 수동 입력, 수면 시간 추이. (센서 없음, 입력만) |
| F11 | **주간/월간 리포트** | 평균 걸음, 칼로리 수지(섭취−소모), 체중 변화량, 운동 횟수 요약. |
| F12 | **PWA + 오프라인** | 홈 화면 설치, 앱 아이콘, 오프라인 시 입력을 로컬 큐에 저장 후 재접속 시 동기화. NAS 접속이 끊겨도 기록 가능. |
| F13 | **알림(선택)** | Web Push로 "오늘 체중 기록 안 함" 등 리마인더. iOS는 홈화면 설치 후에만 동작. |
| F14 | **데이터 내보내기/삭제** | 내 데이터 CSV/JSON 다운로드, 계정 데이터 전체 삭제. 개인 건강 정보라 기본 제공. |
| F15 | **관리자(최소)** | admin이 유저 추가/비활성화. 5명 → N명 확장의 최소 도구. |

### 4.3 화면 목록 (모바일 기준, 하단 탭 5개)
```
[홈]      오늘 대시보드, 빠른 입력 버튼(체중/물/사진)
[활동]    걸음 차트, 운동 세션 목록, 세션 시작 버튼 → 지도 추적 화면
[식사]    오늘 식사 타임라인, 카메라 버튼 → AI 분석 → 확인 화면
[신체]    체중/BMI 차트, 수면
[더보기]  프로필·목표, 리포트, 내보내기, 설정, 로그아웃
```

---

## 5. 시스템 구성

```
┌──────────── 스마트폰 (브라우저 / PWA) ────────────┐
│ React PWA                                          │
│  ├ Geolocation API  → 좌표                         │
│  ├ Camera (input capture / getUserMedia) → 사진    │
│  ├ DeviceMotion (실험) → 걸음 근사                 │
│  ├ Service Worker → 오프라인 큐, 캐시, 푸시        │
│  └ Google Maps JS SDK ← 동선 렌더링                │
└───────────────────────┬────────────────────────────┘
                        │ HTTPS (§8 연결 가이드)
┌───────────────────────▼──── NAS / Raspberry Pi ────┐
│ docker compose                                     │
│  ├ caddy   :443  자동 TLS, 리버스 프록시           │
│  ├ api     :3000 Fastify + Prisma                   │
│  │    ├ /data/app.db      (SQLite, 볼륨)           │
│  │    └ /data/uploads     (사진, 볼륨)             │
│  └ web     정적 빌드 (caddy가 서빙)                 │
└───────────────────────┬────────────────────────────┘
                        │ 서버 → 외부 (키는 서버에만)
              Google Gemini API (음식 사진 분석)
```

---

## 6. 데이터 모델 (초안)

```
User            id, email, passwordHash, name, role, createdAt, isActive
Profile         userId, heightCm, birthDate, sex, activityLevel,
                goalWeightKg, goalStepsPerDay, goalKcalPerDay, timezone
WeightLog       id, userId, measuredAt, weightKg, bodyFatPct?, note
StepLog         id, userId, date, steps, source(manual|sensor|import|healthkit|healthconnect)
                UNIQUE(userId, date, source)
WorkoutSession  id, userId, type, startedAt, endedAt, distanceM, durationS,
                avgSpeedMps, kcalBurned, note
LocationPoint   id, sessionId, ts, lat, lng, accuracyM, altitudeM?, speedMps?
Meal            id, userId, eatenAt, mealType(breakfast|lunch|dinner|snack),
                photoPath?, totalKcal, note, aiRaw(json)
MealItem        id, mealId, name, quantity, unit, kcal, carbG, proteinG, fatG,
                confidence, isEdited
WaterLog        id, userId, ts, ml
SleepLog        id, userId, sleptAt, wokeAt, quality?
RefreshToken    id, userId, tokenHash, expiresAt
PushSubscription id, userId, endpoint, keys(json)
```
- 모든 시각은 UTC 저장, 프로필 timezone으로 표시.
- `LocationPoint`는 세션당 수천 건이 될 수 있어 별도 테이블 + 인덱스(sessionId, ts).
- Postgres 전환 시 `LocationPoint`만 PostGIS 고려, 나머지는 그대로.

---

## 7. AI 칼로리 분석 설계

1. 클라이언트: 사진 선택 → 브라우저에서 1280px로 1차 축소(업로드 용량↓) → `POST /meals/analyze` (multipart).
2. 서버: sharp로 1024px 재축소·EXIF(위치정보) 제거 → 저장 → Gemini 호출.
3. 프롬프트: "사진 속 음식을 항목별로 식별하고 1인분 기준 추정량·kcal·탄단지·확신도(0~1)를 JSON 스키마로 반환. 한국 음식 명칭 우선." + **응답 JSON 스키마 강제**(structured output).
4. 응답을 `MealItem[]` 초안으로 반환 → 사용자가 항목 수정/삭제/추가 후 저장(`isEdited` 기록).
5. 실패/타임아웃(8초) 시: 수동 입력 폼으로 자연스럽게 전환. AI는 보조 수단.
6. 비용 가드: 사용자당 일 50회 제한, 동일 파일 해시 재요청 시 캐시 반환.
7. 안전: 사용자에게 "추정치이며 의학적 조언이 아님" 고지 문구 고정 노출.

---

## 8. 스마트폰 ↔ NAS 연결 가이드 (본 과제에서는 가이드만)

폰의 카메라·위치·PWA는 **HTTPS가 아니면 동작하지 않는다.** 아래 셋 중 하나를 선택하면 된다. 프로토타입에는 **A안 권장**.

| 안 | 방법 | 장점 | 단점 |
|---|---|---|---|
| **A. Tailscale (권장)** | NAS와 폰에 Tailscale 설치 → 사설망 IP 부여 → `tailscale cert`로 `nas.tailnet.ts.net` HTTPS 인증서 자동 발급 → Caddy에 적용 | 포트포워딩·DDNS 불필요, 외부 노출 없음, 10분 설정 | 폰에 Tailscale 앱 필요, 5명 모두 같은 tailnet에 초대해야 함(무료 3명→개인 플랜 확인 필요) |
| **B. Cloudflare Tunnel** | 도메인 하나 보유 → `cloudflared` 컨테이너 추가 → 공개 URL | 포트포워딩 불필요, 공개 접속 가능, 무료 | 도메인 필요, 트래픽이 Cloudflare 경유, 업로드 100MB 제한 |
| **C. DDNS + 포트포워딩 + Let's Encrypt** | 공유기 443 → NAS, Synology DDNS/DuckDNS, Caddy가 인증서 자동 발급 | 완전 자체 운영 | 공인 IP·공유기 설정 필요, 외부 노출로 보안 관리 필요 |

공통 절차(문서로 제공 예정, `docs/DEPLOY.md`):
1. NAS/라즈베리파이에 Docker + Compose 설치 (Synology: Container Manager, RPi: `curl -fsSL get.docker.com`).
2. `docker-compose.yml`, `.env`(JWT 시크릿, GEMINI_API_KEY, GOOGLE_MAPS_KEY, 도메인) 복사.
3. `docker compose up -d` → `/data` 볼륨 위치를 NAS 공유폴더로 지정(백업 편의).
4. 폰 브라우저로 `https://<도메인>` 접속 → "홈 화면에 추가".
5. 시드 계정으로 로그인 → 위치/카메라 권한 허용.

라즈베리파이 주의: 64bit OS 필수(arm64 이미지), microSD 대신 SSD 권장(SQLite 쓰기 수명), 스왑 확인.

---

## 9. Android / iOS 확장 가이드 (추후)

- **Capacitor**로 동일 React 빌드를 래핑 → 앱스토어/플레이스토어 배포 가능. 코드 변경 최소.
- 교체되는 부분(어댑터 패턴으로 미리 분리):
  | 기능 | 웹 구현 | 네이티브 구현 |
  |---|---|---|
  | 걸음수 | 수동/센서 근사 | `capacitor-health` → HealthKit(iOS) / Health Connect(Android) 일별 동기화 |
  | 위치 | `watchPosition` (포그라운드) | `@capacitor-community/background-geolocation` |
  | 카메라 | `<input capture>` | `@capacitor/camera` |
  | 푸시 | Web Push | FCM/APNs |
- 프론트 코드에서 `platform/steps.ts`, `platform/location.ts`, `platform/camera.ts` 인터페이스를 두고 웹 구현을 먼저 작성. 네이티브는 같은 인터페이스의 다른 구현체.
- 서버 API는 `StepLog.source`처럼 이미 다중 소스를 전제하므로 변경 없음.

---

## 10. 논의가 필요한 결정 사항 (실행 전 확인)

| # | 질문 | 제 추천 | 영향 |
|---|---|---|---|
| Q1 | 백엔드 언어: **Node/TypeScript** vs Python/FastAPI | Node (프론트와 타입 공유, 컨테이너 1개 언어) | 전체 구조 |
| Q2 | 지도: **Google Maps**(키 발급·결제계정 등록 필요, 월 $200 무료 크레딧) vs Leaflet+OpenStreetMap(무료·키 없음) | 요구사항대로 Google Maps, 단 키 발급이 부담이면 Leaflet 전환은 반나절 | 비용·설정 |
| Q3 | Gemini 모델: **gemini-2.5-flash**(저렴·빠름) vs gemini-2.5-pro(정확·비쌈) | flash로 시작, 프롬프트/스키마로 정확도 보완 | AI 비용 |
| Q4 | 걸음수 센서 근사(DeviceMotion) 실험 기능을 **포함**할지 | 포함하되 "실험" 라벨. 정확도 낮음을 명시 | 개발 1~2일 |
| Q5 | DB: **SQLite**(프로토) vs 처음부터 PostgreSQL | SQLite. Prisma라 전환 비용 낮음 | 운영 단순성 |
| Q6 | HTTPS 연결 방식 (§8 A/B/C) | A. Tailscale | 실기기 테스트 가능 시점 |
| Q7 | 배포 대상 NAS 기종/라즈베리파이 모델 및 OS | 알려주시면 배포 문서를 맞춤 작성 | DEPLOY.md |
| Q8 | 언어/UI: **한국어 단일** vs 다국어 준비 | 한국어 단일, 문자열은 상수 파일로 분리 | 소소 |
| Q9 | Web Push 알림(F13)을 이번 범위에 넣을지 | 후순위(있으면 좋음), 마지막 단계에 시간 남으면 | 일정 |
| Q10 | API 키(Gemini, Maps)는 누가 발급? | 사용자 측 발급 → `.env`에 입력. 저장소에는 절대 커밋하지 않음 | 보안 |

---

## 11. 실행 단계 (마일스톤)

각 단계 끝에 **실행 가능한 결과물**이 있도록 나눈다. 일정은 전업 기준 대략치.

| 단계 | 산출물 | 완료 기준 | 예상 |
|---|---|---|---|
| **P0 기반** | 모노레포, Docker Compose, CI(lint/test), Prisma 스키마·시드 5명, Caddy | `docker compose up` 후 로그인 화면이 폰에서 뜸 | 1일 |
| **P1 인증·프로필·대시보드** | F1, F7, F8 뼈대, 하단 탭 네비 | 5명 로그인, 목표 설정, 빈 대시보드 | 2일 |
| **P2 신체·활동 기록** | F2(수동/가져오기), F6, F9, F10, 차트 | 걸음·체중·물·수면 입력과 추이 그래프 | 2일 |
| **P3 식사 + AI** | F5, 카메라, Gemini 연동, 수정 UI | 사진 찍고 5초 내 칼로리 항목 확인·저장 | 3일 |
| **P4 운동·지도** | F3, F4, Wake Lock, Google Maps 폴리라인 | 산책 세션 시작→종료 후 지도에 경로 표시 | 3일 |
| **P5 PWA·리포트·내보내기** | F11, F12, F14, F15, (F13 선택) | 홈화면 설치, 오프라인 입력 동기화, CSV 내보내기 | 2일 |
| **P6 배포·문서** | `docs/DEPLOY.md`(§8), `docs/NATIVE.md`(§9), README, arm64 이미지 검증 | NAS/RPi에서 실제 실행, 폰 실기기 E2E 통과 | 1일 |
| **P7 걸음 센서 실험(선택, Q4)** | DeviceMotion 근사 카운터 | "실험" 토글로 제공 | 1~2일 |

합계 약 **14~16일**. P0→P1→P2는 순차, P3와 P4는 병행 가능.

---

## 12. 비기능 요구사항

- **보안**: 비밀번호 Argon2, JWT httpOnly+SameSite, 업로드 EXIF 제거, 파일 타입·크기 검증(10MB), API rate limit, `.env`는 저장소 제외, 건강 데이터는 본인만 조회(모든 쿼리에 userId 스코프).
- **성능**: 첫 로드 < 200KB gz, 대시보드 API < 200ms(SQLite 로컬), 사진 분석 < 8초.
- **호환**: iOS Safari 16+, Android Chrome 110+. 데스크톱 Chrome/Edge.
- **백업**: `/data` 폴더 통째로 NAS 스냅샷. 복원 절차 문서화.
- **로그/모니터링**: 구조화 로그(pino), `/healthz` 엔드포인트, Docker 헬스체크.
- **접근성**: 터치 타겟 44px, 다크모드 지원, 시스템 폰트 크기 존중.

---

## 13. 저장소 구조 (예정)

```
claude04/
├─ apps/
│  ├─ web/            React PWA
│  └─ api/            Fastify + Prisma
├─ packages/
│  └─ shared/         zod 스키마·타입·단위 변환·MET 테이블
├─ deploy/
│  ├─ docker-compose.yml
│  ├─ Caddyfile
│  └─ .env.example
├─ docs/
│  ├─ PLAN.md         (이 문서)
│  ├─ DEPLOY.md       NAS/RPi 배포 + 연결 가이드
│  └─ NATIVE.md       Android/iOS 확장 가이드
└─ README.md
```

---

## 14. 다음 행동
1. §10 항목에 대해 답변/의견 → 계획서 v0.2 확정.
2. 확정 후 P0부터 착수. 단계마다 PR 단위로 커밋해 확인 가능하게 진행.
