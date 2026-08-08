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
static inline float quasiField(float2 p, float t) {
    float s = sin(( p.x               ) * kTau * 1.000 + t * 0.130 * kTau) * 0.40;
    s      += sin(( p.x * 0.309 + p.y * 0.951) * kTau * 1.618 - t * 0.098 * kTau) * 0.30;
    s      += sin((-p.x * 0.809 + p.y * 0.588) * kTau * 2.618 + t * 0.071 * kTau) * 0.19;
    s      += sin((-p.x * 0.588 - p.y * 0.809) * kTau * 4.236 + t * 0.113 * kTau) * 0.11;
    return s;
}

/// Ventana de la rafaga de glitch. Devuelve 0 fuera de la racha y 1 adentro, y
/// escribe en `burst` el numero de racha para sembrar el resto de los hashes.
///
/// El glitch va a rachas y no continuo: permanente deja de leerse como falla y
/// pasa a ser textura. `chance` rompe el metronomo — con 1 dispara todos los
/// intervalos y se vuelve predecible enseguida.
static inline float glitchGate(float time, float rate, float duty, float chance,
                               thread uint &burst) {
    const float t = time * max(rate, 1e-4);
    const float step = floor(t);
    burst = uint(int(step) & 0xffff) ^ 0x51ed270bu;
    if (hash11(mixHash(burst)) > saturate(chance)) { return 0.0; }
    return (t - step) < saturate(duty) ? 1.0 : 0.0;
}
