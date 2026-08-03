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
    const float localDecay = params.trailDecay * (1.0 - params.trailDisperse * jitter);

    const float faded = max(previous.read(gid).r * localDecay - step * 0.05, 0.0);

    // Por debajo de medio escalon el glifo ya es el mas ralo de la rampa; dejar
    // decimales invisibles solo posterga el apagado.
    const float value = max(current, faded);
    next.write(float4(value > step * 0.5 ? value : 0.0), gid);
}
