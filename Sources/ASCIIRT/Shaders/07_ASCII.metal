//  07_ASCII.metal — etapa [7] + [8]
//
//  El nucleo: luma por tile -> indice en la rampa -> glifo del atlas.
//  Los glifos direccionales por borde (que ganan sobre la luminancia) llegan
//  en M4.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

/// Hash entero barato. No hace falta calidad estadistica: alcanza con que dos
/// columnas vecinas no caigan en fase, que es lo unico que se nota a simple vista.
static inline float hash11(uint n) {
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7fffffffu) / float(0x7fffffff);
}

static inline float hash21(uint2 p) {
    return hash11(p.x * 73856093u ^ p.y * 19349663u);
}

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

    // Cuantizacion a indice de rampa. El clamp a rampLength-1 es necesario
    // porque luma == 1.0 daria exactamente rampLength.
    const uint lumaIndex = min(uint(tileLuma * float(params.rampLength)),
                               params.rampLength - 1u);

    uint index = lumaIndex;
    float3 color = float3(1.0);

    if (params.matrixEnabled != 0u) {
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

    const float ink = atlas.read(texel).r;

    output.write(float4(color * ink, 1.0), gid);
}
