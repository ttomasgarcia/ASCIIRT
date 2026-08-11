//  000_Common.metal — utilidades compartidas
//
//  ShaderLibrary concatena TODOS los .metal en una sola unidad de traduccion, en
//  orden alfabetico. Por eso los helpers comunes viven aca y no repetidos: dos
//  definiciones de la misma funcion en dos archivos serian una redefinicion, no
//  dos funciones privadas. El prefijo 000 garantiza que este primero.
//
//  NO incluir RenderParams.h: ShaderLibrary lo antepone.

#include <metal_stdlib>
using namespace metal;

constant float kTau = 6.28318530718;

/// Mezclador entero de 32 bits (variante lowbias32).
///
/// Reemplaza a un hash mas simple que tenia estructura visible: combinando dos
/// coordenadas con `x*k1 ^ y*k2` quedaban regiones enteras del campo con valores
/// parecidos, y eso aparecia en pantalla como manchas de gran escala donde
/// tendria que haber grano parejo. Tres rondas de xor-shift y multiplicacion
/// cuestan nada y el patron desaparece.
static inline uint mixHash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static inline float hash11(uint n) {
    return float(mixHash(n) & 0x00ffffffu) / float(0x01000000);
}

/// El desplazamiento por la proporcion aurea antes de mezclar evita que (x,y) y
/// (y,x) colisionen.
static inline float hash21(uint2 p) {
    return hash11(mixHash(p.x) ^ (p.y * 0x9e3779b9u));
}

/// Campo suave y sin periodo visible, para deformar cosas.
///
/// Cuatro ondas planas en direcciones y frecuencias inconmensurables entre si
/// —las frecuencias son potencias de la proporcion aurea—. La suma de ondas con
/// razones irracionales es cuasiperiodica: no vuelve a alinearse nunca, que es
/// exactamente la propiedad que hace falta cuando lo que se quiere es que no se
/// note el patron.
///
/// Reemplaza a un ruido de valor fractal de tres octavas. El ruido era mejor en
/// teoria y peor en la practica: veinticuatro consultas al reticulado por
/// muestra, dos muestras por pixel, a resolucion completa. Medido, costaba 40%
/// del tiempo de frame. Esto cuesta cuatro senos y reparte la energia angular
/// incluso mejor (42% en los tres primeros armonicos contra 58% del ruido).
/// Redondea una frecuencia para que entre un numero ENTERO de ciclos en el
/// periodo del loop. Con periodo 0 devuelve la frecuencia intacta, que es el
/// caso del preview y del REC en vivo.
///
/// Redondear a 0 ciclos es un resultado valido y correcto: una oscilacion mas
/// lenta que el loop entero no puede cerrar de ninguna manera, y dejarla quieta
/// es preferible a un salto.
static inline float loopSnap(float rate, float period) {
    if (period <= 0.0) { return rate; }
    return round(rate * period) / period;
}

/// Indice de paso de un contador `floor(tiempo * ritmo + desfase)`, reducido al
/// numero de pasos que entran en el periodo.
///
/// El modulo no es cosmetico: sin el, el contador vale ~n al final del periodo y
/// 0 al principio, asi que en el cuadro del empalme TODAS las celdas cambian de
/// golpe —el seed salta n de una— cuando normalmente cada una muta en su propio
/// momento. Medido, ese unico cuadro daba un salto 3,3 veces mayor que el peor
/// paso normal: el loop cerraba, pero se veia el hipo. Reducido modulo n, el
/// paso del empalme es exactamente igual a cualquier otro.
static inline float loopStepIndex(float time, float rate, float offset, float period) {
    const float snapped = loopSnap(rate, period);
    const float step = floor(time * snapped + offset);
    if (period <= 0.0) { return step; }
    const float count = max(round(snapped * period), 1.0);
    return step - floor(step / count) * count;
}

static inline float quasiField(float2 p, float t, float timeScale, float period) {
    // Las cuatro frecuencias temporales pasan por el redondeo del loop. Van
    // multiplicadas por la escala de tiempo ANTES de redondear: lo que tiene que
    // cerrar es la frecuencia con la que este campo oscila en pantalla, no la
    // constante escrita aca.
    const float f0 = loopSnap(0.130 * timeScale, period);
    const float f1 = loopSnap(0.098 * timeScale, period);
    const float f2 = loopSnap(0.071 * timeScale, period);
    const float f3 = loopSnap(0.113 * timeScale, period);
    float s = sin(( p.x               ) * kTau * 1.000 + t * f0 * kTau) * 0.40;
    s      += sin(( p.x * 0.309 + p.y * 0.951) * kTau * 1.618 - t * f1 * kTau) * 0.30;
    s      += sin((-p.x * 0.809 + p.y * 0.588) * kTau * 2.618 + t * f2 * kTau) * 0.19;
    s      += sin((-p.x * 0.588 - p.y * 0.809) * kTau * 4.236 + t * f3 * kTau) * 0.11;
    return s;
}

/// Ventana de la rafaga de glitch. Devuelve 0 fuera de la racha y 1 adentro, y
/// escribe en `burst` el numero de racha para sembrar el resto de los hashes.
///
/// El glitch va a rachas y no continuo: permanente deja de leerse como falla y
/// pasa a ser textura. `chance` rompe el metronomo — con 1 dispara todos los
/// intervalos y se vuelve predecible enseguida.
static inline float glitchGate(float time, float rate, float duty, float chance,
                               float period, thread uint &burst) {
    const float t = time * loopSnap(max(rate, 1e-4), period);
    const float step = floor(t);
    // El numero de racha se reduce al periodo por la misma razon que el resto de
    // los contadores: si no, la racha del empalme nunca coincide con la de la
    // vuelta siguiente.
    const float seeded = period > 0.0
        ? step - floor(step / max(round(max(rate, 1e-4) * period), 1.0))
                 * max(round(max(rate, 1e-4) * period), 1.0)
        : step;
    burst = uint(int(seeded) & 0xffff) ^ 0x51ed270bu;
    if (hash11(mixHash(burst)) > saturate(chance)) { return 0.0; }
    return (t - step) < saturate(duty) ? 1.0 : 0.0;
}

/// Campo de codigo: renglones de caracteres al azar, con sangria, largos
/// desparejos y huecos entre palabras.
///
/// Lo comparten el generador —que escribe la imagen— y el pase ASCII —que elige
/// que letra va en cada celda—. Tiene que ser UNA sola funcion: si cada uno
/// derivara su propio renglon, el bloque encendido y la letra que lo llena se
/// despegarian apenas el campo se desplaza.
struct CodeCell {
    int line;
    float level;   // 0 = celda apagada
};

static inline CodeCell codeField(uint2 cell, constant RenderParams &params) {
    CodeCell out;

    // El desplazamiento es de a renglones ENTEROS. Uno suave, por pixel,
    // deslizaria el bloque encendido dejando las letras quietas dentro de su
    // celda: el campo se movería y el texto no.
    const int line = int(cell.y)
        + int(loopStepIndex(params.time, params.codeScroll, 0.0, params.loopPeriod));
    out.line = line;
    out.level = 0.0;

    const uint lineSeed = mixHash(uint(line + 4096) * 2654435761u);

    // Renglones vacios: el codigo respira. Un bloque parejo se lee como ruido.
    if (hash11(lineSeed) < saturate(params.codeLineGap)) { return out; }

    const float cols = float(max(params.gridSize.x, 1u));
    const float ragged = saturate(params.codeRagged);

    // El largo se mide DESDE la sangria, asi que subir el desparejo no corre el
    // renglon entero hacia la derecha: lo acorta.
    const float indent = floor(hash11(lineSeed ^ 0x27d4eb2fu) * ragged * cols * 0.30);
    const float span = cols * saturate(params.codeDensity)
        * mix(1.0, 0.25 + hash11(lineSeed ^ 0x165667b1u), ragged);

    const float x = float(cell.x);
    if (x < indent || x >= indent + span) { return out; }

    // Palabras: grupos contiguos separados por espacios. Sin esto el renglon es
    // una barra maciza de caracteres y deja de leerse como codigo.
    const uint word = uint((x - indent) / max(params.codeWordLength, 1.0));
    const float wordHash = hash11(lineSeed ^ mixHash(word * 374761393u));
    if (wordHash < 0.22) { return out; }

    out.level = mix(1.0, 0.35 + wordHash * 0.65, saturate(params.codeVariation))
              * max(params.codeLevel, 0.0);
    return out;
}
