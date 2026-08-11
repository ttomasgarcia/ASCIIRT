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
    ASCIIRTTextureIndexSpawn = 8,     ///< RG16F cols x 1: (fila de origen, brillo) por columna
    ASCIIRTTextureIndexLumaRaw = 9,   ///< R16F sin normalizar, etapa [1]
    ASCIIRTTextureIndexDoGTemp = 10,  ///< RG16F intermedia de la DoG separable
    ASCIIRTTextureIndexDoG = 11,      ///< R16F diferencia de gaussianas, etapa [4]
    ASCIIRTTextureIndexSobel = 12,    ///< RG16F gradiente H+V, etapa [5]
    ASCIIRTTextureIndexEdge = 13,     ///< RG16F por tile: (bin direccional, magnitud), etapa [6]
    ASCIIRTTextureIndexGlyphPrev = 14,///< RG8Uint por tile del frame anterior (histeresis)
    ASCIIRTTextureIndexGlyphNext = 15,///< RG8Uint por tile de este frame
    ASCIIRTTextureIndexEdgeAtlas = 16,///< R8Unorm: los 4 glifos direccionales
    ASCIIRTTextureIndexColor = 17,    ///< RGBA8 color de la fuente a resolucion de salida
    ASCIIRTTextureIndexGridColor = 18,///< RGBA8 color medio por tile
    ASCIIRTTextureIndexTrailPrev = 19,///< R16F campo arrastrado del frame anterior
    ASCIIRTTextureIndexTrailNext = 20,///< R16F campo arrastrado de este frame
    ASCIIRTTextureIndexEyeMask = 21,  ///< R8 mascara del interior del ojo, a resolucion completa
    ASCIIRTTextureIndexEyeTrailPrev = 22, ///< RGBA8 color+cuerpo del ojo arrastrado, frame anterior
    ASCIIRTTextureIndexEyeTrailNext = 23, ///< RGBA8 color+cuerpo del ojo arrastrado, este frame
    ASCIIRTTextureIndexTrailOut = 24, ///< R16F lo que ven las etapas de abajo: fuente + rastro
    ASCIIRTTextureIndexChat = 25,     ///< RG8Uint por celda: (indice de caracter + 1, opacidad del globo)
    ASCIIRTTextureIndexTextAtlas = 26,///< R8Unorm, atlas de texto para los globos
};

/// Un globo de chat, en PIXELES de salida.
///
/// El fondo no puede salir de la textura por celda: ahi el borde tiene la
/// resolucion de la celda y el redondeo sale en escalera por mas radio que se le
/// ponga. Pasando el rectangulo y el radio, el shader lo resuelve por pixel con
/// una funcion de distancia y la curva queda lisa.
///
/// El TEXTO si sigue viniendo por celda: ahi la grilla es la que corresponde.
typedef struct {
    ASCIIRT_FLOAT2 origin;
    ASCIIRT_FLOAT2 size;
    float radius;
    float alpha;
    float _pad0;
    float _pad1;
} ASCIIRTChatRect;

typedef ASCIIRT_ENUM(EnumBackingType, ASCIIRTBufferIndex) {
    ASCIIRTBufferIndexRenderParams = 0,
    /// Un float: la media movil de luminancia del frame. Vive en GPU entre
    /// frames para no tener que sincronizar con CPU (spec §4b).
    ASCIIRTBufferIndexLumaStats = 1,
    /// Hasta `chatRectCount` globos.
    ASCIIRTBufferIndexChatRects = 2,
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

    // MARK: Bordes (spec §1 etapas [4][5][6])

    /// 0 = bypass de bordes, para comparar contra luminancia pura.
    uint32_t edgesEnabled;
    /// Sigmas de la diferencia de gaussianas. sigma1 < sigma2.
    float dogSigma1;
    float dogSigma2;
    /// Cuanto se resta la gaussiana ancha. Cerca de 1 el resultado es casi solo
    /// borde; por debajo queda algo de la imagen y el borde sale mas suave.
    float dogTau;
    /// Por encima de esto el tile usa glifo direccional en vez de rampa.
    float edgeThreshold;

    // MARK: Temporal (spec §5)

    /// Zona muerta de la histeresis, medida en ESCALONES de rampa y no en
    /// luminancia absoluta. En escalones el control significa lo mismo con 10
    /// glifos que con 69; en absoluto, con una rampa larga la zona muerta abarca
    /// varios glifos y los tiles se traban. 0 desactiva la histeresis.
    float hysteresisThreshold;

    // MARK: Exposicion (spec §4b)

    /// Mezcla entre luma cruda (0) y normalizada (1).
    float autoLevelStrength;
    /// Alpha de la media movil exponencial de luminancia.
    float lumaSmoothAlpha;
    /// Punto medio al que se lleva la luminancia media.
    float lumaTarget;

    // MARK: Color (spec §8)

    /// 0 mono (frente sobre negro), 1 dos colores, 2 color original por tile.
    uint32_t colorMode;
    /// Invierte tinta y fondo. Util cuando la salida va sobre papel.
    uint32_t invert;
    /// Fondo transparente. Solo tiene sentido exportando a ProRes 4444; en los
    /// demas formatos el alpha se aplasta contra negro igual.
    uint32_t transparentBackground;

    float foregroundR;
    float foregroundG;
    float foregroundB;
    float backgroundR;
    float backgroundG;
    float backgroundB;

    // MARK: Fuente generativa — el ojo
    //
    // No es un modo del pipeline sino una FUENTE: el kernel escribe en lumaRaw y
    // color donde escribiria la camara, y todo lo de abajo sigue igual.

    uint32_t generativeEnabled;

    /// Centro ya resuelto por la fisica de CPU (ver EyeMotion). El shader no
    /// integra nada: recibe la posicion del frame y dibuja.
    float eyeCenterX;
    float eyeCenterY;

    /// Radio del iris, relativo al lado corto de la salida.
    float eyeRadius;
    /// Radio del nucleo, como fraccion del radio del iris.
    float eyeCoreRadius;
    /// Exponente de la caida del iris. Alto = borde duro.
    float eyeFalloff;

    /// Anillo de lente. Existe para que el detector de bordes trace el contorno
    /// del ojo con glifos direccionales.
    float eyeRingWidth;
    float eyeRingIntensity;

    /// Halo: caida ancha que hace que el codigo de alrededor se densifique
    /// hacia el centro.
    float eyeHaloRadius;
    float eyeHaloIntensity;

    float eyeIrisR;
    float eyeIrisG;
    float eyeIrisB;

    /// Respiracion: oscilacion lenta del radio, amplitud relativa.
    float eyeBreathAmount;
    float eyeBreathSpeed;

    /// Pulsos de energia radiales.
    float eyePulseAmount;
    float eyePulseSpeed;
    float eyePulseFrequency;
    float eyePulseDecay;

    /// Grano del campo. Un halo liso, cuantizado por la rampa, sale en bandas
    /// concentricas — se lee como degradado, no como codigo. El grano rompe la
    /// banda haciendo que celdas vecinas caigan en glifos distintos.
    float eyeFieldNoise;
    /// Cambios por segundo del grano. Bajo = campo quieto que respira; alto =
    /// el codigo se refresca solo.
    float eyeFieldChurn;

    /// Cuanto reemplaza el pleno al ASCII dentro del cuerpo del ojo. 0 = todo
    /// glifos como hasta ahora, 1 = disco pleno.
    float eyeSolidAmount;
    /// Ganancia del pleno. Por encima de 1 el ojo pega mas fuerte que el ASCII
    /// que lo rodea, que es justamente para lo que existe.
    float eyeSolidGain;
    /// 0 usa la caida natural del iris; 1 corta en disco de borde duro.
    float eyeSolidEdge;

    /// Padding explicito para cerrar en multiplo de 8.
    uint32_t _pad0;

    /// Arrastre: cuanto sobrevive el campo del frame anterior. 0 lo apaga, 0.9
    /// deja una estela larga. Es el mismo mecanismo que el fosforo de un tubo.
    float trailDecay;

    // MARK: Interior del ojo

    /// Vacia de glifos el area de adentro del anillo. El pleno y el anillo
    /// siguen dibujandose; lo que desaparece es el ASCII.
    uint32_t eyeHollow;

    /// 0 unicolor, 1 gradiente radial que viaja hacia afuera, 2 gradiente
    /// angular que gira alrededor del centro.
    uint32_t eyeGradientMode;
    /// Vueltas o viajes por segundo. Negativo invierte el sentido.
    float eyeGradientSpeed;
    /// Repeticiones del gradiente a lo largo de su eje. 1 = una sola transicion.
    float eyeGradientCycles;

    /// Color del extremo lejano del gradiente. El cercano es el iris.
    float eyeIrisOuterR;
    float eyeIrisOuterG;
    float eyeIrisOuterB;

    /// Color del nucleo. Era blanco fijo, y con el gradiente animado ese blanco
    /// se comia el centro del efecto justo donde mas se mira.
    float eyeCoreR;
    float eyeCoreG;
    float eyeCoreB;
    /// Cuanto pisa el nucleo al color del iris. En 0 el centro toma el color del
    /// gradiente y el nucleo solo aporta luminancia.
    float eyeCoreBlend;

    /// Disgregacion de la estela: cuanto varia el decaimiento celda por celda.
    /// En 0 la cola baja pareja y se apaga entera; subiendolo, unas celdas
    /// mueren enseguida y otras aguantan, asi que la cola se desarma en puntos
    /// sueltos en vez de simplemente atenuarse.
    float trailDisperse;

    /// Parpadeo del nucleo: cada tanto el punto del centro cambia al color de
    /// abajo y vuelve. Toca SOLO el nucleo — el iris, el aro y el halo siguen su
    /// gradiente sin enterarse — porque el objetivo es un acento puntual, y si
    /// parpadeara todo el ojo se leeria como un corte de luz.
    ///
    /// Mientras dura el parpadeo la mezcla del nucleo se fuerza a 1: si respetara
    /// `eyeCoreBlend`, con la fuerza en 0 el color elegido no se veria nunca y el
    /// control pareceria roto.
    uint32_t eyeBlinkEnabled;
    /// Parpadeos por segundo.
    float eyeBlinkRate;
    /// Fraccion del ciclo con el color puesto. Bajo = destello corto; alto = el
    /// color es el estado normal y lo que parpadea es el original.
    float eyeBlinkDuty;
    /// 0 = corte duro, tipo testigo de alarma. 1 = entra y sale suave, mas
    /// respiracion que parpadeo.
    float eyeBlinkSoftness;
    float eyeBlinkR;
    float eyeBlinkG;
    float eyeBlinkB;

    /// De que color queda la cola. En 1 conserva el color del ojo, y como el
    /// cuerpo del ojo es una masa roja grande, la cola se lee como esa masa
    /// corriendose por la pantalla. En 0 la cola toma el color del codigo apenas
    /// pasa el frente, asi que lo que queda atras son caracteres y no un fantasma
    /// del disco. El decaimiento es exponencial: valores intermedios dejan el
    /// color del ojo cerca del frente y lo van perdiendo a lo largo de la cola.
    float trailTint;

    /// Cuanto se deforma el frente de los pulsos. En 0 son circunferencias
    /// concentricas —geometricas, se leen como un patron de test— y subiendolo la
    /// fase se corre segun el angulo y el frente se abolla. No cambia ni el ritmo
    /// ni el alcance: solo la forma.
    float eyePulseShape;

    /// Duracion del frame en unidades de 1/60 s. Existe para que la estela dure
    /// lo mismo sin importar a cuantos fps se este corriendo: el arrastre se
    /// aplica una vez por frame, asi que a 120 Hz la cola se apagaba en la mitad
    /// de tiempo que a 60, y en un render offline a 24 o 30 fps salia mucho mas
    /// larga que lo que se vio en pantalla al ajustarla.
    ///
    /// El factor de decaimiento ya viene corregido desde la CPU; esto escala los
    /// pisos que se restan por frame, que son la otra mitad del apagado.
    float trailDeltaScale;

    /// 1 cuando la imagen la genera el ojo. Lo miran las etapas de estela para
    /// saber si la mascara del interior del ojo tiene contenido valido: con
    /// camara o archivo esa textura no se escribe.
    uint32_t generative;

    /// Con cuanta fuerza entra cada celda al rastro, respecto de su valor en la
    /// imagen. En 1 la cola arranca igual de densa que la fuente —que es lo que
    /// hacia siempre— y por eso el rastro se veia con el mismo peso pase lo que
    /// pase. Bajandolo, la celda cae de golpe a un glifo mas ralo apenas el
    /// frente la deja atras, y de ahi se apaga normalmente. El ritmo de apagado
    /// no cambia, pero al arrancar mas abajo la cola toca el piso antes, asi que
    /// bajar la densidad tambien acorta un poco el alcance.
    ///
    /// Escala lo que ENTRA al rastro y no lo que sale. Escalar la salida se
    /// compondria frame a frame y terminaria siendo otro control de duracion.
    float trailDensity;

    // ---- Glitch -------------------------------------------------------------
    //
    // Todo cuantizado a la CELDA: nada se corre medio caracter. Es lo que hace
    // que se lea como corrupcion del codigo y no como un filtro de video con
    // letras debajo, y lo que lo mantiene geometrico.
    //
    // Todo sale de hashes de (celda, numero de rafaga), y el numero de rafaga es
    // floor(tiempo * ritmo). O sea que es una funcion pura del tiempo, igual que
    // los modos de mirada: el render offline saca exactamente la misma secuencia
    // de fallas que se vio en pantalla.
    uint32_t glitchEnabled;

    /// Rafagas por segundo. El glitch NO es continuo: pasa a rachas y el resto
    /// del tiempo la imagen esta limpia. Un glitch permanente deja de leerse
    /// como falla y pasa a ser textura.
    float glitchRate;
    /// Que fraccion de cada intervalo dura la racha.
    float glitchDuty;
    /// Probabilidad de que un intervalo dispare. Debajo de 1 el ritmo deja de
    /// ser de metronomo, que es lo que mas delata que hay un generador atras.
    float glitchChance;
    /// Intensidad general. Escala el corrimiento de las bandas.
    float glitchAmount;

    /// Alto de cada banda en celdas, y cuanto se puede correr en horizontal.
    float glitchBandHeight;
    float glitchBandShift;
    /// Que fraccion de las bandas se corre en cada racha.
    float glitchBandAmount;

    /// Bloques rectangulares corrompidos.
    float glitchBlockCount;

    /// Lado del modulo base, en FILAS de celda. Todos los bloques miden un
    /// multiplo entero de esto y arrancan pegados a la grilla de modulos, asi que
    /// se alinean entre si en vez de caer donde toque.
    ///
    /// El ancho del modulo se deriva del aspecto de la celda para que el modulo
    /// salga CUADRADO EN PANTALLA. Una celda tipografica es mas alta que ancha
    /// —16x31 px con los defaults— asi que un modulo de n x n celdas saldria un
    /// rectangulo parado y la grilla entera se veria estirada.
    float glitchModule;

    /// Cuantos modulos de lado puede llegar a medir un bloque. Las proporciones
    /// salen de una tabla corta (1:1, 2:1, 1:2, 3:1, 1:3, 2:2, 4:1, 1:4) en vez
    /// de un sorteo continuo: con medidas libres cada rectangulo es distinto y el
    /// conjunto se lee como accidente; con pocas proporciones repetidas se lee
    /// como sistema.
    float glitchBlockScale;
    /// 0 solido, 1 trama, 2 invertido, 3 vacio.
    uint32_t glitchBlockFill;

    /// Fraccion de celdas que retienen el glifo del frame anterior. Se resuelve
    /// en la etapa de indice y no en la composicion: ahi el valor retenido se
    /// propaga solo de frame a frame, asi que la celda se queda clavada toda la
    /// racha en vez de quedar un cuadro atrasada.
    float glitchFreeze;

    /// Fraccion de celdas a las que se les corre el indice de glifo. El caracter
    /// sale mal pero la estructura de densidad sobrevive, asi que se lee como
    /// texto corrompido y no como ruido.
    float glitchScramble;

    // ---- Chat ---------------------------------------------------------------
    //
    // El texto se escribe DIRECTO en la grilla, una letra por celda, y no se
    // pasa por la rampa. Un texto convertido a ASCII queda ilegible a los
    // tamanos de celda que se usan: se lee como una mancha de densidad con forma
    // de renglon. El maquetado y los tiempos los resuelve la CPU y llegan aca
    // como una textura de grid con (caracter, opacidad) por celda.
    uint32_t chatEnabled;

    /// La fuente es SOLO el chat: el generador escribe negro y los globos son
    /// todo lo que hay. Va como parametro y no como una rama en Swift porque el
    /// resto del pipeline tiene que correr igual — rampa, glitch, color y export
    /// se comportan como con cualquier otra fuente.
    uint32_t chatOnly;

    /// Cuantas celdas ocupa cada caracter por lado. El shader lo necesita para
    /// saber que pedazo del glifo le toca a cada celda.
    uint32_t chatScale;

    float chatTextR, chatTextG, chatTextB;
    /// Color y opacidad del globo. En 0 el texto flota sin fondo.
    float chatBubbleR, chatBubbleG, chatBubbleB;
    float chatBubbleAlpha;

    /// Desplazamiento vertical del globo, en PIXELES de salida y hacia abajo.
    ///
    /// El maquetado vive en la grilla, asi que la CPU solo puede mover el globo
    /// de a celdas enteras y el movimiento sale a los saltos. Corriendo la
    /// lectura de la capa por pixeles, en cambio, el globo se desliza suave sin
    /// que el texto pierda nitidez: lo que se mueve es de donde se lee, no como
    /// se dibuja.
    ///
    /// Es UNO solo para toda la capa, asi que solo sirve cuando hay un globo a la
    /// vez. En pila hay varios y cada uno con su animacion, y ahi se sigue
    /// moviendo de a celdas.
    float chatOffsetY;

    /// Cuantos globos hay en el buffer de rectangulos.
    uint32_t chatRectCount;

    // --- Fuente Codigo -----------------------------------------------------
    //
    // Un campo de caracteres al azar organizado en renglones, para usar de
    // fondo. No es una capa aparte: escribe en lumaRaw como cualquier fuente y
    // solo se reserva la eleccion del glifo, porque la rampa elige por densidad
    // y la densidad de un renglon de codigo es plana — sin pisar el indice,
    // todas las celdas encendidas saldrian con la MISMA letra.

    /// La fuente es el campo de codigo.
    uint32_t codeEnabled;

    /// Que proporcion del ancho ocupa un renglon lleno.
    float codeDensity;

    /// Cambios de letra por segundo en cada celda.
    float codeChurn;

    /// Renglones por segundo que sube el campo. En 0 queda quieto.
    float codeScroll;

    /// Proporcion de renglones vacios. Un bloque parejo se lee como ruido.
    float codeLineGap;

    /// Cuanto varian la sangria y el largo entre renglones.
    float codeRagged;

    /// Largo medio de las palabras, en celdas.
    float codeWordLength;

    /// Brillo base del campo.
    float codeLevel;

    /// Cuanto varia el brillo entre palabras.
    float codeVariation;

    /// Periodo del loop en segundos. 0 = sin loop (preview y REC en vivo).
    ///
    /// Con un periodo puesto, TODA frecuencia temporal se redondea para que
    /// entre un numero entero de ciclos adentro. Es lo unico que hace que un
    /// minuto exportado empalme consigo mismo: sin esto cada oscilacion —el
    /// pulso, la respiracion, el churn, la lluvia— queda cortada en una fase
    /// cualquiera y el corte se ve como un salto.
    ///
    /// El redondeo mueve las velocidades menos de un 2% con periodos de decenas
    /// de segundos, asi que el preview y el loop se ven iguales.
    float loopPeriod;
} RenderParams;

#endif /* RenderParams_h */
