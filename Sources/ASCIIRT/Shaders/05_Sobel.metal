//  05_Sobel.metal — etapa [5]
//
//  Gradiente H+V sobre la DoG. RG16F: (gx, gy).
//
//  Sobre la DoG y no sobre la luminancia directa: la DoG ya elimino la baja
//  frecuencia, asi que el gradiente responde a contornos y no a rampas suaves
//  de iluminacion.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void sobelKernel(texture2d<float, access::read>  dog    [[texture(ASCIIRTTextureIndexDoG)]],
                        texture2d<float, access::write> output [[texture(ASCIIRTTextureIndexSobel)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const int2 limit = int2(params.outputSize) - 1;
    float samples[3][3];
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            const uint2 coord = uint2(clamp(int2(gid) + int2(x, y), int2(0), limit));
            samples[y + 1][x + 1] = dog.read(coord).r;
        }
    }

    const float gx = (samples[0][2] + 2.0 * samples[1][2] + samples[2][2])
                   - (samples[0][0] + 2.0 * samples[1][0] + samples[2][0]);
    const float gy = (samples[2][0] + 2.0 * samples[2][1] + samples[2][2])
                   - (samples[0][0] + 2.0 * samples[0][1] + samples[0][2]);

    output.write(float4(gx, gy, 0.0, 0.0), gid);
}
