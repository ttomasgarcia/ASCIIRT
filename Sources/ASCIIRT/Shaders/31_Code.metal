//  31_Code.metal — fuente generativa: campo de codigo
//
//  Igual que el ojo: no es una etapa del pipeline sino una FUENTE. Escribe en
//  lumaRaw y color donde escribiria la camara, y de ahi para abajo nadie se
//  entera de que la imagen no vino de ningun lado. Por eso hereda gratis los
//  modos de color, el glitch, la lluvia de Matrix, la estela y el export.
//
//  Lo unico que NO puede resolver aca es que letra va en cada celda: eso lo
//  decide la rampa por densidad, y la densidad de un renglon de codigo es
//  pareja. La eleccion del glifo la pisa el pase ASCII leyendo el MISMO
//  `codeField`, para que el bloque encendido y la letra coincidan siempre.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void codeKernel(texture2d<float, access::write> luma  [[texture(ASCIIRTTextureIndexLumaRaw)]],
                       texture2d<float, access::write> color [[texture(ASCIIRTTextureIndexColor)]],
                       texture2d<float, access::write> mask  [[texture(ASCIIRTTextureIndexEyeMask)]],
                       constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    // El nivel se escribe PLANO en toda la celda a proposito. El downscale
    // promedia el tile para decidir la densidad, asi que cualquier degrade
    // adentro de la celda se perderia igual; escribirlo plano hace que el
    // promedio sea exactamente el nivel que eligio el campo.
    const uint2 cell = gid / max(params.tileSize, uint2(1u));
    const CodeCell field = codeField(cell, params);

    luma.write(float4(field.level), gid);

    // Alfa en 0: el alfa del color es la MASCARA DE CUERPO que usa el pleno del
    // ojo, no una opacidad. Escribiendo 1 el pleno rellenaba de gris todas las
    // celdas encendidas —con el valor que hubiera quedado de un preset del ojo,
    // en una seccion que ni siquiera se muestra con esta fuente— y el campo se
    // veia como bloques macizos en vez de caracteres. El codigo no tiene cuerpo:
    // son letras sueltas.
    color.write(float4(float3(field.level), 0.0), gid);

    // Sin ojo no hay mascara, pero se limpia igual: si no, la ultima que dibujo
    // el ojo se queda congelada abajo y el hueco reaparece al cambiar de fuente.
    mask.write(float4(0.0), gid);
}
