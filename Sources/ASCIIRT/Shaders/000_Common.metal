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

/// Hash de un punto entero del reticulado 3D, en -1..1.
static inline float latticeHash3(int3 p) {
    const uint h = mixHash(uint(p.x * 73856093) ^ mixHash(uint(p.y * 19349663))
                           ^ mixHash(uint(p.z * 83492791)));
    return hash11(h) * 2.0 - 1.0;
}

/// Ruido de valor 3D. Reticulado entero, valor al azar en cada nodo e
/// interpolacion con la quintica de Perlin (6t^5-15t^4+10t^3), que tiene primera
/// y segunda derivada nulas en los nodos: con interpolacion cubica se ven las
/// aristas del reticulado como una grilla tenue, que es justo lo que hay que
/// evitar cuando el objetivo es que no se note el patron.
static inline float valueNoise3(float3 p) {
    const float3 i = floor(p);
    const float3 f = p - i;
    const float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    const int3 c = int3(i);

    const float n000 = latticeHash3(c + int3(0,0,0));
    const float n100 = latticeHash3(c + int3(1,0,0));
    const float n010 = latticeHash3(c + int3(0,1,0));
    const float n110 = latticeHash3(c + int3(1,1,0));
    const float n001 = latticeHash3(c + int3(0,0,1));
    const float n101 = latticeHash3(c + int3(1,0,1));
    const float n011 = latticeHash3(c + int3(0,1,1));
    const float n111 = latticeHash3(c + int3(1,1,1));

    const float x00 = mix(n000, n100, u.x);
    const float x10 = mix(n010, n110, u.x);
    const float x01 = mix(n001, n101, u.x);
    const float x11 = mix(n011, n111, u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
}

/// Tres octavas de ruido de valor, en -1..1 aproximadamente.
///
/// El salto de frecuencia es 2.13 y no 2: con el 2 exacto los nodos de las
/// octavas caen unos encima de otros cada dos niveles y el reticulado vuelve a
/// aparecer. Con un salto irracional las octavas nunca se alinean.
static inline float fbm3(float3 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    float total = 0.0;
    for (int o = 0; o < 3; ++o) {
        sum += valueNoise3(p) * amplitude;
        total += amplitude;
        p = p * 2.13 + 17.3;
        amplitude *= 0.5;
    }
    return sum / max(total, 1e-5);
}
