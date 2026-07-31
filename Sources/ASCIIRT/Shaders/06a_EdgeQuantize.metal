//  06a_EdgeQuantize.metal — etapa [6]
//
//  Angulo dominante del tile -> bin direccional. RG16F: (bin, magnitud).
//
//  Se usa el tensor de estructura y no la suma de gradientes. La razon: los dos
//  lados de un trazo tienen gradientes opuestos, y sumandolos se cancelan — un
//  trazo bien marcado daria magnitud cero. El tensor suma productos (gx^2,
//  gy^2, gx*gy), que son invariantes al signo, asi que los dos lados se refuerzan.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void edgeQuantizeKernel(texture2d<float, access::read>  sobel  [[texture(ASCIIRTTextureIndexSobel)]],
                               texture2d<float, access::write> output [[texture(ASCIIRTTextureIndexEdge)]],
                               constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    const uint2 origin = gid * params.tileSize;
    const uint2 limit = params.outputSize;

    float jxx = 0.0, jyy = 0.0, jxy = 0.0;
    uint counted = 0u;

    for (uint y = 0u; y < params.tileSize.y; ++y) {
        for (uint x = 0u; x < params.tileSize.x; ++x) {
            const uint2 coord = origin + uint2(x, y);
            if (coord.x >= limit.x || coord.y >= limit.y) { continue; }
            const float2 g = sobel.read(coord).rg;
            jxx += g.x * g.x;
            jyy += g.y * g.y;
            jxy += g.x * g.y;
            counted += 1u;
        }
    }
    if (counted == 0u) { output.write(float4(0.0), gid); return; }

    const float trace = (jxx + jyy) / float(counted);

    // Coherencia: 1 cuando todos los gradientes del tile apuntan al mismo eje,
    // 0 cuando estan repartidos. Multiplicarla contra la magnitud evita poner un
    // glifo direccional sobre ruido, que es lo que hace que los bordes se lean
    // como bordes y no como confeti.
    const float delta = sqrt((jxx - jyy) * (jxx - jyy) + 4.0 * jxy * jxy);
    const float coherence = (jxx + jyy) > 1e-6 ? delta / (jxx + jyy) : 0.0;

    const float magnitude = sqrt(max(trace, 0.0)) * coherence;

    // Direccion dominante del gradiente. El borde corre perpendicular, por eso
    // el +90: el glifo tiene que seguir el trazo, no la direccion en la que la
    // imagen cambia.
    const float gradientAngle = 0.5 * atan2(2.0 * jxy, jxx - jyy);
    float edgeAngle = gradientAngle + M_PI_2_F;

    // A [0, pi): un borde y su opuesto son el mismo trazo.
    edgeAngle = edgeAngle - M_PI_F * floor(edgeAngle / M_PI_F);

    // Cuatro bins de 45 grados, centrados en 0/45/90/135. El +0.5 antes de
    // floor hace que cada bin quede centrado en su angulo en vez de empezar ahi.
    const uint bin = uint(floor(edgeAngle / (M_PI_F / 4.0) + 0.5)) & 3u;

    output.write(float4(float(bin), magnitude, 0.0, 0.0), gid);
}
