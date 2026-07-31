//  RenderParams.h
//
//  Fuente de verdad unica para los parametros que viajan Swift -> Metal.
//  Este archivo lo consumen dos caminos distintos:
//
//    1. Swift, via el target C `ShaderTypes` (import ShaderTypes).
//    2. El compilador MSL en runtime: `ShaderLibrary` lee este archivo como
//       texto y lo antepone a las fuentes .metal antes de compilar.
//
//  Por (2), los .metal NO deben hacer #include de este header: ya viene
//  concatenado adelante. Incluirlo daria doble definicion.
//
//  Se evita Foundation a proposito: el target es C puro, no ObjC, asi que
//  NSInteger no esta disponible. El patron NS_ENUM se replica a mano porque lo
//  que hace que Swift importe esto como enum nativo es la forma
//  `typedef enum X : tipo X; enum X : tipo {...}`, no el header de Foundation.
//
//  Layout: solo escalares de tamano fijo y vectores simd. Nada de bool ni de
//  enums sin tamano explicito.

#ifndef RenderParams_h
#define RenderParams_h

#ifdef __METAL_VERSION__
    // En MSL los tipos vienen de metal_stdlib, que ShaderLibrary ya incluyo
    // antes de pegar este header.
    #define ASCIIRT_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
    typedef int32_t EnumBackingType;
    #define ASCIIRT_UINT2 vector_uint2
    #define ASCIIRT_FLOAT2 vector_float2
#else
    #include <stdint.h>
    #include <simd/simd.h>
    #define ASCIIRT_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
    typedef int32_t EnumBackingType;
    #define ASCIIRT_UINT2 vector_uint2
    #define ASCIIRT_FLOAT2 vector_float2
#endif

/// Indices de textura compartidos entre el encoder en Swift y las firmas de los
/// kernels. Tenerlos aca evita el clasico desfasaje entre
/// `setTexture(_, index: 2)` y `[[texture(3)]]` al agregar una etapa.
typedef ASCIIRT_ENUM(EnumBackingType, ASCIIRTTextureIndex) {
    ASCIIRTTextureIndexSource = 0,   ///< BGRA de camara/archivo, importada zero-copy
    ASCIIRTTextureIndexLuma   = 1,   ///< R16F full-res, etapa [1]
    ASCIIRTTextureIndexGrid   = 2,   ///< R16F cols x rows, etapa [3]
    ASCIIRTTextureIndexAtlas  = 3,   ///< R8Unorm, glifos rasterizados en fila
    ASCIIRTTextureIndexOutput = 4,   ///< RGBA8 a resolucion de salida, etapa [8]
    ASCIIRTTextureIndexMatte = 5,    ///< R8 matte de sujeto (Vision), en espacio de la fuente
    ASCIIRTTextureIndexHeight = 6,   ///< R16F campo de altura para el relieve, tamano de grid
    ASCIIRTTextureIndexHeightTemp = 7, ///< R16F intermedia de la gaussiana separable
    ASCIIRTTextureIndexSpawn = 8,    ///< RG16F cols x 1: (fila de origen, brillo) por columna
};

typedef ASCIIRT_ENUM(EnumBackingType, ASCIIRTBufferIndex) {
    ASCIIRTBufferIndexRenderParams = 0,
};

/// Parametros por frame. Se sube con setBytes (entra holgado en el limite de
/// argumentos inline), nunca como MTLBuffer alocado dentro del render loop.
///
/// Orden de campos elegido para que el layout sea identico en Swift y MSL: los
/// vectores de 8 bytes van primero, los escalares de 4 al final.
typedef struct {
    /// Resolucion del render target en pixeles. El grid se deriva de aca
    /// (spec §3), nunca al reves.
    ASCIIRT_UINT2 outputSize;

    /// cols x rows = floor(outputSize / tileSize).
    ASCIIRT_UINT2 gridSize;

    /// Mapeo de UV de salida -> UV de la fuente: uvSrc = uvOut * scale + offset.
    /// Implementa el encuadre "fit" cuando la resolucion de salida y la de
    /// captura no comparten aspecto. Fuera de [0,1] la etapa [1] escribe negro,
    /// en vez de dejar que clamp_to_edge chorree el borde.
    ASCIIRT_FLOAT2 sourceScale;
    ASCIIRT_FLOAT2 sourceOffset;

    /// Tamano de celda en pixeles, ancho x alto.
    ///
    /// No es cuadrado: una celda tipografica tampoco lo es. El alto sale del
    /// aspecto natural de la fuente (ascent+descent sobre avance), que en una
    /// monoespaciada ronda 2:1. Forzarlo a cuadrado estira el glifo al doble de
    /// ancho, que es exactamente el aspecto "aplastado en Y".
    ASCIIRT_UINT2 tileSize;

    /// Cantidad de glifos en la rampa (= celdas del atlas).
    uint32_t rampLength;

    /// Modo Matrix: lluvia de glifos que mutan, gateada por la imagen.
    uint32_t matrixEnabled;

    /// Segundos desde que arranco el render. En modo offline (M7) tiene que
    /// venir del indice de frame y no del reloj de pared, o el efecto no seria
    /// reproducible entre corridas.
    float time;

    /// Filas por segundo que baja la cabeza de cada gota (antes del factor
    /// aleatorio por columna).
    float matrixSpeed;
    /// Largo del rastro en celdas.
    float matrixTrail;
    /// Cambios de glifo por segundo dentro del rastro.
    float matrixChurn;
    /// Con signo, -1 a 1.
    ///   > 0  la lluvia vive en la luz y el negro queda vacio
    ///   = 0  llueve parejo; la imagen solo altera recorrido y color
    ///   < 0  se invierte: la lluvia se mete en las sombras y la luz la apaga
    /// Un solo control con signo en vez de tres parametros, por la misma razon
    /// por la que Relieve lo tiene: el caso interesante suele estar cerca del
    /// cero y conviene poder cruzarlo arrastrando.
    float matrixImageMix;

    /// Relieve: cuantas celdas se adelanta o atrasa el frente de la gota segun
    /// la luminancia de la celda. La luma funciona como campo de altura — la luz
    /// corre adelante, la sombra queda atras — y el frente se curva sobre la
    /// forma en vez de bajar plano. Negativo invierte que es lo que sobresale.
    ///
    float matrixRelief;

    /// Radio en celdas del blur que produce el campo de altura. 0 = luma cruda.
    /// Con radio, el relieve sigue la forma en vez de la textura.
    uint32_t reliefRadius;

    /// Cuanto pesa el matte del sujeto contra la luma difuminada en la altura.
    float matteWeight;

    /// 0 cuando todavia no hay matte (Vision apagado, o el primero sin llegar).
    uint32_t matteAvailable;

    /// Brillo del ASCII que queda fuera del rastro de la lluvia. Es lo que
    /// decide cuanto se lee la imagen debajo del efecto.
    float matrixBaseLevel;


    /// Tinte de la punta: la cabeza y las primeras celdas del rastro salen en
    /// color mientras el resto queda en blanco y negro.
    uint32_t matrixHeadTintEnabled;
    /// Cuantas celdas desde la cabeza reciben el tinte. Fraccionario: el ultimo
    /// tramo se desvanece en vez de cortar, si no se ve un escalon duro.
    float matrixHeadCells;
    /// El color, en tres floats sueltos y no en un float3 a proposito: un
    /// vector de 3 obliga a alinear el struct entero a 16 bytes y complica
    /// mantener el layout igual de los dos lados.
    float matrixHeadColorR;
    float matrixHeadColorG;
    float matrixHeadColorB;

    /// De donde nace la gota. 0 = desde arriba de todo, 1 = desde la celda mas
    /// brillante de su columna. Con esto el brillo deja de ser algo que la
    /// lluvia ilumina al pasar y pasa a ser lo que la emite.
    float matrixSpawnBias;

    /// Cuanto modula el brillo del origen la fuerza de la gota. Sin esto una
    /// columna con un origen apenas gris emite igual de fuerte que una con un
    /// blanco pleno, y se pierde justamente la jerarquia que se buscaba.
    float matrixSpawnStrength;

    /// Gotas simultaneas por columna. Cada una con fase y velocidad propias, no
    /// repartidas parejo: espaciarlas de forma regular seria mas barato (un solo
    /// modulo en vez de un bucle) pero se leeria como una persiana bajando.
    uint32_t matrixDensity;

    /// Padding explicito para cerrar en multiplo de 8.
    uint32_t _pad0;
    uint32_t _pad1;
} RenderParams;

#endif /* RenderParams_h */
