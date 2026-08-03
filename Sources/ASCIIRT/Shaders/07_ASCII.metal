//  07_ASCII.metal — etapa [7] + [8]
//
//  El nucleo: luma por tile -> indice en la rampa -> glifo del atlas.
//  Los glifos direccionales por borde (que ganan sobre la luminancia) llegan
//  en M4.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

// hash11 / hash21 viven en 000_Common.metal.

/// Intensidad de la lluvia en una celda, 0 fuera del rastro y 1 en la cabeza.
///
/// Cada columna tiene velocidad y fase propias derivadas de su indice: sin eso
/// todas caen sincronizadas y se ve como un barrido, no como lluvia. El ciclo
/// es filas+rastro para que la cola termine de salir por abajo antes de que la
/// cabeza reaparezca arriba.
///
/// El relieve desplaza el frente por celda segun la luminancia local: la gota
/// llega antes donde hay luz y despues donde hay sombra, asi que la linea de
/// avance deja de ser horizontal y calca el volumen de la escena.
///
/// Se desplaza el frente y no la velocidad: si cada celda integrara su propia
/// velocidad, dos celdas contiguas de una misma gota podrian dejar de ser
/// contiguas y la gota se partiria. Desplazando, mientras el gradiente de luma
/// sea menor a una celda por fila el rastro se curva pero no se rompe.
/// Intensidad de la gota y a que distancia de la cabeza esta la celda. La
/// distancia hace falta afuera para el tinte de punta, y recalcularla seria
/// repetir el fmod y los dos hashes.
struct RainSample {
    float intensity;
    float distance;
};

static inline RainSample matrixRain(uint2 tile, float relief01, float2 spawn,
                                    constant RenderParams &params) {
    const float rows = float(params.gridSize.y);
    const float trail = max(params.matrixTrail, 1.0);

    // Origen de la columna. El ciclo se acorta al tramo que queda por debajo,
    // asi la cadencia se mantiene en vez de que las columnas que nacen abajo
    // queden con pausas largas entre gota y gota.
    const float origin = mix(0.0, spawn.x, params.matrixSpawnBias);
    const float span = max(rows - origin, 1.0) + trail;

    // La cola se corta arriba del origen: sin esto el rastro asoma por encima
    // del punto de nacimiento y la gota parece venir de mas arriba en vez de
    // brotar del brillo.
    if (params.matrixSpawnBias > 0.0 && float(tile.y) < origin) {
        return RainSample{0.0, trail + 1.0};
    }

    // Centrado en 0.5 para que el gris medio no se desplace y el relieve se
    // reparta parejo entre lo que sobresale y lo que se hunde.
    const float relief = (relief01 - 0.5) * params.matrixRelief;
    // Un origen apagado emite una gota debil. En strength 0 todas iguales.
    const float emission = mix(1.0, saturate(spawn.y), params.matrixSpawnStrength);

    const uint drops = max(params.matrixDensity, 1u);
    RainSample best = RainSample{0.0, trail + 1.0};

    // Gana la gota mas fuerte, no la suma: dos rastros solapados sumados
    // saturarian a blanco y se perderia la cabeza de las dos.
    for (uint k = 0u; k < drops; ++k) {
        const float speed = params.matrixSpeed
            * (0.45 + 1.10 * hash11(tile.x * 7919u + k * 31u + 13u));
        const float phase = hash11(tile.x * 104729u + k * 6151u + 7u) * 997.0;

        const float head = origin + fmod(params.time * speed + phase, span);
        const float distance = head + relief - float(tile.y);
        if (distance < 0.0 || distance > trail) { continue; }

        const float intensity = (1.0 - distance / trail) * emission;
        if (intensity > best.intensity) {
            best = RainSample{intensity, distance};
        }
    }
    return best;
}

kernel void asciiKernel(texture2d<float, access::read>  grid   [[texture(ASCIIRTTextureIndexGrid)]],
                        texture2d<float, access::read>  atlas  [[texture(ASCIIRTTextureIndexAtlas)]],
                        texture2d<float, access::read>  edgeAtlas [[texture(ASCIIRTTextureIndexEdgeAtlas)]],
                        texture2d<uint,  access::read>  glyphs [[texture(ASCIIRTTextureIndexGlyphNext)]],
                        texture2d<float, access::read>  gridColor [[texture(ASCIIRTTextureIndexGridColor)]],
                        texture2d<float, access::read>  fullColor [[texture(ASCIIRTTextureIndexColor)]],
                        texture2d<float, access::read>  eyeMask [[texture(ASCIIRTTextureIndexEyeMask)]],
                        texture2d<float, access::read>  height [[texture(ASCIIRTTextureIndexHeight)]],
                        texture2d<float, access::read>  spawn  [[texture(ASCIIRTTextureIndexSpawn)]],
                        texture2d<float, access::write> output [[texture(ASCIIRTTextureIndexOutput)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const uint2 tile = gid / params.tileSize;

    // Sobra de division no entera (spec §3 avisa en la UI, pero igual hay que
    // pintar algo): fuera del grid va fondo.
    if (tile.x >= params.gridSize.x || tile.y >= params.gridSize.y) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    const float tileLuma = saturate(grid.read(tile).r);

    // La eleccion de glifo (borde vs rampa, mas histeresis) ya la resolvio
    // 06b_GlyphIndex a resolucion de grid. Aca solo se samplea.
    const uint2 decision = glyphs.read(tile).rg;
    uint index = decision.x;
    bool isEdge = decision.y != 0u;

    const float3 foreground = float3(params.foregroundR, params.foregroundG, params.foregroundB);
    const float3 background = float3(params.backgroundR, params.backgroundG, params.backgroundB);

    // Modos de color (spec §8). El modo 2 usa el promedio del tile, no el pixel:
    // pintar cada pixel del glifo con su color de origen convertiria el glifo en
    // una ventana a la imagen y se perderia la lectura tipografica.
    float3 tint = foreground;
    float3 backdrop = background;
    switch (params.colorMode) {
        case 0u: backdrop = float3(0.0); break;                       // mono
        case 1u: break;                                               // dos colores
        default: tint = gridColor.read(tile).rgb; break;              // original por tile
    }

    // `color` es el multiplicador de la tinta; lo pisa el modo Matrix, que trae
    // su propia paleta.
    float3 color = tint;
    bool matrixOverride = false;

    if (params.matrixEnabled != 0u) {
        matrixOverride = true;
        // El relieve sale del campo de altura (luma difuminada + matte), no de
        // la luma cruda: la luma lleva textura y meteria volumen falso donde
        // solo hay un estampado.
        const float2 origin = spawn.read(uint2(tile.x, 0)).rg;
        const RainSample drop = matrixRain(tile, saturate(height.read(tile).r), origin, params);
        const float rain = drop.intensity;

        // La imagen compuerta la lluvia en vez de taparla: donde el video es
        // oscuro la gota se apaga, y asi la figura sigue legible dentro del
        // efecto en lugar de quedar sepultada bajo ruido parejo.
        //
        // Con el peso en negativo se invierte y la lluvia se mete en las
        // sombras. En cero no compuerta nada y llueve parejo.
        const float gate = params.matrixImageMix >= 0.0
            ? mix(1.0, tileLuma, params.matrixImageMix)
            : mix(1.0, 1.0 - tileLuma, -params.matrixImageMix);
        const float intensity = rain * gate;

        if (intensity > 0.02) {
            // El glifo cambia por celda a `matrixChurn` cambios por segundo. El
            // hash de la celda desfasa el reloj de cada una: si todas mutaran en
            // el mismo frame se veria un parpadeo global.
            const float step = floor(params.time * params.matrixChurn + hash21(tile) * 13.0);
            const uint churn = uint(hash11(uint(step) * 2654435761u
                                           ^ (tile.x * 2246822519u + tile.y * 3266489917u))
                                    * float(params.rampLength));
            index = min(churn, params.rampLength - 1u);
            // La lluvia manda: un glifo direccional congelado en medio del
            // rastro cortaria la ilusion de que el caracter esta mutando.
            isEdge = false;

            // Blanco y negro: cabeza a blanco pleno, cola cayendo a gris. El
            // corte en 0.82 es angosto a proposito — la cabeza tiene que leerse
            // como un punto, no como un degrade largo.
            const float head = smoothstep(0.82, 1.0, rain);
            const float level = mix(intensity * 0.80, 1.0, head);

            if (params.matrixHeadTintEnabled != 0u) {
                // Rampa de una celda en el borde: `matrixHeadCells - distance`
                // vale 1 bien adentro del tramo y cae a 0 al salir, asi el
                // tinte se apaga en vez de cortarse.
                const float tint = saturate(params.matrixHeadCells - drop.distance);
                const float3 tintColor = float3(params.matrixHeadColorR,
                                                params.matrixHeadColorG,
                                                params.matrixHeadColorB);
                color = mix(float3(level), tintColor * level, tint);
            } else {
                color = float3(level);
            }
        } else {
            // Fuera del rastro queda el ASCII del video: la lluvia lo recorre,
            // no lo reemplaza. El nivel es del usuario porque es exactamente la
            // perilla de "cuanto se lee la imagen debajo del efecto".
            color = float3(params.matrixBaseLevel * tileLuma);
        }
    }

    // Posicion dentro del tile calculada desde gid y no desde
    // thread_position_in_threadgroup: con dispatchThreads no uniforme el ultimo
    // threadgroup de cada fila puede estar recortado, y ahi lid ya no coincide
    // con la posicion real dentro del tile.
    const uint2 local = gid % params.tileSize;

    // Flip vertical: el atlas se rasteriza con CoreGraphics, que tiene el origen
    // abajo a la izquierda; las texturas de Metal lo tienen arriba.
    const uint2 texel = uint2(index * params.tileSize.x + local.x,
                              params.tileSize.y - 1u - local.y);

    // Dos atlas y no uno: los cuatro glifos direccionales son fijos y no
    // dependen del charset del usuario, asi que meterlos en la rampa calibrada
    // los ordenaria por cobertura junto con el resto y perderian su indice.
    const float ink = isEdge ? edgeAtlas.read(texel).r : atlas.read(texel).r;

    // Invert cambia quien es tinta y quien es fondo, no el color: invertir el
    // color daria el negativo fotografico, que es otra cosa.
    float coverage = params.invert != 0u ? 1.0 - ink : ink;

    // Vaciar el interior: se quita la tinta del glifo, no el color. Asi el pleno
    // y el anillo siguen dibujandose y lo unico que desaparece adentro es el
    // codigo.
    //
    // Va ANTES de componer el color: la cobertura es lo que decide cuanto glifo
    // hay en el pixel, y si se modifica despues de haberla usado para mezclar,
    // el cambio solo llega al alpha y en pantalla no pasa nada.
    if (params.eyeHollow != 0u && params.generativeEnabled != 0u) {
        coverage *= 1.0 - eyeMask.read(gid).r;
    }

    // Matrix ya trae su composicion resuelta contra negro; los modos de color
    // solo aplican fuera de el.
    const float3 rgb = matrixOverride ? color * coverage : mix(backdrop, color, coverage);

    // Pleno del ojo por encima del ASCII. Se lee el color a resolucion completa,
    // no el promedio por tile: el disco tiene que tener borde limpio, y el grid
    // lo escalonaria a la celda.
    float3 finalRGB = rgb;
    float finalCoverage = coverage;

    if (params.eyeSolidAmount > 0.0) {
        const float4 source = fullColor.read(gid);
        // El borde: en 0 se respeta la caida del iris, en 1 se corta en disco.
        const float low = mix(0.0, 0.48, params.eyeSolidEdge);
        const float high = mix(1.0, 0.52, params.eyeSolidEdge);
        const float mask = smoothstep(low, high, source.a) * params.eyeSolidAmount;

        finalRGB = mix(finalRGB, source.rgb * params.eyeSolidGain, mask);
        // Con fondo transparente el pleno tiene que ser opaco: si heredara la
        // cobertura del glifo saldria calado por dentro.
        finalCoverage = max(finalCoverage, mask);
    }

    // Alpha premultiplicado: es lo que espera una pista ProRes 4444. Sin
    // premultiplicar, los bordes antialiaseados del glifo salen con halo.
    const float alpha = params.transparentBackground != 0u ? finalCoverage : 1.0;
    output.write(float4(params.transparentBackground != 0u ? finalRGB * alpha : finalRGB, alpha), gid);
}
