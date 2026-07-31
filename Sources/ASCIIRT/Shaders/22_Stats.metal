//  22_Stats.metal — luminancia media del frame (spec §4b)
//
//  Fuera de la numeracion [0]..[9]: es telemetria del pipeline, no una etapa.
//
//  El resultado se queda en un buffer de GPU y lo consume la etapa [2] del frame
//  SIGUIENTE. Un frame de atraso es preferible a sincronizar con CPU para leer
//  un solo float, y la media movil lo suaviza igual.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

constant uint kStatsThreads = 256u;

kernel void lumaStatsKernel(texture2d<float, access::read> luma [[texture(ASCIIRTTextureIndexLumaRaw)]],
                            device float &average [[buffer(ASCIIRTBufferIndexLumaStats)]],
                            constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                            uint tid [[thread_position_in_threadgroup]]) {
    threadgroup float partial[kStatsThreads];

    // Muestreo estriado en x: para una media no hace falta cada pixel, y a 1/4
    // de las columnas el error es despreciable contra el costo.
    const uint stride = 4u;
    float sum = 0.0;
    uint counted = 0u;

    for (uint y = tid; y < params.outputSize.y; y += kStatsThreads) {
        for (uint x = 0u; x < params.outputSize.x; x += stride) {
            sum += luma.read(uint2(x, y)).r;
            counted += 1u;
        }
    }
    partial[tid] = counted > 0u ? sum / float(counted) : 0.0;

    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Reduccion en arbol. Todos los hilos llegan a la barrera: salir antes seria
    // comportamiento indefinido.
    for (uint offset = kStatsThreads / 2u; offset > 0u; offset >>= 1u) {
        if (tid < offset) { partial[tid] += partial[tid + offset]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0u) {
        const float frameAverage = partial[0] / float(kStatsThreads);
        // EMA: alpha chico = la correccion tarda en reaccionar pero no persigue
        // cada parpadeo del AGC, que es justo lo que se quiere evitar.
        average = mix(average, frameAverage, saturate(params.lumaSmoothAlpha));
    }
}
