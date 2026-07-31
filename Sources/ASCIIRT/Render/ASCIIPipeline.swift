import Metal
import QuartzCore
import ShaderTypes
import simd

/// Parametros de configuracion que el usuario mueve. Cambiarlos puede forzar
/// reasignacion de texturas o del atlas, asi que no se tocan por frame.
struct PipelineConfig: Equatable {
    var outputSize: SIMD2<UInt32> = SIMD2(1920, 1080)
    /// Ancho x alto de celda en pixeles. El alto no es igual al ancho: sale del
    /// aspecto natural de la fuente (ver AppModel.cellAspect).
    var tileSize: SIMD2<UInt32> = SIMD2(8, 16)
    var font: FontSelection = .system(name: "Menlo-Regular")
    /// Charset en orden de tipeo. El orden que importa — la rampa — lo decide la
    /// cobertura medida en FontAtlasBuilder, no este array (spec §2).
    var charset: [Character] = Array(PipelineConfig.defaultCharset)
    /// Glifos que el usuario saco de la rampa sin borrarlos del charset.
    var excluded: Set<Character> = []

    // MARK: Matrix
    var matrixEnabled = false
    var matrixSpeed: Float = 14
    var matrixTrail: Float = 18
    var matrixChurn: Float = 12
    var matrixImageMix: Float = 0.75
    var matrixRelief: Float = 10
    var reliefRadius: UInt32 = 5
    var matteWeight: Float = 0.6
    var subjectMatteEnabled = false
    var matrixBaseLevel: Float = 0.30
    var matrixHeadTintEnabled = false
    var matrixHeadCells: Float = 3
    var matrixHeadColor: SIMD3<Float> = SIMD3(1.0, 0.10, 0.10)
    var matrixSpawnBias: Float = 0
    var matrixSpawnStrength: Float = 0.6
    var matrixDensity: UInt32 = 1

    // MARK: Bordes (M4)
    var edgesEnabled = true
    var dogSigma1: Float = 0.8
    var dogSigma2: Float = 2.4
    var dogTau: Float = 0.9
    var edgeThreshold: Float = 0.12

    // MARK: Temporal y exposicion (M5)
    var hysteresisThreshold: Float = 0.08
    var autoLevelStrength: Float = 0.0
    var lumaSmoothAlpha: Float = 0.05
    var lumaTarget: Float = 0.5

    /// Default de spec §2. Se recalibra siempre; este orden no se asume.
    static let defaultCharset = #" .'`^",:;Il!i><~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"#

    var gridSize: SIMD2<UInt32> {
        SIMD2(outputSize.x / max(tileSize.x, 1), outputSize.y / max(tileSize.y, 1))
    }

    /// Spec §3: si no divide entero hay que avisar, no resamplear en silencio.
    var remainder: SIMD2<UInt32> {
        SIMD2(outputSize.x % max(tileSize.x, 1), outputSize.y % max(tileSize.y, 1))
    }

    var dividesEvenly: Bool { remainder == SIMD2<UInt32>(0, 0) }

    /// Resolucion valida mas cercana hacia abajo (nunca 0).
    var nearestValidWidth: UInt32 { max(tileSize.x, gridSize.x * tileSize.x) }
    var nearestValidHeight: UInt32 { max(tileSize.y, gridSize.y * tileSize.y) }
}

/// Etapas [1] .. [8] del pipeline. Encoda sobre un command buffer que le pasan;
/// no crea ni presenta drawables — eso es responsabilidad de quien lo usa
/// (preview en M2, AVAssetWriter en M6).
///
/// Todas las texturas intermedias son privadas y se reasignan solo cuando cambia
/// la configuracion. Dentro de `encode` no hay ni un `makeTexture`.
final class ASCIIPipeline {
    private let context: MetalContext

    private let lumaPSO: MTLComputePipelineState
    private let downscalePSO: MTLComputePipelineState
    private let reliefBlurHPSO: MTLComputePipelineState
    private let reliefBlurVPSO: MTLComputePipelineState
    private let spawnPSO: MTLComputePipelineState
    private let normalizePSO: MTLComputePipelineState
    private let dogHPSO: MTLComputePipelineState
    private let dogVPSO: MTLComputePipelineState
    private let sobelPSO: MTLComputePipelineState
    private let edgeQuantizePSO: MTLComputePipelineState
    private let glyphIndexPSO: MTLComputePipelineState
    private let statsPSO: MTLComputePipelineState
    private let asciiPSO: MTLComputePipelineState

    private var lumaTexture: MTLTexture
    private var gridTexture: MTLTexture
    private var heightTemp: MTLTexture
    private var heightTexture: MTLTexture
    private var spawnTexture: MTLTexture
    private var lumaRawTexture: MTLTexture
    private var dogTempTexture: MTLTexture
    private var dogTexture: MTLTexture
    private var sobelTexture: MTLTexture
    private var edgeTexture: MTLTexture
    /// Ping-pong de la histeresis: se lee el del frame anterior y se escribe el
    /// nuevo. Con una sola textura el kernel leeria lo que el mismo acaba de
    /// escribir en otra celda del mismo dispatch.
    private var glyphTextures: [MTLTexture]
    private var glyphIndex = 0

    /// Media movil de luminancia. Vive en GPU entre frames (spec §4b).
    private let lumaStatsBuffer: MTLBuffer
    /// Matte del sujeto del ultimo frame que Vision alcanzo a procesar. Puede
    /// venir con uno o dos frames de atraso; para un campo de altura eso no se
    /// nota, y el alternativo seria bloquear el render.
    var matteTexture: MTLTexture?
    /// Placeholder para cuando no hay matte: Metal exige que el binding exista
    /// aunque el kernel no lo lea.
    private let matteFallback: MTLTexture
    private(set) var outputTexture: MTLTexture
    private(set) var atlas: FontAtlas

    private(set) var config: PipelineConfig

    /// Origen del reloj del efecto Matrix. Se fija al construir el pipeline para
    /// que el tiempo no dependa de cuando arranco la app.
    private let startTime = CACurrentMediaTime()

    init(context: MetalContext, config: PipelineConfig) throws {
        self.context = context
        self.config = config

        self.lumaPSO = try ASCIIPipeline.makePSO(context, "lumaKernel")
        self.downscalePSO = try ASCIIPipeline.makePSO(context, "downscaleKernel")
        self.reliefBlurHPSO = try ASCIIPipeline.makePSO(context, "reliefBlurH")
        self.reliefBlurVPSO = try ASCIIPipeline.makePSO(context, "reliefBlurV")
        self.spawnPSO = try ASCIIPipeline.makePSO(context, "spawnKernel")
        self.normalizePSO = try ASCIIPipeline.makePSO(context, "normalizeKernel")
        self.dogHPSO = try ASCIIPipeline.makePSO(context, "dogBlurH")
        self.dogVPSO = try ASCIIPipeline.makePSO(context, "dogBlurV")
        self.sobelPSO = try ASCIIPipeline.makePSO(context, "sobelKernel")
        self.edgeQuantizePSO = try ASCIIPipeline.makePSO(context, "edgeQuantizeKernel")
        self.glyphIndexPSO = try ASCIIPipeline.makePSO(context, "glyphIndexKernel")
        self.statsPSO = try ASCIIPipeline.makePSO(context, "lumaStatsKernel")
        self.asciiPSO = try ASCIIPipeline.makePSO(context, "asciiKernel")

        let textures = try ASCIIPipeline.makeTextures(context, config)
        (lumaTexture, gridTexture, heightTemp, heightTexture, spawnTexture, outputTexture) =
            (textures.luma, textures.grid, textures.heightTemp, textures.height, textures.spawn, textures.output)
        (lumaRawTexture, dogTempTexture, dogTexture, sobelTexture, edgeTexture, glyphTextures) =
            (textures.lumaRaw, textures.dogTemp, textures.dog, textures.sobel, textures.edge, textures.glyphs)
        self.matteFallback = try ASCIIPipeline.makeFallbackMatte(context)

        var initialAverage: Float = 0.5
        guard let buffer = context.device.makeBuffer(bytes: &initialAverage,
                                                     length: MemoryLayout<Float>.stride,
                                                     options: .storageModeShared) else {
            throw AppError(.metal, "No se pudo crear el buffer de estadisticas de luma.")
        }
        buffer.label = "asciirt.lumaStats"
        self.lumaStatsBuffer = buffer
        self.atlas = try FontAtlasBuilder.build(device: context.device,
                                                font: config.font,
                                                charset: config.charset,
                                                excluded: config.excluded,
                                                cellWidth: Int(config.tileSize.x),
                                                cellHeight: Int(config.tileSize.y))
    }

    /// Reconfigura solo lo que haga falta: cambiar el tile regenera el atlas,
    /// cambiar la resolucion solo reasigna texturas.
    func update(config new: PipelineConfig) throws {
        guard new != config else { return }
        let sizeChanged = new.outputSize != config.outputSize || new.tileSize != config.tileSize
        let atlasChanged = new.tileSize != config.tileSize
            || new.font != config.font
            || new.charset != config.charset
            || new.excluded != config.excluded

        if sizeChanged {
            let textures = try ASCIIPipeline.makeTextures(context, new)
            (lumaTexture, gridTexture, heightTemp, heightTexture, spawnTexture, outputTexture) =
                (textures.luma, textures.grid, textures.heightTemp, textures.height, textures.spawn, textures.output)
            (lumaRawTexture, dogTempTexture, dogTexture, sobelTexture, edgeTexture, glyphTextures) =
                (textures.lumaRaw, textures.dogTemp, textures.dog, textures.sobel, textures.edge, textures.glyphs)
        }
        if atlasChanged {
            atlas = try FontAtlasBuilder.build(device: context.device,
                                               font: new.font,
                                               charset: new.charset,
                                               excluded: new.excluded,
                                               cellWidth: Int(new.tileSize.x),
                                               cellHeight: Int(new.tileSize.y))
        }
        config = new
    }

    func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw AppError(.metal, "No se pudo crear el compute encoder.")
        }
        encoder.label = "asciirt.ascii"

        var params = makeParams(sourceWidth: source.width, sourceHeight: source.height)
        let outputThreads = MTLSize(width: Int(config.outputSize.x),
                                    height: Int(config.outputSize.y),
                                    depth: 1)
        let gridThreads = MTLSize(width: Int(config.gridSize.x),
                                  height: Int(config.gridSize.y),
                                  depth: 1)

        // Todos los dispatches comparten el mismo bind de parametros y del
        // buffer de estadisticas; se setean una vez.
        encoder.setBytes(&params, length: MemoryLayout<RenderParams>.stride,
                         index: Int(ASCIIRTBufferIndexRenderParams.rawValue))
        encoder.setBuffer(lumaStatsBuffer, offset: 0,
                          index: Int(ASCIIRTBufferIndexLumaStats.rawValue))

        // [1] Luma cruda
        encoder.setComputePipelineState(lumaPSO)
        encoder.setTexture(source, index: Int(ASCIIRTTextureIndexSource.rawValue))
        encoder.setTexture(lumaRawTexture, index: Int(ASCIIRTTextureIndexLumaRaw.rawValue))
        encoder.dispatchThreads(outputThreads, threadsPerThreadgroup: threadgroup(for: lumaPSO))

        // [2] Normalizacion de exposicion. Consume la media del frame anterior.
        encoder.setComputePipelineState(normalizePSO)
        encoder.setTexture(lumaTexture, index: Int(ASCIIRTTextureIndexLuma.rawValue))
        encoder.dispatchThreads(outputThreads, threadsPerThreadgroup: threadgroup(for: normalizePSO))

        // [3] Downscale a grid
        encoder.setComputePipelineState(downscalePSO)
        encoder.setTexture(gridTexture, index: Int(ASCIIRTTextureIndexGrid.rawValue))
        encoder.dispatchThreads(gridThreads, threadsPerThreadgroup: threadgroup(for: downscalePSO))

        // [4][5][6] Bordes. Solo si estan activos: son las tres etapas mas caras
        // del pipeline y con el bypass puesto no aportan nada.
        if config.edgesEnabled {
            encoder.setComputePipelineState(dogHPSO)
            encoder.setTexture(dogTempTexture, index: Int(ASCIIRTTextureIndexDoGTemp.rawValue))
            encoder.dispatchThreads(outputThreads, threadsPerThreadgroup: threadgroup(for: dogHPSO))

            encoder.setComputePipelineState(dogVPSO)
            encoder.setTexture(dogTexture, index: Int(ASCIIRTTextureIndexDoG.rawValue))
            encoder.dispatchThreads(outputThreads, threadsPerThreadgroup: threadgroup(for: dogVPSO))

            encoder.setComputePipelineState(sobelPSO)
            encoder.setTexture(sobelTexture, index: Int(ASCIIRTTextureIndexSobel.rawValue))
            encoder.dispatchThreads(outputThreads, threadsPerThreadgroup: threadgroup(for: sobelPSO))

            encoder.setComputePipelineState(edgeQuantizePSO)
            encoder.setTexture(edgeTexture, index: Int(ASCIIRTTextureIndexEdge.rawValue))
            encoder.dispatchThreads(gridThreads, threadsPerThreadgroup: threadgroup(for: edgeQuantizePSO))
        }

        // Decision de glifo por tile: bordes sobre luminancia, mas histeresis.
        glyphIndex = 1 - glyphIndex
        encoder.setComputePipelineState(glyphIndexPSO)
        encoder.setTexture(edgeTexture, index: Int(ASCIIRTTextureIndexEdge.rawValue))
        encoder.setTexture(glyphTextures[1 - glyphIndex], index: Int(ASCIIRTTextureIndexGlyphPrev.rawValue))
        encoder.setTexture(glyphTextures[glyphIndex], index: Int(ASCIIRTTextureIndexGlyphNext.rawValue))
        encoder.dispatchThreads(gridThreads, threadsPerThreadgroup: threadgroup(for: glyphIndexPSO))

        // Campo de altura para el relieve. Solo cuando hace falta: con la lluvia
        // apagada son dos dispatches al pedo por frame.
        if config.matrixEnabled {
            encoder.setComputePipelineState(reliefBlurHPSO)
            encoder.setTexture(gridTexture, index: Int(ASCIIRTTextureIndexGrid.rawValue))
            encoder.setTexture(heightTemp, index: Int(ASCIIRTTextureIndexHeightTemp.rawValue))
            encoder.dispatchThreads(gridThreads, threadsPerThreadgroup: threadgroup(for: reliefBlurHPSO))

            encoder.setComputePipelineState(reliefBlurVPSO)
            encoder.setTexture(matteTexture ?? matteFallback, index: Int(ASCIIRTTextureIndexMatte.rawValue))
            encoder.setTexture(heightTexture, index: Int(ASCIIRTTextureIndexHeight.rawValue))
            encoder.dispatchThreads(gridThreads, threadsPerThreadgroup: threadgroup(for: reliefBlurVPSO))

            // Origen por columna. 1D: un hilo por columna.
            encoder.setComputePipelineState(spawnPSO)
            encoder.setTexture(spawnTexture, index: Int(ASCIIRTTextureIndexSpawn.rawValue))
            encoder.dispatchThreads(MTLSize(width: Int(config.gridSize.x), height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(
                                        width: min(spawnPSO.maxTotalThreadsPerThreadgroup, 64),
                                        height: 1, depth: 1))
        }

        // [7]+[8] ASCII + composite.
        // Un threadgroup por tile (spec §1): los 64 hilos de un tile leen la
        // misma celda del grid y celdas contiguas del atlas.
        encoder.setComputePipelineState(asciiPSO)
        encoder.setTexture(atlas.texture, index: Int(ASCIIRTTextureIndexAtlas.rawValue))
        encoder.setTexture(heightTexture, index: Int(ASCIIRTTextureIndexHeight.rawValue))
        encoder.setTexture(spawnTexture, index: Int(ASCIIRTTextureIndexSpawn.rawValue))
        encoder.setTexture(atlas.edgeTexture, index: Int(ASCIIRTTextureIndexEdgeAtlas.rawValue))
        encoder.setTexture(glyphTextures[glyphIndex], index: Int(ASCIIRTTextureIndexGlyphNext.rawValue))
        encoder.setTexture(outputTexture, index: Int(ASCIIRTTextureIndexOutput.rawValue))
        encoder.dispatchThreads(outputThreads, threadsPerThreadgroup: asciiThreadgroup())

        // Media de luminancia para el frame siguiente. Va al final: el encoder es
        // serial, asi que la etapa [2] de este frame ya leyo el valor anterior.
        encoder.setComputePipelineState(statsPSO)
        encoder.setTexture(lumaRawTexture, index: Int(ASCIIRTTextureIndexLumaRaw.rawValue))
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.endEncoding()
    }

    // MARK: - Interno

    private func makeParams(sourceWidth: Int, sourceHeight: Int) -> RenderParams {
        let outW = Float(config.outputSize.x)
        let outH = Float(config.outputSize.y)
        let srcW = Float(max(sourceWidth, 1))
        let srcH = Float(max(sourceHeight, 1))

        // Encuadre "fit": la fuente entra completa, lo que sobra queda negro.
        // Recortar seria perder imagen sin avisar, y esta app trata de no hacer
        // eso en silencio en ningun lado.
        let fit = min(outW / srcW, outH / srcH)
        let shownW = srcW * fit
        let shownH = srcH * fit
        let originX = (outW - shownW) * 0.5
        let originY = (outH - shownH) * 0.5

        // uvSrc = uvOut * scale + offset, derivado de
        // pxSrc = (pxOut - origin) / fit  y  uv = px / size.
        let scale = SIMD2<Float>(outW / shownW, outH / shownH)
        let offset = SIMD2<Float>(-originX / shownW, -originY / shownH)

        return RenderParams(outputSize: config.outputSize,
                            gridSize: config.gridSize,
                            sourceScale: scale,
                            sourceOffset: offset,
                            tileSize: config.tileSize,
                            rampLength: UInt32(atlas.rampLength),
                            matrixEnabled: config.matrixEnabled ? 1 : 0,
                            time: Float(CACurrentMediaTime() - startTime),
                            matrixSpeed: config.matrixSpeed,
                            matrixTrail: config.matrixTrail,
                            matrixChurn: config.matrixChurn,
                            matrixImageMix: config.matrixImageMix,
                            matrixRelief: config.matrixRelief,
                            reliefRadius: config.reliefRadius,
                            matteWeight: config.matteWeight,
                            matteAvailable: matteTexture != nil ? 1 : 0,
                            matrixBaseLevel: config.matrixBaseLevel,
                            matrixHeadTintEnabled: config.matrixHeadTintEnabled ? 1 : 0,
                            matrixHeadCells: config.matrixHeadCells,
                            matrixHeadColorR: config.matrixHeadColor.x,
                            matrixHeadColorG: config.matrixHeadColor.y,
                            matrixHeadColorB: config.matrixHeadColor.z,
                            matrixSpawnBias: config.matrixSpawnBias,
                            matrixSpawnStrength: config.matrixSpawnStrength,
                            matrixDensity: max(config.matrixDensity, 1),
                            edgesEnabled: config.edgesEnabled ? 1 : 0,
                            dogSigma1: config.dogSigma1,
                            dogSigma2: config.dogSigma2,
                            dogTau: config.dogTau,
                            edgeThreshold: config.edgeThreshold,
                            hysteresisThreshold: config.hysteresisThreshold,
                            autoLevelStrength: config.autoLevelStrength,
                            lumaSmoothAlpha: config.lumaSmoothAlpha,
                            lumaTarget: config.lumaTarget,
                            _pad0: 0)
    }

    /// Un threadgroup por tile (spec §1). Con celdas grandes (32x64 = 2048) se
    /// pasa del maximo de la familia Apple, asi que en ese caso se cae a un
    /// threadgroup generico. El kernel calcula la posicion dentro del tile
    /// desde `thread_position_in_grid`, asi que cualquier forma de threadgroup da
    /// el mismo resultado — esto es solo localidad de cache.
    private func asciiThreadgroup() -> MTLSize {
        let w = Int(config.tileSize.x)
        let h = Int(config.tileSize.y)
        if w * h <= asciiPSO.maxTotalThreadsPerThreadgroup {
            return MTLSize(width: w, height: h, depth: 1)
        }
        return threadgroup(for: asciiPSO)
    }

    /// Threadgroup 2D derivado del ancho de ejecucion real del kernel, en vez de
    /// un 8x8 fijo: el compilador puede reportar 32 o 64 segun el kernel.
    private func threadgroup(for pso: MTLComputePipelineState) -> MTLSize {
        let width = pso.threadExecutionWidth
        let height = max(pso.maxTotalThreadsPerThreadgroup / width, 1)
        return MTLSize(width: width, height: height, depth: 1)
    }

    private static func makePSO(_ context: MetalContext, _ name: String) throws -> MTLComputePipelineState {
        guard let function = context.library.makeFunction(name: name) else {
            throw AppError(.shaders, "Falta el kernel «\(name)» en la libreria.")
        }
        do {
            return try context.device.makeComputePipelineState(function: function)
        } catch {
            throw AppError(.metal, "No se pudo crear el pipeline de «\(name)».", underlying: error)
        }
    }

    /// Matte de 1x1 en cero. Existe solo para que el binding del kernel sea
    /// valido cuando Vision esta apagado; `matteAvailable` hace que no se lea.
    private static func makeFallbackMatte(_ context: MetalContext) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: descriptor) else {
            throw AppError(.metal, "No se pudo crear el matte placeholder.")
        }
        texture.label = "asciirt.matte.fallback"
        var zero: UInt8 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        return texture
    }

    private struct Textures {
        let luma, lumaRaw, grid: MTLTexture
        let dogTemp, dog, sobel, edge: MTLTexture
        let glyphs: [MTLTexture]
        let heightTemp, height, spawn, output: MTLTexture
    }

    private static func makeTextures(_ context: MetalContext,
                                     _ config: PipelineConfig) throws -> Textures {
        let width = Int(config.outputSize.x)
        let height = Int(config.outputSize.y)
        let grid = config.gridSize

        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = context.device.makeTexture(descriptor: descriptor) else {
                throw AppError(.metal, "No se pudo crear la textura «\(label)».")
            }
            texture.label = "asciirt.\(label)"
            return texture
        }

        // R16F y no R8: la luma alimenta el DoG de M4, donde una diferencia de
        // gaussianas sobre 8 bits se banda visiblemente.
        let luma = try make(.r16Float, width, height, "luma")
        let gridTexture = try make(.r16Float, Int(grid.x), Int(grid.y), "grid")
        // RGBA8 y no BGRA8: la escritura desde compute a bgra8Unorm no esta
        // garantizada en todas las familias; el blit al drawable corrige el orden.
        let temp = try make(.r16Float, Int(grid.x), Int(grid.y), "heightTemp")
        let heightTexture = try make(.r16Float, Int(grid.x), Int(grid.y), "height")
        // RG16F: la fila cabe exacta en half hasta 2048, muy por encima de
        // cualquier grid que salga de 4K.
        let spawn = try make(.rg16Float, Int(grid.x), 1, "spawn")
        let output = try make(.rgba8Unorm, width, height, "output")

        let lumaRaw = try make(.r16Float, width, height, "lumaRaw")
        let dogTemp = try make(.rg16Float, width, height, "dogTemp")
        let dog = try make(.r16Float, width, height, "dog")
        let sobel = try make(.rg16Float, width, height, "sobel")
        let edge = try make(.rg16Float, Int(grid.x), Int(grid.y), "edge")
        // RG8Uint: indice de glifo (hasta 255, de sobra para cualquier charset
        // razonable) y una bandera de si vino de un borde.
        let glyphs = try (0..<2).map { try make(.rg8Uint, Int(grid.x), Int(grid.y), "glyph\($0)") }

        return Textures(luma: luma, lumaRaw: lumaRaw, grid: gridTexture,
                        dogTemp: dogTemp, dog: dog, sobel: sobel, edge: edge, glyphs: glyphs,
                        heightTemp: temp, height: heightTexture, spawn: spawn, output: output)
    }
}
