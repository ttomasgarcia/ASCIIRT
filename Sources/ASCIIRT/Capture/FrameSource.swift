import CoreMedia
import CoreVideo

/// Descripcion del material que entra al pipeline, venga de camara o de archivo.
struct FormatDescription: Equatable {
    let width: Int
    let height: Int
    let fps: Double

    var pretty: String { "\(width)×\(height) @ \(String(format: "%.4g", fps)) fps" }
}

protocol FrameSourceDelegate: AnyObject {
    /// Puede llegar en cualquier cola. No debe tocar estado publicado.
    func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime)
    func frameSource(_ source: FrameSource, didChangeFormat description: FormatDescription)
    func frameSource(_ source: FrameSource, didFail error: AppError)
}

/// Lo unico que el resto de la app necesita saber de una fuente: entrega
/// CVPixelBuffer BGRA y se puede apagar.
///
/// La abstraccion existe desde ahora y no despues porque el modo offline (spec
/// §6) tiene que poder reemplazar la fuente sin tocar el pipeline.
protocol FrameSource: AnyObject {
    var delegate: FrameSourceDelegate? { get set }
    func stop()
}
