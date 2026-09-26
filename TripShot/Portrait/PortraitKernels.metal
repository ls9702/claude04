// 인물 보정용 Core Image Metal 커널: 피부색 가능도, 주파수 분리 합성, 얼굴 윤곽·눈 워프.
// 빌드 설정 MTL_COMPILER_FLAGS=-fcikernel, MTLLINKER_FLAGS=-cikernel 필요(project.yml). 결과는 default.metallib.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// 보조 함수는 커널 네임스페이스 밖에 둔다(커널로 오인되지 않게).
// 선형 → sRGB 감마(채널별). 작업 색공간이 선형이므로 YCbCr 판정 전에 감마를 입힌다.
inline float toGamma(float c) {
    c = clamp(c, 0.0f, 1.0f);
    return c <= 0.0031308f ? c * 12.92f : 1.055f * pow(c, 1.0f / 2.4f) - 0.055f;
}

// lo~hi 범위 안이면 1, 경계 ±soft에서 부드럽게 0으로.
inline float softRange(float v, float lo, float hi, float soft) {
    return smoothstep(lo - soft, lo + soft, v) * (1.0f - smoothstep(hi - soft, hi + soft, v));
}

// 워프 가중치 w = (1 − (dist/r)²)², dist ≥ r이면 0. (Gustafsson 1993 국소 변형의 흔한 감쇠 곡선)
inline float warpFalloff(float2 v, float r) {
    float rr = max(r, 1e-4f);
    float t2 = dot(v, v) / (rr * rr);
    float u = 1.0f - t2;
    return t2 < 1.0f ? u * u : 0.0f;
}

// 원형 밀기의 역방향 변위 성분: push = (cx, cy, r, k), dir = 단위 방향. 반환값 d·k·w (입력 좌표 = p − 이 값).
inline float2 warpPush(float2 p, float4 push, float2 dir) {
    return dir * (push.w * warpFalloff(p - push.xy, push.z));
}

// 원형 확대의 역방향 변위 성분: eye = (cx, cy, r, s). 반환값 (p − c)·s·w (입력 좌표 = p − 이 값 → 중심부 확대).
inline float2 warpBulge(float2 p, float4 eye) {
    float2 v = p - eye.xy;
    return v * (eye.w * warpFalloff(v, eye.z));
}

extern "C" {
namespace coreimage {

// 피부색 가능도(0~1) 그레이 마스크. YCbCr(BT.601 풀레인지, 0~255) 표준 근사 범위 Cb 77~127, Cr 133~173, 경계 ±8.
// 작업 색공간은 선형 확장 Display P3지만 sRGB 곡선으로 근사한다(피부색 판정에는 충분).
// TODO(검증): 헬퍼 함수 호출이 -fcikernel 빌드에서 문제되면 본문에 인라인한다.
float4 skinLikelihood(sample_t s) {
    float a = s.a;
    float3 rgb = a > 0.0f ? s.rgb / a : float3(0.0f);
    float r = toGamma(rgb.r) * 255.0f;
    float g = toGamma(rgb.g) * 255.0f;
    float b = toGamma(rgb.b) * 255.0f;
    float cb = 128.0f - 0.168736f * r - 0.331264f * g + 0.5f * b;
    float cr = 128.0f + 0.5f * r - 0.418688f * g - 0.081312f * b;
    float m = softRange(cb, 77.0f, 127.0f, 8.0f) * softRange(cr, 133.0f, 173.0f, 8.0f);
    return float4(m, m, m, 1.0f);
}

// 주파수 분리 합성: 결과 = low + (input − mid).
// low = 큰 반경 블러(피부 톤·요철), mid = 작은 반경 블러. (input − mid)는 모공 같은 미세 질감(하이패스)이므로
// 두 반경 사이의 중간 주파수(잡티·얼룩)만 사라지고 질감은 남는다.
float4 frequencyCombine(sample_t input, sample_t low, sample_t mid) {
    float3 outRGB = low.rgb + (input.rgb - mid.rgb);
    return float4(outRGB, input.a);
}

// 얼굴 윤곽·눈 워프(역방향 변위). 출력 픽셀 p → 입력 좌표 p' = p − Σ d·k·w − Σ (p − c)·s·w.
// 얼굴 하나당 1회 적용한다. 쓰지 않는 밀기·확대는 k = 0 / s = 0으로 넘긴다(변위 0).
// TODO(검증): 헬퍼 함수 호출이 -fcikernel 빌드에서 문제되면 본문에 인라인한다(skinLikelihood와 같은 조건).
float2 faceWarp(float4 push0, float4 push1, float4 push2, float4 push3, float4 push4, float4 push5,
                float2 dir0, float2 dir1, float2 dir2, float2 dir3, float2 dir4, float2 dir5,
                float4 eyeL, float4 eyeR,
                destination dest) {
    float2 p = dest.coord();
    float2 shift = warpPush(p, push0, dir0) + warpPush(p, push1, dir1) + warpPush(p, push2, dir2)
                 + warpPush(p, push3, dir3) + warpPush(p, push4, dir4) + warpPush(p, push5, dir5);
    float2 bulge = warpBulge(p, eyeL) + warpBulge(p, eyeR);
    return p - shift - bulge;
}


// 전신 보정 워프(역방향): 출력 p → 입력 좌표. BodyWarpPlan.sourcePoint(for:)와 같은 식이다.
// slim = (cx, R, a, 0): 입력 x = x + a·w(y)·(x − cx)·(1 − |x − cx|/R)², |x − cx| ≥ R이면 그대로.
// slimY = (fullY, zeroY): 슬림 세로 가중치 w — 입력 y가 fullY 아래면 1, zeroY 위면 0, 사이는 smoothstep.
// legs = (baseY, rampStart, rampWidth, r): 바닥 기준 높이 h가 rampStart 아래면 h·r, 램프에서 r → 1 선형 변화의 적분, 위는 평행 이동.
float2 bodyReshape(float4 slim, float4 slimY, float4 legs, destination dest) {
    float2 p = dest.coord();
    float h = p.y - legs.x;
    float r = legs.w;
    float start = legs.y;
    float w = max(legs.z, 1e-4f);
    float sh;
    if (h <= start) {
        sh = h * r;
    } else if (h - start < w) {
        float t = h - start;
        sh = start * r + r * t + (1.0f - r) * t * t / (2.0f * w);
    } else {
        sh = start * r + (r + 1.0f) * w * 0.5f + (h - start - w);
    }
    float sy = legs.x + sh;

    float sx = p.x;
    float d = p.x - slim.x;
    float u = fabs(d) / max(slim.y, 1e-4f);
    if (slim.z > 0.0f && u < 1.0f) {
        float wy = 1.0f - smoothstep(slimY.x, max(slimY.y, slimY.x + 1e-4f), sy);
        sx = p.x + slim.z * wy * d * (1.0f - u) * (1.0f - u);
    }
    return float2(sx, sy);
}

}
}
