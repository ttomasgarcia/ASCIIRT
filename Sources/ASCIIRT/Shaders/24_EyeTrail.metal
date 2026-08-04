//  24_EyeTrail.metal — estela del ojo a resolucion completa
//
//  El arrastre de 23_Trail corre sobre el grid, o sea sobre la densidad de
//  caracteres. Eso alcanza para la imagen ASCII, pero el pleno del ojo y el
//  color por tile se componen desde la textura de color a resolucion completa y
//  no pasan por ahi: con Pleno alto —que es lo que tienen casi todos los
//  presets— la mayor parte de lo que se ve no dejaba rastro ninguno.
//
//  Este kernel arrastra el COLOR del ojo para que los caracteres de la cola
//  salgan del color del iris y no del color del campo. Lo que NO se arrastra es
//  el pleno: la mascara que dibuja el disco y el aro se toma sin estela, porque
//  el rastro tiene que estar hecho de glifos y no ser un manchon solido del
//  disco corriendose por la pantalla.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

kernel void eyeTrailKernel(texture2d<float, access::read>  current  [[texture(ASCIIRTTextureIndexColor)]],
                           texture2d<float, access::read>  previous [[texture(ASCIIRTTextureIndexEyeTrailPrev)]],
                           texture2d<float, access::write> next     [[texture(ASCIIRTTextureIndexEyeTrailNext)]],
                           constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) { return; }

    const float4 now = current.read(gid);
    const float4 old = previous.read(gid);

    // La disgregacion se calcula por CELDA y no por pixel aunque este kernel
    // corra a resolucion completa: por pixel seria ruido de sal y pimienta
    // dentro del disco, y lo que se busca es que se desarme en pedazos del
    // tamano de un caracter, para que combine con la estela del ASCII.
    const uint2 cell = gid / max(params.tileSize, uint2(1u));
    const uint cellHash = mixHash(cell.x) ^ (cell.y * 0x9e3779b9u);
    const uint timeStep = uint(max(params.time, 0.0) * 10.0);
    const float jitter = hash11(cellHash ^ mixHash(timeStep));
    // La disgregacion NO toca el factor de decaimiento: agrega un piso extra que
    // se resta por frame, distinto en cada celda.
    //
    // Escalar el factor por celda bajaba el promedio y acortaba la cola entera,
    // y descartar celdas enteras las mataba a todas porque el patron se
    // re-sortea y tarde o temprano a cada una le toca. Restando, la celda con
    // sorteo cero conserva el largo nominal —o sea que el alcance maximo del
    // rastro no cambia— y las demas llegan a cero antes, asi que la cola se va
    // agujereando a medida que envejece en vez de acortarse.
    const float step = 1.0 / 255.0;
    const float localDecay = params.trailDecay;
    const float extraFloor = params.trailDisperse * jitter * step * 0.25 * params.trailDeltaScale;

    const float faded = max(old.a * localDecay - step * params.trailDeltaScale - extraFloor, 0.0);

    // El color de lo que queda atras se va hacia el color del codigo. Se aplica
    // por frame, asi que la caida es exponencial: con el tinte en 0 la cola es
    // codigo desde el primer frame, y con valores intermedios el color del ojo
    // sobrevive cerca del frente y se pierde a lo largo del rastro.
    //
    // Sin esto la cola arrastra el rojo del cuerpo del ojo, y como ese cuerpo es
    // un disco lleno, lo que se ve no es una estela de caracteres sino el disco
    // entero corriendose por la pantalla.
    const float3 codeColor = float3(params.foregroundR, params.foregroundG, params.foregroundB);
    const float3 agedRGB = mix(codeColor, old.rgb, saturate(params.trailTint));

    // Gana el que mas cuerpo tiene, y se lleva SU color. Mezclar los dos daria
    // un promedio entre el iris y lo que haya quedado atras, y la cola saldria
    // de un color que no existe en ningun lado.
    next.write(now.a >= faded ? now : float4(agedRGB, faded), gid);
}
