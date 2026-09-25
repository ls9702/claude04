// 인물 보정용 Core Image Metal 커널: 피부색 가능도, 주파수 분리 합성.
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

}
}
