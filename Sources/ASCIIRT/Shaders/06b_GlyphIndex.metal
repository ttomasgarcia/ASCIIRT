//  06b_GlyphIndex.metal — decision de glifo por tile
//
//  Une la etapa [7] pasos 3-5 de la spec: los bordes ganan sobre la luminancia,
//  y encima va la histeresis temporal.
//
//  Vive en su propio kernel, a resolucion de grid, y no dentro del kernel ASCII
//  porque la histeresis escribe estado por celda: hacerlo desde un kernel que
//  corre por pixel significaria decenas de hilos escribiendo la misma celda.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void glyphIndexKernel(texture2d<float, access::read> grid [[texture(ASCIIRTTextureIndexGrid)]],
                             texture2d<float, access::read> edge [[texture(ASCIIRTTextureIndexEdge)]],
                             texture2d<uint,  access::read> previous [[texture(ASCIIRTTextureIndexGlyphPrev)]],
                             texture2d<uint,  access::write> next [[texture(ASCIIRTTextureIndexGlyphNext)]],
                             constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    const float tileLuma = saturate(grid.read(gid).r);

    // 3) Los bordes ganan sobre la luminancia. Ese orden es lo que separa esto
    //    de un filtro de brillo, asi que va primero y no se negocia.
    if (params.edgesEnabled != 0u) {
        const float2 e = edge.read(gid).rg;
        if (e.y > params.edgeThreshold) {
            next.write(uint4(uint(e.x), 1u, 0u, 0u), gid);
            return;
        }
    }

    // 4) Indice en la rampa de luminancia.
    const uint fresh = min(uint(tileLuma * float(params.rampLength)), params.rampLength - 1u);

    // 5) Histeresis temporal (spec §5). Sin esto la salida parpadea frame a
    //    frame: la luma de un tile quieto oscila unas milesimas y cruza el
    //    limite entre dos glifos vecinos todo el tiempo.
    //
    //    Dos desvios de la formula literal de la spec, los dos por el mismo
    //    defecto: comparar contra el CENTRO del escalon anterior con un umbral
    //    en unidades absolutas de luminancia deja tiles congelados para siempre.
    //    Con 69 glifos cada escalon vale 0.0145, asi que un umbral de 0.08 es una
    //    zona muerta de +-5.5 escalones: un tile que se apaga del todo queda a
    //    0.07 de su glifo viejo, nunca supera el umbral, y se queda prendido.
    //    Se veia como una estela que el ojo dejaba encendida a su paso.
    //
    //    a) El umbral se mide en ESCALONES de rampa, no en luminancia absoluta.
    //       Asi el control significa lo mismo con 10 glifos que con 69.
    //    b) Se compara contra el BORDE entre el glifo viejo y el nuevo, no
    //       contra el centro del viejo — un disparador de Schmitt. Eso lo hace
    //       imposible de trabar: cuanto mas lejos se va la luma, mas lejos queda
    //       del borde, y en algun momento cambia si o si.
    if (params.hysteresisThreshold > 0.0) {
        const uint2 prev = previous.read(gid).rg;
        // Solo se conserva si el frame anterior tambien resolvio por rampa: un
        // indice heredado de un glifo direccional no significa lo mismo.
        // Apagarse siempre se permite. Un caracter que deberia estar apagado y
        // sigue encendido se nota muchisimo mas que uno que quedo un escalon
        // corrido, y es lo que dejaba residuos de la estela colgados en pantalla.
        if (prev.y == 0u && prev.x < params.rampLength && fresh != prev.x && fresh != 0u) {
            const float step = 1.0 / float(params.rampLength);
            const float boundary = float(fresh > prev.x ? prev.x + 1u : prev.x) * step;
            if (abs(tileLuma - boundary) <= params.hysteresisThreshold * step) {
                next.write(uint4(prev.x, 0u, 0u, 0u), gid);
                return;
            }
        }
    }

    next.write(uint4(fresh, 0u, 0u, 0u), gid);
}
