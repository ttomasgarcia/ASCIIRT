//  32_Audio.metal — fuente generativa: la onda de audio
//
//  Igual que el ojo y el campo de codigo: no es una etapa del pipeline sino una
//  FUENTE. Escribe en lumaRaw y color donde escribiria la camara, asi que el
//  glitch, la lluvia de Matrix, los glifos de borde, la estela, los modos de
//  color y el export la afectan sin que haya que tocar ninguno.
//
//  Lo que se dibuja aca es una imagen en escala de grises, no glifos: la rampa
//  decide despues que caracter le toca a cada celda segun cuanta tinta hay. Por
//  eso el trazo lleva halo —una linea de un pixel cae entera adentro de una
//  celda y sale como puntos sueltos en vez de como una onda.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

/// Lectura interpolada del arreglo de audio. `component` 0 es la onda, 1 el
/// espectro. Sin interpolar, al estirar 512 muestras sobre el ancho de la
/// pantalla la onda sale escalonada en bloques.
static inline float audioSample(texture2d<float, access::read> audio,
                                float position, uint component) {
    const uint count = audio.get_width();
    if (count == 0u) { return 0.0; }
    const float x = clamp(position, 0.0, 1.0) * float(count - 1u);
    const uint i0 = uint(floor(x));
    const uint i1 = min(i0 + 1u, count - 1u);
    const float2 a = audio.read(uint2(i0, 0u)).rg;
    const float2 b = audio.read(uint2(i1, 0u)).rg;
    const float t = x - float(i0);
    const float2 v = mix(a, b, t);
    return component == 0u ? v.x : v.y;
}

kernel void audioKernel(texture2d<float, access::write> luma  [[texture(ASCIIRTTextureIndexLumaRaw)]],
                        texture2d<float, access::write> color [[texture(ASCIIRTTextureIndexColor)]],
                        texture2d<float, access::write> mask  [[texture(ASCIIRTTextureIndexEyeMask)]],
                        texture2d<float, access::read>  audio [[texture(ASCIIRTTextureIndexAudio)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const float2 size = float2(params.outputSize);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float aspect = size.x / size.y;

    // El volumen agranda la onda ademas de moverla. Con react en 0 el tamano no
    // depende del nivel y solo cambia la forma, que es lo que hace falta cuando
    // la onda tiene que quedar estable en cuadro.
    const float react = mix(1.0, 0.35 + params.audioLevel * 1.30, saturate(params.audioReact));
    const float amplitude = max(params.audioAmplitude, 0.0) * react;
    const float thickness = max(params.audioThickness, 0.002);
    const float glow = max(params.audioGlow, 0.0);
    const float centerY = params.audioCenterY;

    float ink = 0.0;

    if (params.audioStyle == 2u) {
        // Anillo: la onda montada sobre una circunferencia. El eje x se corrige
        // por aspecto para que sea un circulo y no una elipse.
        const float2 p = (uv - float2(0.5, centerY)) * float2(aspect, 1.0);
        const float r = length(p);
        const float angle = atan2(p.y, p.x) / kTau + 0.5;   // 0..1

        const float wave = audioSample(audio, angle, 0u);
        const float radius = max(params.audioRadius, 0.01) * 0.5 + wave * amplitude * 0.5;
        const float d = abs(r - radius);

        ink = saturate(1.0 - d / thickness);
        if (glow > 0.0) { ink = max(ink, saturate(1.0 - d / (thickness + glow)) * 0.55); }
        if (params.audioFill > 0.0 && r < radius) {
            ink = max(ink, params.audioFill * saturate(r / max(radius, 1e-3)));
        }

    } else {
        // El tramo util esta centrado: con span 0.5 la onda ocupa la mitad del
        // ancho y queda aire a los dos lados, en vez de arrancar pegada al borde.
        const float span = clamp(params.audioSpan, 0.05, 1.0);
        const float x = (uv.x - (0.5 - span * 0.5)) / span;
        if (x < 0.0 || x > 1.0) {
            luma.write(float4(0.0), gid);
            color.write(float4(0.0), gid);
            mask.write(float4(0.0), gid);
            return;
        }

        const float dy = uv.y - centerY;

        if (params.audioStyle == 1u) {
            // Barras de espectro. La ranura entre barras es del 20%: sin ella
            // las barras se tocan y el conjunto se lee como una sola mancha.
            const float bars = max(params.audioBars, 1.0);
            const float slot = floor(x * bars);
            const float inside = fract(x * bars);
            if (inside > 0.80) {
                luma.write(float4(0.0), gid);
                color.write(float4(0.0), gid);
                mask.write(float4(0.0), gid);
                return;
            }
            const float value = audioSample(audio, (slot + 0.5) / bars, 1u);
            const float height = value * amplitude * 0.5;

            // Sin espejo la barra crece hacia arriba desde el eje; con espejo,
            // hacia los dos lados.
            const float low  = params.audioMirror != 0u ? -height : -height;
            const float high = params.audioMirror != 0u ?  height : 0.0;
            const float d = dy < low ? low - dy : (dy > high ? dy - high : 0.0);

            ink = saturate(1.0 - d / thickness);
            if (glow > 0.0) { ink = max(ink, saturate(1.0 - d / (thickness + glow)) * 0.55); }
            if (d == 0.0) { ink = max(ink, 1.0); }

        } else {
            // Onda en el tiempo.
            const float wave = audioSample(audio, x, 0u);
            const float w = wave * amplitude * 0.5;

            float d = abs(dy - w);
            if (params.audioMirror != 0u) { d = min(d, abs(dy + w)); }

            ink = saturate(1.0 - d / thickness);
            if (glow > 0.0) { ink = max(ink, saturate(1.0 - d / (thickness + glow)) * 0.55); }

            // Relleno entre el trazo y el eje, para que la onda tenga cuerpo.
            if (params.audioFill > 0.0) {
                const bool between = (dy >= min(0.0, w) && dy <= max(0.0, w))
                    || (params.audioMirror != 0u && dy >= min(0.0, -w) && dy <= max(0.0, -w));
                if (between) { ink = max(ink, params.audioFill); }
            }
        }
    }

    ink = saturate(ink);
    luma.write(float4(ink), gid);
    // Alfa en 0: el alfa del color es la mascara de cuerpo del pleno del ojo, y
    // esta fuente no tiene cuerpo.
    color.write(float4(float3(ink), 0.0), gid);
    mask.write(float4(0.0), gid);
}
