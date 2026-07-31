import CoreVideo
import Foundation
import Metal
import Vision

/// Matte de sujeto por Vision, para alimentar el campo de altura del relieve.
///
/// Por que esto y no profundidad real: `VNGeneratePersonSegmentationRequest`
/// corre en la Neural Engine, esta pensado para video, y en `.balanced` cuesta
/// unos pocos milisegundos por frame. No da profundidad metrica — da figura
/// contra fondo — pero para que la lluvia encuentre volumen esa separacion hace
/// mas que cualquier gradiente de luminancia. Y no hay modelo que distribuir.
///
/// Corre desacoplado del render: si hay un pedido en vuelo, el frame nuevo se
/// descarta. El matte puede llegar con uno o dos frames de atraso; para un campo
/// de altura eso no se percibe, y la alternativa seria frenar el pipeline.
final class SubjectMatte {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "asciirt.matte", qos: .userInitiated)
    private let request: VNGeneratePersonSegmentationRequest

    private let lock = NSLock()
    private var inFlight = false
    private var latestTexture: MTLTexture?

    /// Anillo de texturas en vez de una sola: la CPU escribe el matte nuevo
    /// mientras la GPU todavia puede estar leyendo el anterior. Con tres, a la
    /// velocidad a la que Vision produce, nunca se alcanzan.
    private var ring: [MTLTexture] = []
    private var ringIndex = 0
    private var ringSize = CGSize.zero

    var isEnabled = false {
        didSet {
            guard !isEnabled else { return }
            lock.lock(); latestTexture = nil; lock.unlock()
        }
    }

    var onError: ((AppError) -> Void)?

    init(device: MTLDevice) {
        self.device = device
        self.request = VNGeneratePersonSegmentationRequest()
        // `.balanced` y no `.accurate`: accurate devuelve el matte a resolucion
        // completa y multiplica el costo, y el campo de altura se consume a
        // resolucion de grid igual.
        self.request.qualityLevel = .balanced
        self.request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Textura del ultimo matte disponible, o nil si todavia no hay ninguno.
    var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latestTexture
    }

    func submit(_ pixelBuffer: CVPixelBuffer) {
        guard isEnabled else { return }

        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock(); self.inFlight = false; self.lock.unlock()
            }
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                try handler.perform([self.request])
                guard let mask = self.request.results?.first?.pixelBuffer else { return }
                let texture = try self.upload(mask)
                self.lock.lock(); self.latestTexture = texture; self.lock.unlock()
            } catch {
                DispatchQueue.main.async {
                    self.onError?(AppError(.capture, "Vision no pudo segmentar el sujeto.", underlying: error))
                }
            }
        }
    }

    /// Se copia en vez de envolver el buffer con CVMetalTextureCache: el buffer
    /// que devuelve Vision no siempre viene respaldado por IOSurface, y sin eso
    /// el zero-copy falla. El matte es chico, la copia es barata.
    private func upload(_ mask: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)

        let texture = try textureFromRing(width: width, height: height)

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else {
            throw AppError(.capture, "El matte de Vision no expuso su buffer.")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(mask))
        return texture
    }

    private func textureFromRing(width: Int, height: Int) throws -> MTLTexture {
        let size = CGSize(width: width, height: height)
        if ring.isEmpty || size != ringSize {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            ring = try (0..<3).map { index in
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw AppError(.metal, "No se pudo crear la textura del matte.")
                }
                texture.label = "asciirt.matte.\(index)"
                return texture
            }
            ringSize = size
            ringIndex = 0
        }
        let texture = ring[ringIndex]
        ringIndex = (ringIndex + 1) % ring.count
        return texture
    }
}
