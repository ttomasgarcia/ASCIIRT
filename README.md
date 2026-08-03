# ASCIIRT

Conversión ASCII/textmode en tiempo real desde webcam o archivo de video, nativa
para macOS. Pipeline de video completo en GPU: sin round-trip a CPU, sin
librerías ASCII de terceros.

![estado](https://img.shields.io/badge/estado-en%20desarrollo-orange)

## Qué hace hoy

- **Captura** desde cualquier cámara del sistema (incluida Continuity Camera) o
  desde archivo de video, con player propio: transporte, scrub con tolerancia
  cero, avance frame a frame, loop.
- **Rampa calibrada por cobertura de tinta.** El orden de los glifos no se
  hardcodea: se rasteriza el charset, se mide la tinta de cada glifo y se ordena.
  La tabla de cobertura es visible y cada glifo se puede excluir.
- **Celda con aspecto tipográfico.** El alto de celda sale del aspecto natural
  de la fuente, así el glifo no sale deformado.
- **Modo Matrix**: lluvia de glifos que mutan, con relieve por campo de altura
  (luma difuminada + segmentación de sujeto por Vision), origen de gota en el
  punto más brillante de cada columna, y tinte de punta configurable.
- **Glifos direccionales por borde.** DoG + Sobel + tensor de estructura por
  tile: los contornos se dibujan con `-` `/` `|` `\` y ganan sobre la rampa de
  luminancia, que es lo que separa esto de un filtro de brillo.
- **Histéresis temporal.** Sin ella la salida hierve: sobre escena estática, el
  30% de los píxeles cambia entre dos frames. Con el default de 0,08 baja a
  0,02%.
- **Grabación y export.** REC en vivo a ProRes, y render offline desacoplado del
  reloj donde cada frame de entrada produce exactamente uno de salida. ProRes
  422 HQ / 4444, H.264 y secuencia PNG numerada. Audio del archivo pasa sin
  recodificar.
- **Modo ojo**: fuente generativa sin entrada — un núcleo rojo con anillo de
  lente, halo, respiración y pulsos de energía radiales, que se mueve con
  inercia siguiendo el mouse. No es un modo aparte: genera luminancia y color
  donde escribiría la cámara, así que hereda la rampa calibrada, los glifos de
  borde, la histéresis, la lluvia y el export.
- **Modos de color**: mono, dos colores, o color original promediado por tile.
  Más invertir y fondo transparente para ProRes 4444 / secuencia PNG.
- **Arrastre**: el campo del frame anterior sobrevive atenuado, así el ASCII
  deja estela al moverse. Es el mismo mecanismo que el fósforo de un tubo.
- **Presets** en JSON, más restauración automática del estado al abrir. Diez
  presets del ojo vienen en `Presets/` — copialos a
  `~/Library/Application Support/ASCIIRT/Presets/`.

## Requisitos

- macOS 14+, Apple Silicon
- Swift 5.9+

**No requiere Xcode.** Los shaders Metal se compilan en runtime desde
`Sources/ASCIIRT/Shaders/*.metal`, así que alcanza con las Command Line Tools.
Si hay Xcode disponible, cambiar a `.metallib` precompilado es reemplazar una
función en `Metal/ShaderLibrary.swift`.

## Build

```bash
./Scripts/build.sh && open build/ASCIIRT.app
```

El script compila con SwiftPM, arma el bundle a mano (la cámara necesita
`Info.plist` con `NSCameraUsageDescription`) y lo firma ad-hoc. La identidad TCC
de una firma ad-hoc es el cdhash, así que **cada rebuild vuelve a pedir permiso
de cámara**.

## Arquitectura

Todo el trabajo por frame ocurre en GPU, en un solo command buffer:

```
CVPixelBuffer (BGRA)
  └─> [0] Import        CVMetalTextureCache, zero-copy
  └─> [1] Luma          Rec.709 -> R16F a resolución de salida
  └─> [2] Normalize     corrección de exposición por media móvil
  └─> [3] Downscale     media por tile -> R16F cols×rows
  └─> [4] DoG           diferencia de gaussianas, las dos en una pasada
  └─> [5] Sobel         gradiente H+V sobre la DoG
  └─> [6] EdgeQuantize  tensor de estructura por tile -> bin direccional
  └─> [6b] GlyphIndex   bordes sobre luminancia + histéresis temporal
  └─> [7] ASCII         samplea el glifo elegido del atlas
  └─> [8] Composite
  └─> [9] Fork          -> MTKView
```

Etapas fuera de la numeración base, para el modo Matrix:

```
  └─> [20] Relief       gaussiana separable sobre el grid + matte de sujeto
  └─> [21] Spawn        reducción por columna: fila de origen de la gota
  └─> [22] Stats        media de luminancia, consumida por [2] del frame siguiente
  └─> [30] Eye          fuente generativa: escribe donde escribiría la cámara
```

Los parámetros viajan a los shaders en un único struct `RenderParams` compartido
entre Swift y Metal vía un header C puenteado, para que no puedan desfasarse.

### Estructura

```
Sources/
  ShaderTypes/include/RenderParams.h   struct + índices de textura/buffer
  ASCIIRT/
    App/        modelo observable, presets, errores
    Capture/    AVCaptureSession y AVPlayer detrás de un protocolo común
    Metal/      contexto, librería en runtime, atlas de fuente, Vision
    Render/     pipeline de compute, renderer del preview
    Shaders/    un .metal por etapa
    UI/         SwiftUI
```

## Estado

| Milestone | |
|---|---|
| M1 — captura + preview Metal | ✅ |
| M2 — luma, grid, kernel ASCII | ✅ |
| M3 — atlas dinámico, calibración, charset | ✅ |
| M4 — DoG + Sobel + glifos direccionales | ✅ |
| M5 — histéresis temporal, normalización de exposición | ✅ |
| M6 — grabación con AVAssetWriter (ProRes) | ✅ |
| M7 — render offline desacoplado del reloj | ✅ |
| M8 — resto de formatos de export, pulido | ✅ |

Fuera de la spec original, agregado sobre la marcha: modo Matrix, player de
archivo, presets con persistencia.

### Verificado con medición

- **Histéresis**: sobre escena estática, la fracción de píxeles que cambia entre
  dos frames pasa de 30,63 % con el umbral en 0 a 0,02 % con histéresis activa
  (spec §10). El umbral se mide en escalones de rampa, no en luminancia
  absoluta — ver el comentario en `06b_GlyphIndex.metal`.
- **Rampa calibrada**: 69 de 69 glifos ordenados por cobertura medida.
- **Presets**: round-trip de 14 valores distintivos, todos sobreviven a
  guardar → cerrar → abrir.

### Sin verificar de punta a punta

El export a disco (REC en vivo y render offline) está escrito y revisado, y la
grabación en vivo la probó el autor con éxito, pero el conteo de frames del
render offline contra el original no se midió todavía. El criterio §10 —"frame
count de entrada == frame count de salida"— sigue abierto.

## Referencia

El enfoque de edge detection (M4) deriva conceptualmente de la implementación de
Acerola: [GarrettGunnell/Post-Processing](https://github.com/GarrettGunnell/Post-Processing)
y [AcerolaFX](https://github.com/GarrettGunnell/AcerolaFX). No es un port: eso es
ReShade/Unity y esto es Metal con otro modelo de threading.
