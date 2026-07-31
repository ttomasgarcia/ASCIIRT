//  02_Normalize.metal — etapa [2]
//
//  Corrige la exposicion antes de que la luminancia llegue al grid.
//
//  El problema (spec §4): el AGC/AE de la webcam mueve la luminancia media
//  constantemente y la rampa "hierve" aunque la escena este quieta. Aca se
//  remapea para que la media movil caiga en un punto medio configurable.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void normalizeKernel(texture2d<float, access::read>  rawLuma [[texture(ASCIIRTTextureIndexLumaRaw)]],
                            texture2d<float, access::write> output  [[texture(ASCIIRTTextureIndexLuma)]],
                            constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                            constant float &lumaAvg [[buffer(ASCIIRTBufferIndexLumaStats)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const float raw = rawLuma.read(gid).r;

    // El piso evita que un frame negro genere una ganancia infinita en el
    // primer cuadro tras tapar la lente.
    const float average = max(lumaAvg, 0.02);
    const float gain = params.lumaTarget / average;

    // Ganancia lineal y no una curva: mover el punto medio con gamma comprime
    // las altas luces, y la rampa ASCII necesita los extremos separados para
    // que el glifo mas denso siga apareciendo.
    const float normalized = saturate(raw * gain);

    output.write(float4(mix(raw, normalized, params.autoLevelStrength)), gid);
}
