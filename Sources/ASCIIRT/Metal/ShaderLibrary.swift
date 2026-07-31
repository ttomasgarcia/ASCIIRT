import Foundation
import Metal

/// Compila los .metal del bundle en una unica MTLLibrary, en runtime.
///
/// Por que en runtime y no un .metallib precompilado: esta maquina tiene solo
/// Command Line Tools instaladas, sin Xcode, y por lo tanto sin las utilidades
/// `metal`/`metallib`. El compilador MSL que trae el framework de Metal si esta
/// disponible, asi que `makeLibrary(source:)` funciona. El costo es ~decenas de
/// ms una sola vez al arrancar. Si en algun momento hay Xcode, reemplazar
/// `makeLibrary(source:)` por `device.makeDefaultLibrary()` y compilar los mismos
/// archivos en build time: la organizacion en disco no cambia.
enum ShaderLibrary {

    /// Nombre de la carpeta dentro de Contents/Resources donde `Scripts/build.sh`
    /// deja RenderParams.h y los .metal.
    static let resourceFolder = "Shaders"

    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let folder = try locateShaderFolder()
        let source = try assembleSource(from: folder)

        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        // Fast math: el pipeline es todo aproximacion perceptual, no hay nada que
        // dependa de NaN/inf ni de precision estricta de IEEE.
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }

        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            // El mensaje del compilador MSL trae archivo:linea, pero de la fuente
            // concatenada. Se adjunta tal cual: es mas util que nada, y la
            // concatenacion respeta el orden alfabetico de los archivos.
            throw AppError(.shaders, "El compilador de Metal rechazo los shaders.", underlying: error)
        }
    }

    /// Concatena el header compartido + cada .metal en orden alfabetico.
    ///
    /// Los .metal no hacen #include de RenderParams.h justamente porque el header
    /// entra por aca; el prefijo numerico de los archivos (00_, 01_, ...) fija el
    /// orden y refleja la etapa del pipeline.
    private static func assembleSource(from folder: URL) throws -> String {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)

        guard let header = entries.first(where: { $0.lastPathComponent == "RenderParams.h" }) else {
            throw AppError(.shaders, "Falta RenderParams.h en el bundle.", detail: folder.path)
        }
        let metalFiles = entries.filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !metalFiles.isEmpty else {
            throw AppError(.shaders, "No se encontro ningun .metal en el bundle.", detail: folder.path)
        }

        var chunks: [String] = []
        // metal_stdlib va primero: RenderParams.h usa int32_t y vector_uint2, que
        // en MSL los define la stdlib. Los .metal lo incluyen igual por claridad;
        // el include guard hace que el segundo sea gratis.
        chunks.append("#include <metal_stdlib>\nusing namespace metal;")
        chunks.append(try read(header))
        for file in metalFiles {
            chunks.append("// ---- \(file.lastPathComponent) ----")
            chunks.append(try read(file))
        }
        return chunks.joined(separator: "\n")
    }

    private static func read(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw AppError(.shaders, "No se pudo leer \(url.lastPathComponent).", underlying: error)
        }
    }

    private static func locateShaderFolder() throws -> URL {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(resourceFolder))
        }
        // Fallback para correr el binario suelto (swift run) sin el .app armado.
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent(resourceFolder))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw AppError(.shaders, "No se encontro la carpeta de shaders.",
                       detail: candidates.map(\.path).joined(separator: "\n"))
    }
}
