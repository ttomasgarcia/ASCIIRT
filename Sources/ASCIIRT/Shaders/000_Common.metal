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
