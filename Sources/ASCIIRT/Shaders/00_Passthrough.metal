//  00_Passthrough.metal
//
//  Etapa [9] parcial: blit del frame de camara al drawable.
//  En M1 es todo el pipeline; a partir de M2 esta etapa dibuja el resultado
//  del kernel ASCII en vez de la textura cruda, sin cambiar de shader.
//
//  NO incluir RenderParams.h aca: ShaderLibrary lo antepone al compilar.

#include <metal_stdlib>
using namespace metal;

struct BlitVertexOut {
    float4 position [[position]];
    float2 uv;
};

/// Triangulo fullscreen generado desde vertex_id.
///
/// Por que un triangulo y no un quad: un quad son dos triangulos con una
/// diagonal compartida, y los fragmentos sobre esa diagonal se rasterizan en
/// quads de 2x2 pisados por ambos triangulos. Con uno solo, ademas, no hace
/// falta vertex buffer ni index buffer: cero allocations en el render loop.
vertex BlitVertexOut blitVertex(uint vid [[vertex_id]]) {
    // vid 0,1,2 -> uv (0,0), (2,0), (0,2). El triangulo se pasa del viewport
    // y el rasterizador lo recorta; lo que queda cubre exactamente el frame.
    const float2 uv = float2((vid << 1) & 2, vid & 2);

    BlitVertexOut out;
    // Y invertida: NDC crece hacia arriba, las texturas de CoreVideo crecen
    // hacia abajo. Corregirlo aca evita samplear con flip en el fragment.
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 blitFragment(BlitVertexOut in [[stage_in]],
                             texture2d<float, access::sample> source [[texture(ASCIIRTTextureIndexSource)]]) {
    // clamp_to_edge y no repeat: si el drawable y la fuente tienen aspect
    // distinto preferimos estirar el borde antes que espejar la imagen.
    constexpr sampler bilinear(filter::linear, mip_filter::none, address::clamp_to_edge);
    return source.sample(bilinear, in.uv);
}
