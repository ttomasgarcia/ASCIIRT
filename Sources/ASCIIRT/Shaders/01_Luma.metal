//  01_Luma.metal — etapa [1]
//
//  BGRA de la fuente -> luminancia R16F a resolucion de salida.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void lumaKernel(texture2d<float, access::sample> source [[texture(ASCIIRTTextureIndexSource)]],
                       texture2d<float, access::write>  luma   [[texture(ASCIIRTTextureIndexLumaRaw)]],
                       texture2d<float, access::write>  color  [[texture(ASCIIRTTextureIndexColor)]],
                       constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    // +0.5 para caer en el centro del texel: sin eso el remuestreo se corre medio
    // pixel y en tiles de 4 px eso es un octavo de tile.
    const float2 uvOut = (float2(gid) + 0.5) / float2(params.outputSize);
    const float2 uvSrc = uvOut * params.sourceScale + params.sourceOffset;

    // Encuadre "fit": lo que cae afuera de la fuente es negro, no borde estirado.
    if (any(uvSrc < 0.0) || any(uvSrc > 1.0)) {
        luma.write(float4(0.0), gid);
        color.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    constexpr sampler bilinear(filter::linear, mip_filter::none, address::clamp_to_edge);
    const float3 rgb = source.sample(bilinear, uvSrc).rgb;

    // Rec.709 sobre la senal tal como viene (no linealizada). Es deliberado: la
    // rampa ASCII se calibra contra percepcion, y la curva de transferencia de
    // la camara ya esta aproximadamente en dominio perceptual. Linealizar aca
    // aplastaria las sombras justo donde viven los glifos ralos.
    luma.write(float4(dot(rgb, float3(0.2126, 0.7152, 0.0722))), gid);

    // El color se guarda aparte de la luma porque el modo "color original por
    // tile" (spec §8) lo necesita despues de promediar, y reconstruirlo desde la
    // luma seria imposible.
    color.write(float4(rgb, 1.0), gid);
}
