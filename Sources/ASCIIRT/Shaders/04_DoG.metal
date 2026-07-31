//  04_DoG.metal — etapa [4]
//
//  Diferencia de gaussianas sobre la luminancia normalizada, a resolucion plena.
//
//  Las dos gaussianas se calculan en la MISMA pasada, una en el canal R y otra
//  en el G, con el radio de la mas ancha. Separable seria naturalmente cuatro
//  dispatches (h y v por cada sigma); asi son dos, y las lecturas de textura —
//  que es lo que cuesta — se comparten entre ambas.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

/// 3 sigmas cubre el 99.7% de la campana; mas taps no cambian nada visible.
static inline int dogRadius(constant RenderParams &params) {
    return clamp(int(ceil(max(params.dogSigma1, params.dogSigma2) * 3.0)), 1, 24);
}

kernel void dogBlurH(texture2d<float, access::read>  luma [[texture(ASCIIRTTextureIndexLuma)]],
                     texture2d<float, access::write> temp [[texture(ASCIIRTTextureIndexDoGTemp)]],
                     constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const int radius = dogRadius(params);
    const float d1 = -0.5 / max(params.dogSigma1 * params.dogSigma1, 1e-4);
    const float d2 = -0.5 / max(params.dogSigma2 * params.dogSigma2, 1e-4);

    float2 sum = 0.0;
    float2 weightSum = 0.0;

    for (int i = -radius; i <= radius; ++i) {
        const uint2 coord = uint2(clamp(int(gid.x) + i, 0, int(params.outputSize.x) - 1), gid.y);
        const float value = luma.read(coord).r;
        const float2 weight = float2(exp(float(i * i) * d1), exp(float(i * i) * d2));
        sum += value * weight;
        weightSum += weight;
    }
    temp.write(float4(sum / weightSum, 0.0, 0.0), gid);
}

kernel void dogBlurV(texture2d<float, access::read>  temp   [[texture(ASCIIRTTextureIndexDoGTemp)]],
                     texture2d<float, access::write> output [[texture(ASCIIRTTextureIndexDoG)]],
                     constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const int radius = dogRadius(params);
    const float d1 = -0.5 / max(params.dogSigma1 * params.dogSigma1, 1e-4);
    const float d2 = -0.5 / max(params.dogSigma2 * params.dogSigma2, 1e-4);

    float2 sum = 0.0;
    float2 weightSum = 0.0;

    for (int i = -radius; i <= radius; ++i) {
        const uint2 coord = uint2(gid.x, clamp(int(gid.y) + i, 0, int(params.outputSize.y) - 1));
        const float2 value = temp.read(coord).rg;
        const float2 weight = float2(exp(float(i * i) * d1), exp(float(i * i) * d2));
        sum += value * weight;
        weightSum += weight;
    }

    const float2 blurred = sum / weightSum;
    // tau cerca de 1 deja casi solo el borde; por debajo sobrevive algo de la
    // imagen y el contorno sale mas blando.
    output.write(float4(blurred.x - params.dogTau * blurred.y), gid);
}
