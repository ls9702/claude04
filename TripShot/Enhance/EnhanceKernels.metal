// 보정 파이프라인용 Core Image Metal 커널: 5단계 저조도(Zero-DCE++ 곡선의 풀해상도 적용).
// PortraitKernels.metal과 같은 default.metallib로 빌드된다(project.yml의 -fcikernel 플래그). 함수 이름은 겹치지 않게 한다.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// 보조 함수는 커널 네임스페이스 밖에 둔다. 다른 .metal 파일의 헬퍼(toGamma)와 이름이 겹치지 않도록 접두어 dce를 붙이고
// static으로 파일 안에서만 보이게 한다.
// 선형 → sRGB 감마(채널별, 0~1 입력 가정).
static inline float dceToGamma(float c) {
    return c <= 0.0031308f ? c * 12.92f : 1.055f * pow(c, 1.0f / 2.4f) - 0.055f;
}

// sRGB 감마 → 선형(채널별, 0~1 입력 가정).
static inline float dceToLinear(float c) {
    return c <= 0.04045f ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
}

static inline float3 dceToGamma3(float3 c) { return float3(dceToGamma(c.r), dceToGamma(c.g), dceToGamma(c.b)); }
static inline float3 dceToLinear3(float3 c) { return float3(dceToLinear(c.r), dceToLinear(c.g), dceToLinear(c.b)); }

extern "C" {
namespace coreimage {

// Zero-DCE++ LE 곡선. x = 입력(작업 색공간: 선형 확장 Display P3, 프리멀티플라이드),
// a = 곡선 파라미터 맵(모델 출력 A를 (A+1)/2로 0~1에 담은 것, 색 관리 없음).
// 모델이 sRGB 감마 공간 이미지로 학습됐으므로 선형 → 감마로 바꿔 곡선을 적용하고 다시 선형으로 되돌린다.
// 곡선(원본 코드와 동일, 채널별): x = x + A·(x² − x) 를 iterations회 반복. A < 0이면 밝아지고 A > 0이면 어두워진다.
// 0~1 밖 값(확장 색역·HDR 하이라이트)은 곡선을 0~1에만 적용하고 벗어난 만큼을 다시 더해 보존한다.
// 결과는 strength(0~1)로 원본과 섞는다.
// TODO(검증): 헬퍼 호출·동적 반복문이 -fcikernel 빌드에서 문제되면 본문에 인라인하고 8회로 고정한다.
float4 zeroDCECurve(sample_t x, sample_t a, float iterations, float strength) {
    float alpha = x.a;
    float3 rgb = alpha > 0.0f ? x.rgb / alpha : float3(0.0f);
    float3 inRange = clamp(rgb, 0.0f, 1.0f);
    float3 residual = rgb - inRange;

    float3 A = a.rgb * 2.0f - 1.0f;
    float3 g = dceToGamma3(inRange);
    int n = int(iterations);
    for (int i = 0; i < n; i++) {
        g = clamp(g + A * (g * g - g), 0.0f, 1.0f);
    }
    float3 enhanced = dceToLinear3(g) + residual;
    float3 outRGB = mix(rgb, enhanced, clamp(strength, 0.0f, 1.0f));
    return float4(outRGB * alpha, alpha);
}

}
}
