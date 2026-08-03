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
                      texture2d<float, access::write> mask  [[texture(ASCIIRTTextureIndexEyeMask)]],
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
    //
    // Caida con soporte FINITO y no exponencial. Una exponencial tiene cola
    // infinita: su parametro no dice hasta donde llega el halo sino cada cuanto
    // se divide por e, y como el primer escalon de la rampa esta muy abajo, un
    // valor de 0.5 ya pintaba caracteres hasta las esquinas. Con esta el radio
    // significa literalmente el borde del campo, y el slider sirve entero.
    //
    // (1-t^2)^3 y no (1-t): la derivada es cero en los dos extremos, asi que no
    // hay ni pico en el centro ni corte visible en el borde. El cubo en vez del
    // cuadrado concentra mas el campo cerca del ojo: con el cuadrado la densidad
    // quedaba casi pareja en todo el radio y el degradado no se leia.
    //
    // Unidades: r esta medido contra la MEDIA altura de la salida, asi que el
    // borde vertical cae en 0.5 y las esquinas de un 16:9 en ~1.02.
    const float haloT = saturate(r / max(params.eyeHaloRadius, 1e-4));
    const float haloBase = 1.0 - haloT * haloT;
    const float haloFalloff = haloBase * haloBase * haloBase;
    const float halo = haloFalloff * params.eyeHaloIntensity;

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

    const float3 innerColor = float3(params.eyeIrisR, params.eyeIrisG, params.eyeIrisB);
    const float3 outerColor = float3(params.eyeIrisOuterR, params.eyeIrisOuterG, params.eyeIrisOuterB);

    // Gradiente del iris. El eje puede ser el radio o el angulo; en los dos
    // casos se anima corriendo la fase, no interpolando entre colores: correr la
    // fase hace que el gradiente VIAJE, que es lo que se lee como movimiento.
    float gradient = 0.0;
    if (params.eyeGradientMode == 1u) {
        const float rNorm = r / radius;
        gradient = fract(rNorm * params.eyeGradientCycles - params.time * params.eyeGradientSpeed);
    } else if (params.eyeGradientMode == 2u) {
        const float angle = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
        gradient = fract(angle * params.eyeGradientCycles + params.time * params.eyeGradientSpeed);
    }
    // Triangulo en vez de rampa: con `fract` sola el gradiente salta del ultimo
    // color al primero y queda una costura dura girando por el aro.
    gradient = 1.0 - abs(gradient * 2.0 - 1.0);

    const float3 irisColor = params.eyeGradientMode == 0u
        ? innerColor
        : mix(innerColor, outerColor, gradient);

    // El color del campo de codigo. Sale del color de tinta elegido en Color, no
    // de un blanco fijo: en modo "original por tile" es el unico lugar desde
    // donde se puede decidir de que color sale el codigo de alrededor.
    const float3 fieldColor = float3(params.foregroundR, params.foregroundG, params.foregroundB);

    // La transicion al color del iris arranca apenas hay cuerpo y termina
    // enseguida. Sin esto el aro se desvanecia HACIA el color del campo y dejaba
    // un borde claro alrededor del circulo: la caida del anillo llevaba `redness`
    // de 1 a 0 y el color con ella, cosa que en el pleno se ve como halo blanco
    // porque ahi el color se usa a brillo pleno, no atenuado por la luminancia.
    float3 rgb = mix(fieldColor, irisColor, smoothstep(0.02, 0.30, redness));

    // El nucleo pisa el color del iris segun su propia mezcla. En 0 no pisa
    // nada: el centro se queda con el color del gradiente y el nucleo solo
    // aporta luminancia, que es lo que hace falta cuando el gradiente esta
    // animado y un blanco fijo en el medio lo apaga.
    const float3 coreColor = float3(params.eyeCoreR, params.eyeCoreG, params.eyeCoreB);

    // Parpadeo: pulso periodico que cambia SOLO el color del nucleo. La onda es
    // una ventana con flancos suavizados en vez de un seno para que el tiempo
    // encendido sea regulable aparte del ritmo — con un seno, medio ciclo esta
    // siempre prendido y no se puede pedir un destello corto.
    float blink = 0.0;
    if (params.eyeBlinkEnabled != 0u) {
        const float phase = fract(params.time * params.eyeBlinkRate);
        const float duty = clamp(params.eyeBlinkDuty, 0.01, 0.99);
        // El flanco nunca es cero: un corte instantaneo titila feo cuando el
        // ritmo no es multiplo de los fps. Arriba llega a medio pulso, que es
        // donde la ventana se vuelve un triangulo y el parpadeo se hace respiro.
        const float edge = mix(0.004, duty * 0.5, saturate(params.eyeBlinkSoftness));
        blink = smoothstep(0.0, edge, phase) * (1.0 - smoothstep(duty - edge, duty, phase));
    }

    const float3 blinkColor = float3(params.eyeBlinkR, params.eyeBlinkG, params.eyeBlinkB);
    const float3 activeCore = mix(coreColor, blinkColor, blink);
    const float activeBlend = mix(params.eyeCoreBlend, 1.0, blink);
    rgb = mix(rgb, activeCore, core * activeBlend);

    // El alpha lleva la mascara del CUERPO del ojo — nucleo, iris y anillo, sin
    // halo ni pulsos. La etapa de composicion la usa para poder pintar el ojo
    // como pleno por encima de los glifos. Va a resolucion completa: si saliera
    // del grid, el disco tendria borde escalonado.
    const float body = saturate(core + iris + ring);

    // Mascara del interior: 1 bien adentro del aro, 0 afuera. La transicion cae
    // sobre el aro mismo para que al vaciar el interior el borde quede en el
    // anillo y no un escalon a mitad del iris.
    const float inner = 1.0 - smoothstep(radius - ringWidth, radius, r);

    luma.write(float4(luminance), gid);
    color.write(float4(rgb, body), gid);
    mask.write(float4(inner), gid);
}
