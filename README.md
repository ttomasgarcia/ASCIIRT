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
- **Presets** en JSON, más restauración automática del estado al abrir.

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
  └─> [3] Downscale     media por tile -> R16F cols×rows
  └─> [7] ASCII         luma de tile -> índice de rampa -> glifo del atlas
  └─> [8] Composite
  └─> [9] Fork          -> MTKView
```

Etapas fuera de la numeración base, para el modo Matrix:

```
  └─> [20] Relief       gaussiana separable sobre el grid + matte de sujeto
  └─> [21] Spawn        reducción por columna: fila de origen de la gota
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
| M4 — DoG + Sobel + glifos direccionales | pendiente |
| M5 — histéresis temporal, normalización de exposición | pendiente |
| M6 — grabación con AVAssetWriter (ProRes) | pendiente |
| M7 — render offline desacoplado del reloj | pendiente |
| M8 — resto de formatos de export, pulido | pendiente |

Fuera de la spec original, agregado sobre la marcha: modo Matrix, player de
archivo, presets con persistencia.

## Referencia

El enfoque de edge detection (M4) deriva conceptualmente de la implementación de
Acerola: [GarrettGunnell/Post-Processing](https://github.com/GarrettGunnell/Post-Processing)
y [AcerolaFX](https://github.com/GarrettGunnell/AcerolaFX). No es un port: eso es
ReShade/Unity y esto es Metal con otro modelo de threading.
