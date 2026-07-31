//  20_Relief.metal — campo de altura para el desplazamiento de la lluvia
//
//  Fuera de la numeracion [0]..[9] de la spec a proposito: no es una etapa del
//  pipeline ASCII, es una entrada del modo Matrix.
//
//  El problema que resuelve: la luminancia cruda lleva textura, no forma. Una
//  remera estampada mete relieve donde no hay volumen. Pasando la luma por un
//  blur fuerte queda solo la baja frecuencia — la forma — y el detalle se cae.
//
//  El blur corre sobre el grid (cols x rows), no sobre la imagen full-res: el
//  relieve se aplica por celda, asi que a 240x72 son ~17k texels por pasada.
//  Hacerlo a 1920x1080 seria 120x mas trabajo para el mismo resultado.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

/// Gaussiana normalizada en una pasada 1D.
///
/// Separable: dos pasadas de 2r+1 taps en vez de una de (2r+1)^2. Con r=8 son
/// 34 lecturas por celda contra 289.
static inline float blur1D(texture2d<float, access::read> source,
                           uint2 coord, uint2 limit, int2 axis, int radius) {
    if (radius <= 0) { return source.read(coord).r; }

    const float sigma = max(float(radius) * 0.5, 0.5);
    const float denom = -0.5 / (sigma * sigma);

    float sum = 0.0;
    float weightSum = 0.0;

    for (int i = -radius; i <= radius; ++i) {
        const int2 offset = axis * i;
        const int2 target = int2(coord) + offset;
        // clamp en vez de descartar: descartar los bordes hunde el relieve en
        // los margenes y la lluvia se dobla contra el marco.
        const uint2 clamped = uint2(clamp(target, int2(0), int2(limit) - 1));
        const float weight = exp(float(i * i) * denom);
        sum += source.read(clamped).r * weight;
        weightSum += weight;
    }
    return sum / weightSum;
}

/// Pasada horizontal: grid -> temporal.
kernel void reliefBlurH(texture2d<float, access::read>  source [[texture(ASCIIRTTextureIndexGrid)]],
                        texture2d<float, access::write> output [[texture(ASCIIRTTextureIndexHeightTemp)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }
    output.write(float4(blur1D(source, gid, params.gridSize, int2(1, 0), int(params.reliefRadius))), gid);
}

/// Pasada vertical + mezcla con el matte del sujeto -> campo de altura final.
///
/// El matte se samplea en espacio de la fuente, no del grid: viene de Vision
/// sobre el frame original, asi que hay que pasar por el mismo mapeo "fit" que
/// usa la etapa [1]. Sin eso el sujeto queda corrido cuando la resolucion de
/// salida no comparte aspecto con la de captura.
kernel void reliefBlurV(texture2d<float, access::read>   source [[texture(ASCIIRTTextureIndexHeightTemp)]],
                        texture2d<float, access::sample> matte  [[texture(ASCIIRTTextureIndexMatte)]],
                        texture2d<float, access::write>  output [[texture(ASCIIRTTextureIndexHeight)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    float height = blur1D(source, gid, params.gridSize, int2(0, 1), int(params.reliefRadius));

    if (params.matteAvailable != 0u && params.matteWeight > 0.0) {
        constexpr sampler bilinear(filter::linear, mip_filter::none, address::clamp_to_edge);
        const float2 uvOut = (float2(gid) + 0.5) / float2(params.gridSize);
        const float2 uvSrc = uvOut * params.sourceScale + params.sourceOffset;

        // Afuera del encuadre el sujeto no existe: 0, no borde estirado.
        const float subject = (any(uvSrc < 0.0) || any(uvSrc > 1.0))
            ? 0.0
            : matte.sample(bilinear, uvSrc).r;

        // El matte separa figura de fondo, que es la informacion que la luma no
        // tiene; la luma difuminada aporta el modelado dentro de la figura. Por
        // eso se mezclan en vez de elegir uno.
        height = mix(height, subject, params.matteWeight);
    }

    output.write(float4(height), gid);
}
