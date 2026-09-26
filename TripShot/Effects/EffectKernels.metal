// 효과(R2) 렌즈용 Core Image 워프 커널: 물결·일렁임·수정구슬·원통. 모두 역방향(출력 좌표 → 입력 좌표).
// 빌드 설정은 PortraitKernels.metal과 같다(-fcikernel, default.metallib).
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

// 동심원 물결: c = (cx, cy), w = (진폭 px, 파장 px, 위상, 감쇠 거리 px).
float2 effectRipple(float2 c, float4 w, destination dest) {
    float2 p = dest.coord();
    float2 d = p - c;
    float r = length(d);
    if (r < 1e-3f) { return p; }
    float falloff = exp(-r / max(w.w, 1.0f));
    float offset = w.x * sin(r / max(w.y, 1.0f) * 6.2831853f - w.z) * falloff;
    return p + d / r * offset;
}

// 가로 일렁임: w = (진폭 px, 파장 px, 위상, 0). 세로 위치에 따라 좌우로 흔들린다.
float2 effectWave(float4 w, destination dest) {
    float2 p = dest.coord();
    return float2(p.x + w.x * sin(p.y / max(w.y, 1.0f) * 6.2831853f + w.z), p.y);
}

// 수정구슬: c = (cx, cy), r = (반지름, 0). 원 안은 뒤집히고 가장자리로 갈수록 압축된 상(구슬 굴절), 밖은 그대로.
float2 effectCrystalBall(float2 c, float2 r, destination dest) {
    float2 p = dest.coord();
    float2 d = p - c;
    float R = max(r.x, 1.0f);
    float q = length(d) / R;
    if (q >= 1.0f) { return p; }
    float z = sqrt(1.0f - q * q);
    return c - d * (0.45f + 0.9f * (1.0f - z));
}

// 원통: c = (중심 x, 반폭 px). 가운데는 확대, 가장자리는 압축(원통에 감긴 모습).
float2 effectCylinder(float2 c, destination dest) {
    float2 p = dest.coord();
    float half_w = max(c.y, 1.0f);
    float u = clamp((p.x - c.x) / half_w, -1.0f, 1.0f);
    float src = asin(u) / 1.5707963f;
    return float2(c.x + src * half_w, p.y);
}

}
}
