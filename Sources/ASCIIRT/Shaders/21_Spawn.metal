//  21_Spawn.metal — punto de nacimiento de la gota por columna
//
//  Fuera de la numeracion [0]..[9] de la spec: es una entrada del modo Matrix,
//  no una etapa del pipeline ASCII.
//
//  Un hilo por columna, no por celda: la reduccion es sobre las filas de esa
//  columna y son decenas, no miles. A 240 columnas x 72 filas son 17k lecturas
//  para todo el frame.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

/// Busca, por columna, la fila de mayor altura y la escribe junto con su valor.
///
/// Se corre sobre el campo de altura y no sobre la luma cruda a proposito: la
/// luma cruda hace que la gota nazca del specular mas chico que haya en la
/// columna — un brillo en un ojo, un reflejo en un vidrio — y salta de fila
/// entre frames. Sobre el campo difuminado el origen se queda quieto, y si el
/// peso de sujeto esta arriba la gota nace de la figura en vez de nacer del
/// punto mas brillante del fondo.
kernel void spawnKernel(texture2d<float, access::read>  height [[texture(ASCIIRTTextureIndexHeight)]],
                        texture2d<float, access::write> spawn  [[texture(ASCIIRTTextureIndexSpawn)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid >= params.gridSize.x) { return; }

    float best = -1.0;
    uint bestRow = 0u;

    for (uint y = 0u; y < params.gridSize.y; ++y) {
        const float value = height.read(uint2(gid, y)).r;
        if (value > best) {
            best = value;
            bestRow = y;
        }
    }

    // .x = fila de origen, .y = que tan brillante es. La intensidad viaja junto
    // con la fila porque el kernel ASCII la usa para que un origen apagado no
    // emita una gota igual de fuerte que uno encendido.
    spawn.write(float4(float(bestRow), max(best, 0.0), 0.0, 0.0), uint2(gid, 0));
}
