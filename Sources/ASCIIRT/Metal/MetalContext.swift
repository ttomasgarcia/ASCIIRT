import Metal
import MetalKit
import CoreVideo

/// Estado de GPU de larga vida: device, cola, cache de texturas de CoreVideo y
/// la libreria de shaders. Se crea una vez y se comparte; nada de esto se
/// reconstruye por frame.
final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    /// Cache de CVMetalTexture. Es lo que hace que importar un CVPixelBuffer sea
    /// zero-copy (spec §1, etapa [0]): el IOSurface del buffer se envuelve como
    /// MTLTexture sin copiar bytes.
    let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw AppError(.metal, "No hay dispositivo Metal disponible.")
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw AppError(.metal, "No se pudo crear el MTLCommandQueue.")
        }
        queue.label = "asciirt.render"
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw AppError(.metal, "CVMetalTextureCacheCreate fallo.", detail: "CVReturn \(status)")
        }
        self.textureCache = cache

        self.library = try ShaderLibrary.makeLibrary(device: device)
    }

    /// Suelta las texturas del cache que ya nadie usa.
    ///
    /// `CVMetalTextureCache` no libera nada por su cuenta: acumula las texturas
    /// que fue creando hasta que se le pide que las revise. Sin esta llamada la
    /// memoria sube sostenido mientras corre un video —medido, unos 15 MB por
    /// minuto con material 1080p— y con un archivo en loop eso no para nunca.
    ///
    /// Va DESPUES de que el command buffer termino: el cache solo suelta lo que
    /// no tiene referencias vivas, asi que llamarlo antes no libera nada.
    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Envuelve un CVPixelBuffer BGRA como MTLTexture sin copiar.
    ///
    /// El CVMetalTexture devuelto tiene que seguir vivo mientras el command
    /// buffer que usa la textura no haya terminado; por eso lo devolvemos junto
    /// con la MTLTexture en vez de descartarlo.
    func makeTexture(from pixelBuffer: CVPixelBuffer,
                     pixelFormat: MTLPixelFormat = .bgra8Unorm) throws -> (texture: MTLTexture, keepAlive: CVMetalTexture) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            pixelFormat, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw AppError(.metal, "No se pudo importar el frame como textura.", detail: "CVReturn \(status)")
        }
        return (texture, cvTexture)
    }
}
