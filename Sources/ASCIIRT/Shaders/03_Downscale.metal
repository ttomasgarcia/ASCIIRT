//  03_Downscale.metal — etapa [3]
//
//  Luma full-res -> luma media por tile (R16F, cols x rows).
//
//  Un hilo por celda del grid, no por pixel: la reduccion es de 16 a 256
//  lecturas segun el tile, todas contiguas en la misma fila de cache, y evita
//  la sincronizacion de una reduccion en threadgroup para un tamano tan chico.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void downscaleKernel(texture2d<float, access::read>  luma [[texture(ASCIIRTTextureIndexLuma)]],
                            texture2d<float, access::write> grid [[texture(ASCIIRTTextureIndexGrid)]],
                            constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    const uint2 origin = gid * params.tileSize;
    const uint2 limit = params.outputSize;

    float sum = 0.0;
    uint counted = 0u;

    // El clamp contra outputSize importa solo cuando el ancho no es multiplo del
    // tile; en ese caso el ultimo tile es parcial y promediar los texels
    // inexistentes como 0 lo oscureceria artificialmente.
    for (uint y = 0u; y < params.tileSize.y; ++y) {
        for (uint x = 0u; x < params.tileSize.x; ++x) {
            const uint2 coord = origin + uint2(x, y);
            if (coord.x < limit.x && coord.y < limit.y) {
                sum += luma.read(coord).r;
                counted += 1u;
            }
        }
    }

    grid.write(float4(counted > 0u ? sum / float(counted) : 0.0), gid);
}
