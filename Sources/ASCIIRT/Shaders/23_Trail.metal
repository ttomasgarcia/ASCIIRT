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
                        texture2d<float, access::read>  eyeMask  [[texture(ASCIIRTTextureIndexEyeMask)]],
                        texture2d<float, access::read>  previous [[texture(ASCIIRTTextureIndexTrailPrev)]],
                        texture2d<float, access::write> next     [[texture(ASCIIRTTextureIndexTrailNext)]],
                        texture2d<float, access::write> out      [[texture(ASCIIRTTextureIndexTrailOut)]],
                        constant RenderParams &params [[buffer(ASCIIRTBufferIndexRenderParams)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    const float current = grid.read(gid).r;

    // Decaimiento multiplicativo MAS una resta fija. Solo con multiplicacion la
    // cola es una exponencial: se acerca a cero pero nunca llega, y con factores
    // altos se queda decadas de frames por encima del primer escalon de la rampa
    // — que es todo lo que hace falta para que quede un caracter encendido.
    // La resta garantiza que llegue a cero exacto en tiempo acotado.
    const float step = 1.0 / max(float(params.rampLength), 1.0);

    // Disgregacion: el decaimiento varia celda por celda. Con un factor unico la
    // cola entera baja al mismo ritmo y se lee como una atenuacion; variandolo,
    // unas celdas mueren enseguida y otras aguantan, y la cola se desarma en
    // puntos sueltos — que es como se deshace algo, no como se apaga.
    //
    // El patron cambia unas diez veces por segundo. Fijo se veria como una
    // trama estatica que la cola atraviesa; cambiando, la disgregacion avanza y
    // parece que la estela se va desarmando sola.
    const uint cellHash = mixHash(gid.x) ^ (gid.y * 0x9e3779b9u);
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
    const float localDecay = params.trailDecay;
    const float extraFloor = params.trailDisperse * jitter * step * 0.25 * params.trailDeltaScale;

    const float faded = max(previous.read(gid).r * localDecay - step * 0.05 * params.trailDeltaScale - extraFloor, 0.0);

    // Adentro del ojo la estela no se ve: un objeto tapa su propio pasado.
    //
    // El rastro se queda con el MAXIMO entre lo que hay ahora y lo que quedaba.
    // El interior del iris es oscuro, asi que cuando el aro brillante pasa por
    // encima y sigue de largo, el maximo conserva ese brillo dentro del circulo
    // y se ve como si las generaciones viejas de la estela flotaran arriba del
    // centro. Anulando el rastro donde la mascara dice que estamos adentro del
    // aro, el ojo se tapa a si mismo y la cola queda solo por fuera.
    float inside = 0.0;
    if (params.generative != 0u) {
        const uint2 centre = min(gid * params.tileSize + params.tileSize / 2u,
                                 params.outputSize - uint2(1u));
        inside = eyeMask.read(centre).r;
    }

    // La densidad atenua lo que ENTRA al rastro. La celda cae a un glifo mas
    // ralo apenas el frente la deja atras, y de ahi se apaga al ritmo de
    // siempre. Como arranca mas abajo, tambien toca el piso antes: bajar la
    // densidad acorta un poco el alcance ademas de aligerar la cola.
    const float entering = current * params.trailDensity;
    float state = mix(max(entering, faded), entering, inside);

    // Por debajo de medio escalon el glifo ya es el mas ralo de la rampa; dejar
    // decimales invisibles solo posterga el apagado.
    state = state > step * 0.5 ? state : 0.0;
    next.write(float4(state), gid);

    // Lo que ven las etapas de abajo lleva la fuente a fuerza plena: la densidad
    // es de la cola, no del frame actual.
    out.write(float4(max(current, state)), gid);
}
