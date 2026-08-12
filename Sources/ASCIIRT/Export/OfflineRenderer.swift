import AVFoundation
import CoreVideo
import Foundation
import Metal
import ShaderTypes

/// Render offline (spec §6): desacoplado del reloj de pared.
///
/// La diferencia con Live no es de velocidad sino de contrato. Live acepta
/// perder frames porque hay un reloj que respetar; aca **cada frame de entrada
/// produce exactamente un frame de salida**, se tarde lo que se tarde. Por eso:
///
/// - Los PTS se derivan del indice de frame y del fps nominal, no del tiempo que
///   trajo el sample buffer. Un archivo con timing irregular sale parejo.
/// - El command buffer se espera con `waitUntilCompleted` antes de escribir.
/// - El tiempo del efecto Matrix tambien sale del indice, asi que dos corridas
///   del mismo archivo dan el mismo resultado.
/// - Se usa un `ASCIIPipeline` propio, no el del preview: sus texturas y el
///   ping-pong de histeresis son estado, y compartirlo con el preview mezclaria
///   dos secuencias temporales distintas.
final class OfflineRenderer {

    struct Progress: Equatable {
        var framesDone = 0
        var framesTotal = 0
        var fraction: Double { framesTotal > 0 ? Double(framesDone) / Double(framesTotal) : 0 }
    }

    private let context: MetalContext
    private let queue = DispatchQueue(label: "asciirt.offline", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var cancelled = false

    init(context: MetalContext) {
        self.context = context
    }

    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled
    }

    /// Devuelve la cantidad de frames escritos, para poder compararla contra la
    /// de entrada (criterio §10).
    func render(source: URL,
                destination: URL,
                config: PipelineConfig,
                codec: ExportCodec,
                loopEffects: Bool = false,
                onProgress: @escaping (Progress) -> Void,
                onFinish: @escaping (Result<Int, AppError>) -> Void) {
        cancelLock.lock(); cancelled = false; cancelLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let written = try self.run(source: source, destination: destination,
                                           config: config, codec: codec,
                                           loopEffects: loopEffects, onProgress: onProgress)
                DispatchQueue.main.async { onFinish(.success(written)) }
            } catch let error as AppError {
                DispatchQueue.main.async { onFinish(.failure(error)) }
            } catch {
                DispatchQueue.main.async {
                    onFinish(.failure(AppError(.capture, "Falló el render offline.", underlying: error)))
                }
            }
        }
    }

    // MARK: - Interno

    private func run(source: URL,
                     destination: URL,
                     config: PipelineConfig,
                     codec: ExportCodec,
                     loopEffects: Bool,
                     onProgress: @escaping (Progress) -> Void) throws -> Int {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard let videoTrack = loadTrack(asset, .video) else {
            throw AppError(.capture, "El archivo no tiene pista de video.")
        }
        let audioTrack = loadTrack(asset, .audio)

        let naturalSize = syncLoad { try await videoTrack.load(.naturalSize) } ?? .zero
        let transform = syncLoad { try await videoTrack.load(.preferredTransform) } ?? .identity
        let nominalFPS = Double(syncLoad { try await videoTrack.load(.nominalFrameRate) } ?? 30)
        let fps = nominalFPS > 0 ? nominalFPS : 30
        let duration = syncLoad { try await asset.load(.duration) } ?? .zero

        let displaySize = naturalSize.applying(transform)
        var jobConfig = config

        // La resolucion de salida es la del PROYECTO, no la del archivo.
        //
        // Antes se pisaba siempre con el tamano natural del video, y como la
        // celda no cambia, cambiaba la grilla: un archivo de 640x360 con el
        // proyecto en 1080p exportaba 80x24 celdas donde el preview mostraba
        // 240x72. Los caracteres salian tres veces mas grandes que lo que se
        // habia estado mirando. Solo se toma el tamano del archivo cuando la
        // salida esta puesta en «Fuente», que es justamente pedir eso.
        if config.outputFollowsSource {
            jobConfig.outputSize = SIMD2(UInt32(abs(displaySize.width).rounded()),
                                         UInt32(abs(displaySize.height).rounded()))
        }

        // Periodo de loop = lo que dura el archivo. Con esto cada frecuencia del
        // efecto —la lluvia, la mutacion de glifos, el glitch— se redondea al
        // valor mas cercano que complete un numero ENTERO de ciclos dentro del
        // video, asi que el ultimo cuadro deja el efecto donde lo encuentra el
        // primero y el clip empalma consigo mismo.
        //
        // Lo que NO cierra por esto es lo que arrastra estado del material:
        // estela e histeresis vienen de los cuadros anteriores del video, y el
        // video en si no tiene por que empalmar.
        if loopEffects, duration.seconds > 0 {
            jobConfig.loopPeriod = Float(duration.seconds)
        }

        // El total es estimado: la unica cuenta exacta de frames de un archivo es
        // decodificarlo entero. Sirve para la barra, no para el criterio de
        // aceptacion — ese se verifica contra los frames realmente leidos.
        let estimatedTotal = Int((duration.seconds * fps).rounded())

        let pipeline = try ASCIIPipeline(context: context, config: jobConfig)
        let writer = VideoWriter()

        // Si el preset usa deteccion de sujeto, el export tiene que usarla
        // tambien. Aca corre sincrona: sin reloj de pared no hay razon para
        // saltear frames, y saltearlos haria que el archivo no coincida con el
        // preview.
        let matte: SubjectMatte? = jobConfig.subjectMatteEnabled
            ? SubjectMatte(device: context.device)
            : nil
        matte?.isEnabled = true

        let reader = try makeReader(asset: asset, track: videoTrack, transform: transform)
        let videoOutput = reader.outputs[0]

        // La secuencia PNG usa el pool de un writer que nunca arranca sesion:
        // se necesitan los CVPixelBuffer para que la GPU escriba adentro, pero
        // no hay pista que escribir.
        let sequence: ImageSequenceWriter?
        if codec.isImageSequence {
            let folder = destination.deletingPathExtension()
            let seq = ImageSequenceWriter(folder: folder,
                                          basename: folder.lastPathComponent)
            try seq.prepare()
            sequence = seq
            try writer.startPixelBufferPoolOnly(size: jobConfig.outputSize)
        } else {
            sequence = nil
            try writer.start(url: destination,
                             size: jobConfig.outputSize,
                             codec: codec,
                             fps: fps,
                             realTime: false,
                             audioFormat: audioTrack.flatMap(formatDescription(of:)))
        }

        guard reader.startReading() else {
            throw AppError(.capture, "No se pudo leer el archivo.",
                           detail: reader.error?.localizedDescription)
        }

        // El audio va en su propio hilo con su propio lector: un AVAssetReader no
        // se puede rebobinar, y entrelazar las dos pistas desde un solo lector
        // obligaria a bufferear una de las dos entera. Una secuencia de imagenes
        // no lleva audio.
        let audioWork = sequence == nil ? audioTrack.map { track in
            startAudioPassthrough(asset: asset, track: track, writer: writer)
        } : nil

        var frameIndex = 0
        var blitState: MTLRenderPipelineState?

        while let sample = videoOutput.copyNextSampleBuffer() {
            if isCancelled { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            guard let target = writer.dequeuePixelBuffer() else {
                throw AppError(.capture, "El pool de buffers de salida se agotó.")
            }

            let (sourceTexture, sourceKeepAlive) = try context.makeTexture(from: pixelBuffer)
            let (targetTexture, targetKeepAlive) = try context.makeTexture(from: target)

            if blitState == nil { blitState = try makeBlitState() }

            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                throw AppError(.metal, "No se pudo crear el command buffer offline.")
            }

            pipeline.matteTexture = matte?.process(pixelBuffer)

            // Tiempo del efecto derivado del indice: reproducible entre corridas.
            pipeline.timeOverride = Float(Double(frameIndex) / fps)
            // dt fijo del fps nominal: el render tiene que ser reproducible, no
            // depender de cuanto tardo la GPU en cada cuadro.
            try pipeline.encode(commandBuffer: commandBuffer, source: sourceTexture,
                                deltaTime: Float(1.0 / fps))

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = targetTexture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
                  let blitState else {
                throw AppError(.metal, "No se pudo crear el encoder de salida offline.")
            }
            encoder.setRenderPipelineState(blitState)
            encoder.setFragmentTexture(pipeline.outputTexture,
                                       index: Int(ASCIIRTTextureIndexSource.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            // Sincrono: sin esto el buffer se apendaria antes de que la GPU haya
            // terminado de escribirlo.
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            _ = sourceKeepAlive
            _ = targetKeepAlive

            if let sequence {
                try sequence.write(target, index: frameIndex,
                                   withAlpha: jobConfig.transparentBackground)
            } else {
                // PTS exacto = indice / fps (spec §6), no el timestamp del sample.
                let presentation = CMTime(value: CMTimeValue(frameIndex),
                                          timescale: CMTimeScale(fps.rounded()))
                guard writer.appendSynchronously(target, at: presentation) else {
                    if writer.stallDetected {
                        throw AppError(.capture,
                                       "El escritor dejó de aceptar frames en el \(frameIndex).",
                                       detail: "Se esperó treinta segundos sin que el codificador tomara un frame más. "
                                             + "Probá con otro formato de salida.")
                    }
                    throw AppError(.capture, "El escritor rechazó el frame \(frameIndex).",
                                   detail: writer.writerError?.localizedDescription)
                }
            }

            frameIndex += 1
            let progress = Progress(framesDone: frameIndex, framesTotal: max(estimatedTotal, frameIndex))
            DispatchQueue.main.async { onProgress(progress) }
        }

        audioWork?.wait()
        reader.cancelReading()

        if isCancelled {
            _ = await_finish(writer)
            try? FileManager.default.removeItem(at: sequence?.folder ?? destination)
            throw AppError(.capture, "Render cancelado.")
        }

        if sequence != nil {
            writer.stopPixelBufferPoolOnly()
            return frameIndex
        }

        switch await_finish(writer) {
        case .success:
            return frameIndex
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Loop

    /// Render de un loop de duracion fija para las fuentes generativas.
    ///
    /// Dos cosas lo separan del render de archivo, y las dos son lo que hace que
    /// el clip empalme consigo mismo:
    ///
    /// 1. **Periodo.** `config.loopPeriod` hace que toda frecuencia temporal se
    ///    redondee para que entre un numero entero de ciclos. Sin esto cada
    ///    oscilacion queda cortada en una fase cualquiera y el corte salta.
    ///
    /// 2. **Vuelta de precalentamiento.** Se renderizan DOS periodos y se escribe
    ///    solo el segundo. La estela, la histeresis y el resorte del ojo son
    ///    estado: al empezar de cero el primer periodo arranca con la pantalla
    ///    limpia y el ojo quieto, y eso no se parece a como esta el sistema al
    ///    llegar al final. Descartando la primera vuelta, el cuadro inicial del
    ///    clip tiene atras exactamente la misma historia que el ultimo.
    func renderLoop(destination: URL,
                    config: PipelineConfig,
                    codec: ExportCodec,
                    duration: Double,
                    fps: Double,
                    onProgress: @escaping (Progress) -> Void,
                    onFinish: @escaping (Result<Int, AppError>) -> Void) {
        cancelLock.lock(); cancelled = false; cancelLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let written = try self.runLoop(destination: destination, config: config,
                                               codec: codec, duration: duration, fps: fps,
                                               onProgress: onProgress)
                DispatchQueue.main.async { onFinish(.success(written)) }
            } catch let error as AppError {
                DispatchQueue.main.async { onFinish(.failure(error)) }
            } catch {
                DispatchQueue.main.async {
                    onFinish(.failure(AppError(.capture, "Falló el render del loop.", underlying: error)))
                }
            }
        }
    }

    private func runLoop(destination: URL,
                         config: PipelineConfig,
                         codec: ExportCodec,
                         duration: Double,
                         fps: Double,
                         onProgress: @escaping (Progress) -> Void) throws -> Int {
        // El periodo se mide en CUADROS y de ahi se deriva en segundos. Si se
        // tomara la duracion pedida tal cual, con un fps que no la divide entero
        // el ultimo cuadro caeria fuera del periodo y el empalme fallaria por una
        // fraccion de cuadro.
        let periodFrames = max(Int((duration * fps).rounded()), 1)
        let period = Double(periodFrames) / fps

        var jobConfig = config
        jobConfig.loopPeriod = Float(period)

        let pipeline = try ASCIIPipeline(context: context, config: jobConfig)
        let writer = VideoWriter()

        let sequence: ImageSequenceWriter?
        if codec.isImageSequence {
            let folder = destination.deletingPathExtension()
            let seq = ImageSequenceWriter(folder: folder, basename: folder.lastPathComponent)
            try seq.prepare()
            sequence = seq
            try writer.startPixelBufferPoolOnly(size: jobConfig.outputSize)
        } else {
            sequence = nil
            try writer.start(url: destination, size: jobConfig.outputSize,
                             codec: codec, fps: fps, realTime: false)
        }

        var blitState: MTLRenderPipelineState?
        var written = 0

        // Dos vueltas: la primera solo deja el estado como corresponde.
        for index in 0..<(periodFrames * 2) {
            if isCancelled { break }
            let keep = index >= periodFrames

            guard let target = writer.dequeuePixelBuffer() else {
                throw AppError(.capture, "El pool de buffers de salida se agotó.")
            }
            let (targetTexture, targetKeepAlive) = try context.makeTexture(from: target)
            if blitState == nil { blitState = try makeBlitState() }

            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                throw AppError(.metal, "No se pudo crear el command buffer del loop.")
            }

            // El tiempo se envuelve en el periodo: lo que ve el cuadro 0 de la
            // segunda vuelta es identico a lo que veria el cuadro que sigue al
            // ultimo, que es justamente la definicion de que el clip cierre.
            pipeline.timeOverride = Float(Double(index % periodFrames) / fps)
            try pipeline.encode(commandBuffer: commandBuffer, source: nil,
                                deltaTime: Float(1.0 / fps))

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = targetTexture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
                  let blitState else {
                throw AppError(.metal, "No se pudo crear el encoder de salida del loop.")
            }
            encoder.setRenderPipelineState(blitState)
            encoder.setFragmentTexture(pipeline.outputTexture,
                                       index: Int(ASCIIRTTextureIndexSource.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            _ = targetKeepAlive

            if keep {
                if let sequence {
                    try sequence.write(target, index: written,
                                       withAlpha: jobConfig.transparentBackground)
                } else {
                    let presentation = CMTime(value: CMTimeValue(written),
                                              timescale: CMTimeScale(fps.rounded()))
                    guard writer.appendSynchronously(target, at: presentation) else {
                        throw AppError(.capture, "El escritor rechazó el frame \(written).")
                    }
                }
                written += 1
            }

            let progress = Progress(framesDone: index + 1, framesTotal: periodFrames * 2)
            DispatchQueue.main.async { onProgress(progress) }
        }

        if isCancelled {
            _ = await_finish(writer)
            try? FileManager.default.removeItem(at: sequence?.folder ?? destination)
            throw AppError(.capture, "Loop cancelado.")
        }

        if sequence != nil {
            writer.stopPixelBufferPoolOnly()
            return written
        }

        switch await_finish(writer) {
        case .success: return written
        case .failure(let error): throw error
        }
    }

    /// Puente sincrono al `finish()` async del writer: este metodo ya corre en
    /// su propia cola, y hacerlo async contagiaria de concurrencia a todo el
    /// bucle por un solo await.
    private func await_finish(_ writer: VideoWriter) -> Result<URL, AppError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, AppError> = .failure(AppError(.capture, "sin resultado"))
        Task {
            result = await writer.finish()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func startAudioPassthrough(asset: AVAsset,
                                       track: AVAssetTrack,
                                       writer: VideoWriter) -> DispatchWorkItem {
        let work = DispatchWorkItem {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }

            while let sample = output.copyNextSampleBuffer() {
                if self.isCancelled { break }
                writer.appendAudio(sample)
            }
            reader.cancelReading()

            // Avisar que la pista termino, SIEMPRE y apenas termina.
            //
            // AVAssetWriter entrelaza las pistas: mientras crea que todavia
            // puede llegar audio, no da por listo el input de video pasado el
            // ultimo audio que recibio. El audio casi siempre termina antes que
            // el video, asi que sin esta linea el render se colgaba a pocos
            // frames del final, esperando para siempre un audio que ya no
            // existia.
            writer.markAudioFinished()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
        return work
    }

    private func makeReader(asset: AVAsset,
                            track: AVAssetTrack,
                            transform: CGAffineTransform) throws -> AVAssetReader {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AppError(.capture, "No se pudo abrir el archivo para lectura.", underlying: error)
        }

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        // Con rotacion se lee por composicion para que el transform se aplique
        // antes de que el frame llegue al pipeline, igual que en el preview.
        let composition: AVVideoComposition? = transform.isIdentity
            ? nil
            : syncLoad { try await AVVideoComposition.videoComposition(withPropertiesOf: asset) }

        if let composition {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
            output.videoComposition = composition
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw AppError(.capture, "El lector rechazó la composición de video.")
            }
            reader.add(output)
        } else {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw AppError(.capture, "El lector rechazó la pista de video.")
            }
            reader.add(output)
        }
        return reader
    }

    private func makeBlitState() throws -> MTLRenderPipelineState {
        guard let vertexFn = context.library.makeFunction(name: "blitVertex"),
              let fragmentFn = context.library.makeFunction(name: "blitFragment") else {
            throw AppError(.shaders, "Faltan blitVertex/blitFragment.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "asciirt.offline.blit"
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try context.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw AppError(.metal, "No se pudo crear el pipeline de salida offline.", underlying: error)
        }
    }

    // MARK: - Carga sincrona de propiedades

    /// El bucle offline no es async a proposito: convertirlo contagiaria de
    /// concurrencia a todo el render por unas pocas propiedades que se leen una
    /// vez al principio. Estos helpers hacen el puente con la API moderna de
    /// AVFoundation sin pagar ese precio.
    private func syncLoad<T>(_ operation: @escaping () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = try? await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func loadTrack(_ asset: AVAsset, _ type: AVMediaType) -> AVAssetTrack? {
        syncLoad { try await asset.loadTracks(withMediaType: type).first } ?? nil
    }

    private func formatDescription(of track: AVAssetTrack) -> CMFormatDescription? {
        syncLoad { try await track.load(.formatDescriptions).first } ?? nil
    }
}
