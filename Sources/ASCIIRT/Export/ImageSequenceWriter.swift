import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Secuencia PNG numerada (spec §7): máxima calidad, para llevar a post.
///
/// Es el único destino donde el frame sí vuelve a CPU, y no hay forma de evitarlo:
/// PNG es compresión sin pérdida sobre bytes, no un codec de video con ruta de
/// hardware. Por eso vive únicamente en el camino offline, donde no hay reloj
/// que respetar.
struct ImageSequenceWriter {

    let folder: URL
    let basename: String
    /// Numeración `%05d` como pide la spec: cinco dígitos aguantan 27 horas a
    /// 30 fps y ordenan bien alfabéticamente en cualquier herramienta.
    private let digits = 5

    init(folder: URL, basename: String) {
        self.folder = folder
        self.basename = basename
    }

    func prepare() throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AppError(.capture, "No se pudo crear la carpeta de salida.", underlying: error)
        }
    }

    func write(_ pixelBuffer: CVPixelBuffer, index: Int, withAlpha: Bool) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw AppError(.capture, "El frame \(index) no expuso su buffer.")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // El pipeline escribe alpha premultiplicado; declararlo mal haría que
        // los bordes antialiaseados del glifo salgan con halo.
        let alphaInfo: CGImageAlphaInfo = withAlpha ? .premultipliedFirst : .noneSkipFirst
        let bitmapInfo = alphaInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo),
              let image = context.makeImage() else {
            throw AppError(.capture, "No se pudo convertir el frame \(index) a imagen.")
        }

        let name = String(format: "%@.%0\(digits)d.png", basename, index)
        let url = folder.appendingPathComponent(name)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError(.capture, "No se pudo crear «\(name)».")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AppError(.capture, "Falló la escritura de «\(name)».")
        }
    }
}
