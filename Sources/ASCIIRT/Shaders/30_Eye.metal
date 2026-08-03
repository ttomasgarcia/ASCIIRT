//  30_Eye.metal — fuente generativa: el ojo
//
//  Fuera de la numeracion [0]..[9] porque no es una etapa del pipeline: es una
//  FUENTE. Escribe en lumaRaw y color exactamente donde escribiria la camara, y
//  de ahi para abajo el pipeline no se entera de nada. Eso es lo que hace que el
//  ojo herede gratis la rampa calibrada, los glifos de borde, la histeresis, los
//  modos de color, la lluvia y el export.
//
//  La consecuencia de diseno mas importante: como todo pasa por la rampa, un
//  pulso de energia no se ve como un resplandor sino como una ola de caracteres
//  cambiando de densidad. El ASCII no muestra el efecto, ES el efecto.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void eyeKernel(texture2d<float, access::write> luma  [[texture(ASCIIRTTextureIndexLumaRaw)]],
                      texture2d<float, access::write> color [[texture(ASCIIRTTextureIndexColor)]],
                      constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const float2 size = float2(params.outputSize);
    const float2 uv = (float2(gid) + 0.5) / size;

    // El radio se mide contra el lado corto y la x se corrige por aspecto: sin
    // esto el ojo sale elipse en cualquier salida que no sea cuadrada.
    const float aspect = size.x / size.y;

    // El centro llega ya integrado: la deriva y la inercia las resuelve el
    // resorte en CPU, que es donde puede haber estado entre frames.
    const float2 center = float2(params.eyeCenterX, params.eyeCenterY);
    const float2 p = (uv - center) * float2(aspect, 1.0);
    const float r = length(p);

    // Respiracion: oscilacion lenta del radio. Amplitud relativa, asi cambiar el
    // tamano del ojo no cambia cuanto respira.
    const float breath = 1.0 + params.eyeBreathAmount
                       * sin(params.time * params.eyeBreathSpeed * kTau);
    const float radius = max(params.eyeRadius * breath, 1e-4);

    // --- Capas ---

    // Nucleo: lo unico que llega a los glifos mas densos de la rampa. Un iris
    // rojo plano nunca llegaria ahi y el centro se leeria sucio.
    const float core = 1.0 - smoothstep(0.0, max(params.eyeCoreRadius * radius, 1e-4), r);

    // Iris: cuerpo, con caida controlada por el exponente.
    const float iris = pow(saturate(1.0 - r / radius), max(params.eyeFalloff, 0.05));

    // Anillo de lente. Existe para el detector de bordes: la DoG lo encuentra y
    // el contorno del ojo termina TRAZADO con glifos direccionales en vez de ser
    // una mancha de densidad. Es el detalle que lo hace ver disenado.
    const float ringWidth = max(params.eyeRingWidth * radius, 1e-4);
    const float ringDistance = (r - radius) / ringWidth;
    const float ring = exp(-ringDistance * ringDistance) * params.eyeRingIntensity;

    // Halo: caida ancha y tenue. Los tiles lejanos caen en la punta rala de la
    // rampa, asi el codigo de alrededor se densifica hacia el centro en vez de
    // estar repartido parejo.
    const float halo = exp(-r / max(params.eyeHaloRadius, 1e-4)) * params.eyeHaloIntensity;

    // Pulsos: ondas radiales que salen del centro. La envolvente las apaga con
    // la distancia; sin ella el borde de la pantalla late igual que el centro.
    const float phase = (r - params.time * params.eyePulseSpeed) * params.eyePulseFrequency;
    const float wave = sin(phase * kTau) * 0.5 + 0.5;
    const float pulse = wave * exp(-r * params.eyePulseDecay) * params.eyePulseAmount;

    // Grano por celda, no por pixel: el pipeline promedia el tile igual, y a
    // nivel de pixel el ruido se cancelaria en el promedio sin cambiar nada.
    //
    // Solo afecta al campo de afuera (halo + pulsos) y no al cuerpo del ojo: el
    // iris tiene que quedar limpio o el ojo se ve sucio.
    const uint2 cell = gid / max(params.tileSize, uint2(1u));
    const float churnStep = floor(params.time * params.eyeFieldChurn);
    const uint cellHash = mixHash(cell.x) ^ (cell.y * 0x9e3779b9u);
    const float grain = hash11(cellHash ^ mixHash(uint(churnStep))) - 0.5;
    const float field = (halo + pulse) * (1.0 + grain * params.eyeFieldNoise * 2.0);

    const float luminance = saturate(core + iris + ring + field);

    // --- Color ---
    // Cuanto pertenece este pixel al ojo. El halo y los pulsos NO tinen: son el
    // campo de codigo alrededor y tienen que quedar del color del modo.
    const float redness = saturate(iris + ring);
    const float3 irisColor = float3(params.eyeIrisR, params.eyeIrisG, params.eyeIrisB);

    float3 rgb = mix(float3(1.0), irisColor, redness);
    // El nucleo quema a blanco por encima del tinte.
    rgb = mix(rgb, float3(1.0), core);

    // El alpha lleva la mascara del CUERPO del ojo — nucleo, iris y anillo, sin
    // halo ni pulsos. La etapa de composicion la usa para poder pintar el ojo
    // como pleno por encima de los glifos. Va a resolucion completa: si saliera
    // del grid, el disco tendria borde escalonado.
    const float body = saturate(core + iris + ring);

    luma.write(float4(luminance), gid);
    color.write(float4(rgb, body), gid);
}
