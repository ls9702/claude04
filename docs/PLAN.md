# 개인 건강관리 앱 (프로토타입) 개발 계획서

작성일: 2026-09-25 · 상태: **v0.2 확정 (논의 반영, 실행 착수)** · 결정 이력은 §10 참조

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
| **걸음수 자동 수집 불가 (웹)** | 브라우저는 폰의 만보계(HealthKit/Health Connect)에 접근할 수 없다. Google Fit REST API는 2024년 이후 신규 사용이 중단됨. | **직접 측정은 범위 밖(Q4)**. ① **iPhone 단축어(Shortcuts) 자동화**: 매일 정해진 시각에 건강앱 걸음수를 읽어 서버 API로 POST (설치 1회, 이후 자동) ② 건강앱 내보내기 파일 업로드(Apple Health XML zip, 삼성헬스 CSV) ③ 수동 입력 ④ 네이티브 전환 시 Capacitor 플러그인으로 교체(§9). 서버 API는 `source` 필드로 처음부터 다중 소스 설계. |
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
| 지도 | Google Maps JavaScript API (`@vis.gl/react-google-maps`) | 확정. API 키는 사용자 제공(Q2) |
| 백엔드 | **Node.js 22 + Fastify + TypeScript** | 확정(Q1) |
| ORM/DB | **Drizzle ORM + better-sqlite3**(프로토) → PostgreSQL(확장) | 스키마 하나로 두 DB 지원, 라즈베리파이에서 가벼움. (v0.1의 Prisma는 7.x부터 드라이버 어댑터 필수·엔진 무거워 교체) |
| 인증 | 이메일+비밀번호, Argon2 해시, JWT(access 15분 + refresh 30일, httpOnly 쿠키) | 5명 프로토라 소셜 로그인 제외. 확장 시 OAuth 추가 |
| AI | **Google Gemini API** (`gemini-2.5-pro`, 이미지 입력 + JSON 스키마 응답) | 확정(Q3). 키는 서버에만 보관. 모델명은 `.env`로 교체 가능 |
| 파일 저장 | 로컬 볼륨 (`/data/uploads`), sharp로 리사이즈·EXIF 제거 | NAS 공유폴더를 볼륨으로 마운트 |
| 배포 | Docker Compose (linux/arm64 + amd64 멀티아키), Caddy 리버스 프록시(자동 HTTPS) | **1차 서버는 라즈베리파이 4**, NAS는 백업 대상(§8.1 참조) |
| 저장소 구조 | pnpm 모노레포: `apps/web`, `apps/api`, `packages/shared`(타입·zod 스키마) | 프론트/백 계약을 코드로 공유 |
| 테스트 | Vitest(단위) + Playwright(모바일 뷰포트 E2E) | Playwright에서 iPhone/Pixel 에뮬레이션 |

---

## 4. 기능 명세

### 4.1 필수 기능 (요구사항에 명시)
| # | 기능 | 상세 |
|---|---|---|
| F1 | **로그인/사용자** | 이메일·비밀번호 로그인, 세션 유지, 로그아웃, 비밀번호 변경. 시드 유저 5명. `role: user/admin` 필드로 확장 대비. |
| F2 | **걸음수** | 일별 걸음수 기록. 입력 경로: ① iPhone 단축어 자동 전송(개인 API 토큰 사용) ② 건강앱 내보내기 파일 가져오기(Apple Health / 삼성헬스) ③ 수동 입력. 일/주/월 차트, 목표 대비 달성률. 같은 날 여러 소스가 있으면 우선순위(자동>가져오기>수동)로 대표값 선택. |
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
| F13 | ~~알림~~ | **미포함(Q9)**. 추후 Web Push 추가 가능하도록 `PushSubscription` 테이블만 예약. |
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

## 8. 스마트폰 ↔ 서버 연결 가이드 (본 과제에서는 가이드만)

### 8.1 서버 하드웨어 판단 (Q7)
- **Synology DS112**(2012, Marvell Kirkwood ARMv5)와 **Realtek RTD1296 계열**(DS118/DS218/DS220j 등 저소음 모델)은 모두 Synology Container Manager(Docker)를 지원하지 않는다. 정확한 모델명을 확인해 주시면 재판단하겠지만, 두 후보 모두 앱 서버로는 부적합하다.
- 따라서 **라즈베리파이 4가 앱 서버**(Docker Compose 전체 실행), **NAS는 백업 저장소**로 역할을 나눈다.
  - RPi4 `/data`(DB + 사진)를 매일 새벽 NAS 공유폴더로 `rsync`(cron) → NAS 스냅샷/하이퍼백업으로 2차 보호.
  - 또는 NAS 폴더를 NFS로 RPi4에 마운트해 사진(`/data/uploads`)만 NAS에 직접 저장. SQLite 파일은 NFS 위에 두면 잠금 문제가 있어 **반드시 RPi4 로컬 SSD/SD에** 둔다.
- RPi4 권장 사양: 4GB 이상 RAM, 64bit Raspberry Pi OS, USB SSD 부팅(SD 카드 쓰기 수명 보호).

### 8.2 HTTPS 연결 방식

폰의 카메라·위치·PWA는 **HTTPS가 아니면 동작하지 않는다.** 아래 셋 중 **A안(Tailscale)으로 확정(Q6)**. 나머지는 참고용.

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

## 10. 결정 이력 (2026-09-25 논의 결과)

| # | 질문 | 결정 | 비고 |
|---|---|---|---|
| Q1 | 백엔드 언어 | **Node/TypeScript** | 추천안 |
| Q2 | 지도 | **Google Maps**, API 키는 사용자 제공 | `.env`의 `GOOGLE_MAPS_API_KEY` |
| Q3 | Gemini 모델 | **gemini-2.5-pro** | 정확도 우선. flash 대비 비용·지연 큼 → 결과 캐시·일일 한도 유지 |
| Q4 | 걸음수 수집 | **직접 측정 제외**. 폰에서 간단히 내보내 연동 | iPhone 단축어 자동 전송 + 건강앱 파일 가져오기 + 수동 (§2, §4.1 F2, `docs/STEPS.md`) |
| Q5 | DB | **SQLite** | ORM은 Drizzle로 변경(§3) |
| Q6 | HTTPS 연결 | **Tailscale** | §8 A안 |
| Q7 | 서버 하드웨어 | Synology(DS112 또는 Realtek 저소음 모델) + **라즈베리파이 4** | **NAS는 Docker 불가 가능성 높음 → RPi4를 앱 서버로, NAS는 백업 저장소**(§8.1) |
| Q8 | 언어 | **한국어 단일** | 문자열은 `apps/web/src/i18n/ko.ts`에 모아 둠 |
| Q9 | Web Push 알림 | **미포함** | 테이블만 예약 |
| Q10 | API 키 발급 | **개인 계정** | 저장소에 키 커밋 금지, `.env.example`만 제공 |
| 추가 | **디자인** | **Apple 디자인 철학(HIG) 전면 차용** | §15 |

## 11. 실행 단계 (마일스톤)

각 단계 끝에 **실행 가능한 결과물**이 있도록 나눈다. 일정은 전업 기준 대략치.

| 단계 | 산출물 | 완료 기준 | 예상 |
|---|---|---|---|
| **P0 기반** | 모노레포, Docker Compose, CI(lint/test), Prisma 스키마·시드 5명, Caddy | `docker compose up` 후 로그인 화면이 폰에서 뜸 | 1일 |
| **P1 인증·프로필·대시보드** | F1, F7, F8 뼈대, 하단 탭 네비 | 5명 로그인, 목표 설정, 빈 대시보드 | 2일 |
| **P2 신체·활동 기록** | F2(단축어 API/가져오기/수동), F6, F9, F10, 차트 | 걸음·체중·물·수면 입력과 추이 그래프 | 2일 |
| **P3 식사 + AI** | F5, 카메라, Gemini 연동, 수정 UI | 사진 찍고 5초 내 칼로리 항목 확인·저장 | 3일 |
| **P4 운동·지도** | F3, F4, Wake Lock, Google Maps 폴리라인 | 산책 세션 시작→종료 후 지도에 경로 표시 | 3일 |
| **P5 PWA·리포트·내보내기** | F11, F12, F14, F15 | 홈화면 설치, 오프라인 입력 동기화, CSV 내보내기 | 2일 |
| **P6 배포·문서** | `docs/DEPLOY.md`(§8), `docs/NATIVE.md`(§9), README, arm64 이미지 검증 | NAS/RPi에서 실제 실행, 폰 실기기 E2E 통과 | 1일 |

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
1. ~~§10 항목 답변~~ → 반영 완료(v0.2).
2. P0부터 착수. 단계마다 커밋해 확인 가능하게 진행.
3. 사용자 확인 필요: NAS 정확한 모델명(§8.1), Google Maps·Gemini API 키 전달 시점(P3/P4 착수 전).

---

## 15. 디자인 원칙 — Apple Human Interface Guidelines 차용

"디자인이 중요하다"는 요구에 따라, Apple HIG의 원칙과 iOS 네이티브 앱(건강, 피트니스)의 시각 언어를 웹에서 그대로 재현한다. 구체 규칙은 `docs/DESIGN.md`에 토큰 단위로 고정하고, 모든 컴포넌트는 그 토큰만 사용한다.

### 15.1 세 가지 원칙
| 원칙 | 의미 | 이 앱에서의 적용 |
|---|---|---|
| **Clarity(명료)** | 텍스트는 읽히고, 아이콘은 정확하고, 장식은 기능을 돕는다 | 숫자가 주인공. 큰 숫자 + 작은 단위 + 회색 보조 텍스트. 불필요한 테두리·그림자 제거 |
| **Deference(절제)** | UI는 콘텐츠를 돋보이게 하고 뒤로 물러난다 | 배경은 시스템 그룹 배경(밝은 회색), 카드는 흰색 둥근 사각형, 색은 데이터에만 사용 |
| **Depth(깊이)** | 계층과 전환으로 위치와 맥락을 알려준다 | 시트(bottom sheet)로 입력, 페이지 전환은 오른쪽에서 밀어 들어오는 push, 스크롤 시 큰 제목이 작은 제목으로 축소 |

### 15.2 시각 토큰 (iOS 17 기준)
- **타이포그래피**: `-apple-system, "SF Pro", "Pretendard", system-ui` 스택. iOS 텍스트 스타일 그대로: Large Title 34/700, Title1 28, Title2 22, Headline 17/600, Body 17, Callout 16, Subheadline 15, Footnote 13, Caption 12. 숫자는 `font-variant-numeric: tabular-nums`.
- **색상(시맨틱)**: `systemBlue #007AFF`, `systemGreen #34C759`, `systemOrange #FF9500`, `systemRed #FF3B30`, `systemPurple #AF52DE`, `systemTeal #30B0C7`. 라벨 `label / secondaryLabel(60%) / tertiaryLabel(30%)`. 배경 `systemGroupedBackground #F2F2F7`, 카드 `#FFFFFF`. 다크모드는 각 토큰의 iOS 다크 값(`#000000`, 카드 `#1C1C1E`)으로 자동 전환.
- **데이터 색상 규약**(건강앱 관례): 활동/걸음 = 오렌지, 운동 = 그린, 식사/영양 = 그린 계열이 아닌 **오렌지-레드**, 체중/신체 = 퍼플, 수분 = 틸/블루, 수면 = 인디고.
- **형태**: 카드 모서리 반경 12~16px(연속 곡률 느낌으로 큰 반경), 그룹 인셋 리스트(좌우 16px 여백, 행 높이 44px, 구분선은 왼쪽 인셋), 버튼은 filled(파랑 배경·흰 글씨, 50px 높이, 반경 12px) / tinted / plain 세 등급.
- **레이아웃**: 하단 탭바 5개(SF Symbols 스타일 아이콘 + 10px 라벨, 반투명 블러 배경), 상단 Large Title, 안전영역(`env(safe-area-inset-*)`) 존중, 터치 타겟 최소 44×44.
- **모션**: 200~300ms, `cubic-bezier(0.32, 0.72, 0, 1)`(iOS 스프링 근사). 시트는 아래에서 올라옴, 링은 채워지는 애니메이션. `prefers-reduced-motion` 존중.
- **시그니처 요소**: 홈의 **활동 링**(Apple Fitness 링 3개: 걸음·소모·섭취), 건강앱식 **요약 카드**(제목 + 큰 수치 + 미니 차트), 체중 차트는 건강앱과 같은 점+선+구간 강조.

### 15.3 구현 방식
- Tailwind 테마를 위 토큰으로 **완전히 덮어써서** 임의 색·크기 사용을 막는다(`tailwind.config`의 색상 팔레트를 iOS 시맨틱 컬러로 교체).
- 공통 컴포넌트 세트 먼저 제작: `LargeTitleHeader`, `InsetGroup/Row`, `Card`, `Sheet`, `SegmentedControl`, `ActivityRing`, `StatTile`, `TabBar`, `FilledButton`. 모든 화면은 이 세트로만 조립.
- 아이콘: SF Symbols는 라이선스상 웹에서 쓸 수 없으므로 시각적으로 가장 근접한 **Lucide** 아이콘을 1.5px 선 굵기로 사용.
- 폰트: iOS에서는 시스템 SF Pro가 자동 적용. Android/데스크톱은 SF와 메트릭이 비슷한 **Pretendard**(한글 포함, 무료)를 셀프 호스팅.
- 검수 기준: Playwright로 iPhone 15 뷰포트 스크린샷을 단계마다 남겨 iOS 건강앱과 나란히 비교.
