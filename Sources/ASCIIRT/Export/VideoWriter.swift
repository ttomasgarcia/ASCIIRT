import AVFoundation
import CoreVideo
import VideoToolbox
import Foundation
import Metal
import QuartzCore

/// Formatos de salida (spec §7).
enum ExportCodec: String, CaseIterable, Identifiable, Codable {
    case proRes422HQ = "ProRes 422 HQ"
    case proRes4444 = "ProRes 4444"
    case hevcAlpha = "HEVC con alfa"
    case h264 = "H.264"
    case pngSequence = "Secuencia PNG"

    var id: String { rawValue }

    /// La secuencia no pasa por AVAssetWriter: es un destino distinto, no otro
    /// codec, y solo existe en el camino offline.
    var isImageSequence: Bool { self == .pngSequence }

    var avCodec: AVVideoCodecType {
        switch self {
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        case .hevcAlpha: return .hevcWithAlpha
        case .h264: return .h264
        case .pngSequence: return .proRes4444   // nunca se usa; ver isImageSequence
        }
    }

    /// ProRes 4444 es el unico que lleva alpha; los demas aplastan contra negro.
    /// ProRes 4444 y la secuencia PNG guardan alfa sin comprimir; HEVC con alfa
    /// lo guarda en una capa auxiliar del mismo archivo y pesa un orden de
    /// magnitud menos. Es lo mas parecido a un WebM con alfa que existe nativo en
    /// macOS — WebM necesitaria un encoder VP9 que el sistema no trae.
    var supportsAlpha: Bool { self == .proRes4444 || self == .pngSequence || self == .hevcAlpha }

    var fileExtension: String {
        switch self {
        case .h264: return "mp4"
        case .pngSequence: return "png"
        default: return "mov"
        }
    }

    var fileType: AVFileType { self == .h264 ? .mp4 : .mov }

    /// Spec §7: ASCII es el peor caso posible para un codec de transformada.
    /// Bordes de altisima frecuencia y contraste extremo producen ringing y
    /// mosquito noise que se come los glifos finos. Por eso el bitrate sugerido
    /// es ~3x el de material normal.
    func suggestedBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = Double(width * height)
        let normal = pixels * max(fps, 1) * 0.10   // ~0.1 bits por pixel por frame
        return Int(normal * 3.0)
    }
}

/// Escritura a disco del resultado del pipeline.
///
/// El frame nunca vuelve a CPU: se pide un CVPixelBuffer del pool del adaptor,
/// se envuelve como MTLTexture con el mismo cache que usa la importacion, y el
/// render escribe directo ahi. Lo unico que cruza es el append, que recibe un
/// buffer que ya esta lleno.
final class VideoWriter {

    struct Stats: Equatable {
        var framesWritten = 0
        /// Frames que llegaron con el input no listo. En Live es aceptable
        /// (spec §6) pero tiene que verse.
        var framesDropped = 0
        var duration: Double = 0
    }

    private(set) var stats = Stats()
    private(set) var url: URL?
    private(set) var isRecording = false

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    /// Origen del reloj en modo Live y ultimo PTS escrito, para garantizar que
    /// la secuencia sea estrictamente creciente.
    private var sessionStartSeconds: Double?
    private var lastPresentation: CMTime = .invalid
    private var realTime = false
    private var standalonePool: CVPixelBufferPool?

    /// Los append van serializados en su propia cola: llegan desde los
    /// completion handlers de Metal, que corren en hilos internos del driver.
    private let queue = DispatchQueue(label: "asciirt.writer")

    var onStats: ((Stats) -> Void)?
    var onError: ((AppError) -> Void)?
    private var reportedFailure = false

    // MARK: - Ciclo de vida

    func start(url: URL,
               size: SIMD2<UInt32>,
               codec: ExportCodec,
               fps: Double,
               realTime: Bool,
               audioFormat: CMFormatDescription? = nil) throws {
        guard !isRecording else { return }

        // Un archivo previo con el mismo nombre hace fallar a AVAssetWriter con
        // un error que no dice eso.
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
        } catch {
            throw AppError(.capture, "No se pudo crear el archivo de salida.", underlying: error)
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.x),
            AVVideoHeightKey: Int(size.y)
        ]
        if codec == .hevcAlpha {
            settings[AVVideoCompressionPropertiesKey] = [
                // El pipeline escribe alfa PREMULTIPLICADO —lo dice la etapa de
                // composicion— asi que hay que declararlo: con el modo por
                // defecto los bordes antialiaseados de los glifos salen con halo.
                kVTCompressionPropertyKey_AlphaChannelMode as String:
                    kVTAlphaChannelMode_PremultipliedAlpha as String,
                AVVideoAverageBitRateKey: codec.suggestedBitrate(width: Int(size.x),
                                                                 height: Int(size.y),
                                                                 fps: fps)
            ]
        }
        if codec == .h264 {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: codec.suggestedBitrate(width: Int(size.x),
                                                                 height: Int(size.y),
                                                                 fps: fps),
                // Sin B-frames: el ringing sobre bordes duros se propaga peor
                // cuando el frame se predice desde los dos lados.
                AVVideoAllowFrameReorderingKey: false
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // En Live hay que aceptar perder frames antes que frenar la captura; en
        // offline es al reves y por eso el flag viene de afuera.
        input.expectsMediaDataInRealTime = realTime

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: codec.supportsAlpha
                ? kCVPixelFormatType_32BGRA
                : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.x),
            kCVPixelBufferHeightKey as String: Int(size.y),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                          sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else {
            throw AppError(.capture, "El escritor rechazó la pista de video.",
                           detail: "\(codec.rawValue) a \(size.x)×\(size.y)")
        }
        writer.add(input)

        // Audio sin recodificar (spec §7): outputSettings nil es passthrough.
        if let audioFormat {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: audioFormat)
            audio.expectsMediaDataInRealTime = realTime
            if writer.canAdd(audio) {
                writer.add(audio)
                self.audioInput = audio
            }
        }

        guard writer.startWriting() else {
            throw AppError(.capture, "No se pudo iniciar la escritura.",
                           underlying: writer.error ?? AppError(.capture, "sin detalle"))
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.url = url
        self.sessionStart = nil
        self.stats = Stats()
        self.sessionStartSeconds = nil
        self.lastPresentation = .invalid
        self.realTime = realTime
        self.reportedFailure = false
        self.isRecording = true
    }

    /// Pool de buffers sin pista de salida, para la secuencia de imagenes: la
    /// GPU necesita CVPixelBuffer donde escribir, pero no hay nada que multiplexar.
    func startPixelBufferPoolOnly(size: SIMD2<UInt32>) throws {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.x),
            kCVPixelBufferHeightKey as String: Int(size.y),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            throw AppError(.metal, "No se pudo crear el pool de buffers de salida.")
        }
        standalonePool = pool
        stats = Stats()
        isRecording = true
    }

    func stopPixelBufferPoolOnly() {
        standalonePool = nil
        isRecording = false
    }

    /// Buffer del pool listo para que el render escriba adentro.
    func dequeuePixelBuffer() -> CVPixelBuffer? {
        if let standalonePool {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, standalonePool, &buffer) == kCVReturnSuccess else {
                return nil
            }
            return buffer
        }
        guard isRecording, let pool = adaptor?.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            // El pool vacio significa que el codificador todavia tiene todos los
            // buffers. El frame no se graba, y antes eso no se contaba en ningun
            // lado: el archivo salia con un frenado y los contadores decian que
            // no se habia perdido nada. Ahora suma a perdidos.
            queue.async { self.stats.framesDropped += 1 }
            publish()
            return nil
        }
        return buffer
    }

    /// Version bloqueante para el modo offline: espera a que el input este
    /// listo en vez de descartar. Ahi no hay reloj de pared que respetar y la
    /// exigencia es que entren TODOS los frames (spec §6).
    @discardableResult
    func appendSynchronously(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard isRecording, let input, let adaptor else { return false }
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let ok = adaptor.append(buffer, withPresentationTime: time)
        queue.sync {
            if ok {
                self.stats.framesWritten += 1
                self.stats.duration = time.seconds
            } else {
                self.stats.framesDropped += 1
            }
        }
        publish()
        return ok
    }

    /// Audio tal cual viene del archivo, sin decodificar ni recodificar.
    @discardableResult
    func appendAudio(_ sample: CMSampleBuffer) -> Bool {
        guard let audioInput else { return false }
        while !audioInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        return audioInput.append(sample)
    }

    var hasAudioInput: Bool { audioInput != nil }

    func markAudioFinished() { audioInput?.markAsFinished() }

    /// Se llama desde el completion handler del command buffer, con el frame ya
    /// renderizado adentro.
    ///
    /// En Live el PTS sale del reloj de pared al momento de dibujar, NO del
    /// timestamp de la fuente. Motivo: con el modo Matrix el preview repinta a
    /// 60 Hz aunque la camara entregue a 30, asi que dos frames dibujados
    /// comparten el timestamp de la fuente. `AVAssetWriter` exige PTS
    /// estrictamente crecientes y rechaza el segundo — que era el error de
    /// escritura. Con reloj de pared, ademas, el archivo queda con exactamente
    /// lo que se vio, incluida la lluvia animando sobre un frame congelado.
    func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        let hostSeconds = CACurrentMediaTime()

        queue.async { [weak self] in
            guard let self, self.isRecording,
                  let input = self.input, let adaptor = self.adaptor else { return }

            let presentation: CMTime
            if self.realTime {
                if self.sessionStartSeconds == nil { self.sessionStartSeconds = hostSeconds }
                let elapsed = hostSeconds - (self.sessionStartSeconds ?? hostSeconds)
                presentation = CMTime(seconds: max(elapsed, 0), preferredTimescale: 600)
            } else {
                if self.sessionStart == nil { self.sessionStart = time }
                presentation = CMTimeSubtract(time, self.sessionStart ?? .zero)
            }

            // Cinturon de seguridad: si por jitter del reloj dos frames caen en
            // el mismo tick de 1/600 s, este se descarta en vez de hacer fallar
            // la escritura entera.
            if self.lastPresentation.isValid,
               CMTimeCompare(presentation, self.lastPresentation) <= 0 {
                self.stats.framesDropped += 1
                self.publish()
                return
            }

            guard input.isReadyForMoreMediaData else {
                self.stats.framesDropped += 1
                self.publish()
                return
            }
            if adaptor.append(buffer, withPresentationTime: presentation) {
                self.lastPresentation = presentation
                self.stats.framesWritten += 1
                self.stats.duration = presentation.seconds
            } else {
                self.stats.framesDropped += 1
                // El error del writer es lo unico que explica por que fallo;
                // sin esto el usuario ve un contador subir y nada mas.
                if let failure = self.writer?.error {
                    self.reportOnce(AppError(.capture, "El escritor rechazó un frame.",
                                             underlying: failure))
                }
            }
            self.publish()
        }
    }

    func finish() async -> Result<URL, AppError> {
        publish(force: true)
        guard isRecording, let writer, let input else {
            return .failure(AppError(.capture, "No hay grabación en curso."))
        }
        isRecording = false

        // Drenar la cola de appends antes de cerrar, o los ultimos frames se
        // pierden en silencio.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }

        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        let output = url
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        self.audioInput = nil
        self.url = nil

        if writer.status == .completed, let output {
            return .success(output)
        }
        return .failure(AppError(.capture, "La escritura no se completó.",
                                 detail: writer.error?.localizedDescription))
    }

    /// Un fallo de escritura se repite en cada frame; alcanza con verlo una vez.
    private func reportOnce(_ error: AppError) {
        guard !reportedFailure else { return }
        reportedFailure = true
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    /// Ultima vez que se publicaron los contadores a la UI.
    private var lastPublish: CFTimeInterval = 0

    /// Publica los contadores, como mucho cuatro veces por segundo.
    ///
    /// Antes se publicaba en CADA frame escrito. `recordStats` esta publicado en
    /// el modelo, asi que eso reconstruia el panel entero —cien filas de
    /// controles con sus ayudas— treinta veces por segundo, en el main thread,
    /// que es el mismo hilo donde corre el render. De ahi el tironeo al grabar y
    /// que el archivo saliera con frenadas: los frames se dibujaban tarde.
    ///
    /// El renderer ya throttleaba sus propios contadores a 2 Hz por esta misma
    /// razon; al escritor le habia faltado.
    ///
    /// `force` es para el arranque y el cierre, donde el numero final importa
    /// mas que el ritmo.
    private func publish(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastPublish >= 0.25 else { return }
        lastPublish = now
        let snapshot = stats
        DispatchQueue.main.async { [weak self] in self?.onStats?(snapshot) }
    }
}
