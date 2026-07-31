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
                onProgress: @escaping (Progress) -> Void,
                onFinish: @escaping (Result<Int, AppError>) -> Void) {
        cancelLock.lock(); cancelled = false; cancelLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let written = try self.run(source: source, destination: destination,
                                           config: config, codec: codec, onProgress: onProgress)
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
        jobConfig.outputSize = SIMD2(UInt32(abs(displaySize.width).rounded()),
                                     UInt32(abs(displaySize.height).rounded()))

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
            try pipeline.encode(commandBuffer: commandBuffer, source: sourceTexture)

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
                    throw AppError(.capture, "El escritor rechazó el frame \(frameIndex).")
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
