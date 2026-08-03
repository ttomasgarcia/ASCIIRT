//  23_Trail.metal — arrastre temporal del campo
//
//  Fuera de la numeracion [0]..[9]: es un efecto sobre el grid, no una etapa.
//
//  Realimentacion simple: el campo de este frame compite contra el del anterior
//  atenuado. Donde la imagen se apago, el valor viejo sigue ahi un rato y se va
//  desvaneciendo; donde hay senal nueva, gana la nueva.
//
//  Se toma el MAXIMO y no una mezcla: mezclando, un tile encendido tarda en
//  llegar a su valor real y el frente del movimiento sale lavado. Con maximo el
//  frente entra a pleno de una y solo la cola se arrastra, que es lo que hace
//  un fosforo — y lo que uno espera de una estela.
//
//  Corre a resolucion de grid: la estela se percibe celda a celda igual, y a
//  resolucion completa costaria 120 veces mas para el mismo resultado.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void trailKernel(texture2d<float, access::read>  grid     [[texture(ASCIIRTTextureIndexGrid)]],
                        texture2d<float, access::read>  previous [[texture(ASCIIRTTextureIndexTrailPrev)]],
                        texture2d<float, access::write> next     [[texture(ASCIIRTTextureIndexTrailNext)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    const float current = grid.read(gid).r;
    const float faded = previous.read(gid).r * params.trailDecay;

    // Piso: por debajo del primer escalon de la rampa el glifo ya es un espacio,
    // asi que seguir arrastrando decimales invisibles solo alarga el calculo.
    const float value = max(current, faded);
    next.write(float4(value > 1.0 / 512.0 ? value : 0.0), gid);
}
