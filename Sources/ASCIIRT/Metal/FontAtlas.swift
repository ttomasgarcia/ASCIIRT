import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

/// De donde sale la fuente: una instalada en el sistema o un archivo suelto.
enum FontSelection: Equatable, Hashable {
    case system(name: String)
    case file(url: URL)

    var displayName: String {
        switch self {
        case .system(let name): return name
        case .file(let url): return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Monoespaciadas que estan siempre en macOS. Sirven de default y de
    /// comparacion rapida sin abrir el file picker.
    static let systemDefaults: [FontSelection] = [
        .system(name: "Menlo-Regular"),
        .system(name: "Monaco"),
        .system(name: "Courier"),
        .system(name: "PTMono-Regular")
    ]

    /// Alto/ancho de la celda tipografica: (ascent+descent) sobre el avance.
    /// En una monoespaciada tipica da ~2. Es el numero que evita que el glifo
    /// salga estirado cuando se lo mete en la celda.
    func naturalCellAspect() throws -> Double {
        let font = try makeFont(size: 100)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font)

        var glyph = CGGlyph(0)
        let chars = Array("M".utf16)
        guard CTFontGetGlyphsForCharacters(font, chars, &glyph, 1) else {
            throw AppError(.shaders, "No se pudo medir el avance de «\(displayName)».")
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        guard advance.width > 0, height > 0 else {
            throw AppError(.shaders, "Metricas invalidas en «\(displayName)».")
        }
        return Double(height / advance.width)
    }

    func makeFont(size: CGFloat) throws -> CTFont {
        switch self {
        case .system(let name):
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CTFontCreateWithName nunca falla: si el nombre no existe devuelve
            // Helvetica. Comparar el nombre real es la unica forma de detectarlo.
            let actual = CTFontCopyPostScriptName(font) as String
            guard actual == name || actual.hasPrefix(name) else {
                throw AppError(.shaders, "La fuente «\(name)» no esta instalada.",
                               detail: "El sistema devolvio «\(actual)» en su lugar.")
            }
            return font

        case .file(let url):
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let first = descriptors.first else {
                throw AppError(.shaders, "No se pudo leer la fuente.", detail: url.lastPathComponent)
            }
            return CTFontCreateWithFontDescriptor(first, size, nil)
        }
    }
}

/// Un glifo del charset con su cobertura de tinta medida.
struct GlyphCoverage: Identifiable, Equatable {
    let character: Character
    /// 0.0–1.0, normalizado contra el glifo mas denso del set (spec §2).
    let coverage: Double
    let included: Bool

    var id: Character { character }

    /// Como se muestra en la tabla: el espacio necesita etiqueta propia.
    var label: String {
        character == " " ? "␣" : String(character)
    }
}

/// Atlas de glifos: una fila de celdas cuadradas de `cellSize` px, **en el orden
/// de la rampa calibrada**. R8Unorm, donde el valor es cobertura de tinta.
///
/// Se regenera solo cuando cambia la fuente, el charset, las exclusiones o el
/// tile (spec §2). Nunca por frame.
struct FontAtlas {
    let texture: MTLTexture
    /// El orden de este array **es** la rampa: cobertura ascendente.
    let ramp: [Character]
    /// Todos los glifos del charset, incluidos los excluidos, para la tabla de UI.
    let coverage: [GlyphCoverage]
    let cellWidth: Int
    let cellHeight: Int

    var rampLength: Int { ramp.count }
}

enum FontAtlasBuilder {

    /// Rasteriza, mide cobertura y ordena. Spec §2, los cinco pasos:
    /// rasterizar → sumar tinta → normalizar contra el mas denso → ordenar
    /// ascendente → esa secuencia es la rampa.
    ///
    /// La celda se llena en los dos ejes: sx = ancho/avance, sy = alto/(asc+desc).
    /// Cuando el alto de celda respeta el aspecto natural de la fuente los dos
    /// factores coinciden y el glifo sale sin deformar. Si el usuario fuerza otro
    /// aspecto, la deformacion es deliberada y visible en el control.
    static func build(device: MTLDevice,
                      font selection: FontSelection,
                      charset: [Character],
                      excluded: Set<Character>,
                      cellWidth: Int,
                      cellHeight: Int) throws -> FontAtlas {
        // Dedup preservando el orden de tipeo: un charset con repetidos daria
        // celdas identicas y romperia la identidad en la tabla de la UI.
        var seen = Set<Character>()
        let characters = charset.filter { seen.insert($0).inserted }

        guard !characters.isEmpty else {
            throw AppError(.shaders, "El charset esta vacio.")
        }
        guard cellWidth > 0, cellHeight > 0 else {
            throw AppError(.shaders, "Tamano de celda invalido: \(cellWidth)x\(cellHeight).")
        }

        // Se mide a un tamano grande y se deriva el definitivo para que
        // ascent+descent caiga en la altura de celda; asi el escalado vertical
        // queda cerca de 1 y el rasterizador trabaja a su tamano natural.
        let probe = try selection.makeFont(size: 100)
        let probeHeight = CTFontGetAscent(probe) + CTFontGetDescent(probe)
        guard probeHeight > 0 else {
            throw AppError(.shaders, "No se pudo medir «\(selection.displayName)».")
        }
        let font = try selection.makeFont(size: 100.0 * CGFloat(cellHeight) / probeHeight)

        // 1) Rasterizar el charset completo en orden de tipeo.
        let strip = try rasterize(characters: characters, font: font, selection: selection,
                                  cellWidth: cellWidth, cellHeight: cellHeight)

        // 2+3) Sumar tinta por celda y normalizar contra el mas denso.
        let rawInk = characters.indices.map {
            ink(in: strip, cellIndex: $0, cellWidth: cellWidth, cellHeight: cellHeight,
                stride: cellWidth * characters.count)
        }
        let densest = rawInk.max() ?? 0
        let normalized = rawInk.map { densest > 0 ? $0 / densest : 0 }

        // 4) Ordenar ascendente, solo los incluidos.
        let includedIndices = characters.indices
            .filter { !excluded.contains(characters[$0]) }
            .sorted { normalized[$0] < normalized[$1] }

        guard includedIndices.count >= 2 else {
            throw AppError(.shaders, "La rampa necesita al menos 2 glifos.",
                           detail: "Quedaron \(includedIndices.count) despues de excluir.")
        }

        // 5) Esa secuencia es la rampa. El atlas se arma copiando celdas en ese
        // orden, sin volver a rasterizar.
        let texture = try makeTexture(device: device,
                                      strip: strip,
                                      order: includedIndices,
                                      cellWidth: cellWidth,
                                      cellHeight: cellHeight,
                                      sourceStride: cellWidth * characters.count)

        let coverage = characters.enumerated().map { index, character in
            GlyphCoverage(character: character,
                          coverage: normalized[index],
                          included: !excluded.contains(character))
        }

        return FontAtlas(texture: texture,
                         ramp: includedIndices.map { characters[$0] },
                         coverage: coverage,
                         cellWidth: cellWidth,
                         cellHeight: cellHeight)
    }

    // MARK: - Rasterizacion

    /// Bitmap gris de 8 bpp, una celda por caracter, en orden de tipeo.
    private static func rasterize(characters: [Character],
                                  font: CTFont,
                                  selection: FontSelection,
                                  cellWidth: Int,
                                  cellHeight: Int) throws -> [UInt8] {
        let width = cellWidth * characters.count

        let glyphs = try glyphIDs(for: characters, font: font, selection: selection)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)

        var pixels = [UInt8](repeating: 0, count: width * cellHeight)

        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: cellHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw AppError(.shaders, "No se pudo crear el contexto de rasterizacion del atlas.")
            }

            context.setFillColor(gray: 1, alpha: 1)
            context.setShouldAntialias(true)
            // Font smoothing dilata los trazos y falsea la cobertura de tinta,
            // que es justamente lo que se mide para ordenar la rampa.
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setAllowsFontSubpixelQuantization(false)

            for (i, glyph) in glyphs.enumerated() {
                let advance = advances[i].width
                // Sin ancho (el espacio, por ejemplo) no se dibuja: la celda
                // queda negra, que es cobertura cero.
                guard advance > 0 else { continue }

                context.saveGState()
                context.translateBy(x: CGFloat(i) * CGFloat(cellWidth), y: 0)
                context.scaleBy(x: CGFloat(cellWidth) / advance,
                                y: CGFloat(cellHeight) / (ascent + descent))
                context.translateBy(x: 0, y: descent) // baseline
                var position = CGPoint.zero
                var mutableGlyph = glyph
                CTFontDrawGlyphs(font, &mutableGlyph, &position, 1, context)
                context.restoreGState()
            }
        }

        return pixels
    }

    /// Tinta media de una celda, 0.0–1.0 antes de normalizar.
    private static func ink(in strip: [UInt8], cellIndex: Int,
                            cellWidth: Int, cellHeight: Int, stride: Int) -> Double {
        var total = 0
        for y in 0..<cellHeight {
            let rowStart = y * stride + cellIndex * cellWidth
            for x in 0..<cellWidth {
                total += Int(strip[rowStart + x])
            }
        }
        return Double(total) / Double(cellWidth * cellHeight * 255)
    }

    private static func makeTexture(device: MTLDevice,
                                    strip: [UInt8],
                                    order: [Int],
                                    cellWidth: Int,
                                    cellHeight: Int,
                                    sourceStride: Int) throws -> MTLTexture {
        let width = cellWidth * order.count
        var packed = [UInt8](repeating: 0, count: width * cellHeight)

        for (destination, source) in order.enumerated() {
            for y in 0..<cellHeight {
                let from = y * sourceStride + source * cellWidth
                let to = y * width + destination * cellWidth
                packed.replaceSubrange(to..<(to + cellWidth),
                                       with: strip[from..<(from + cellWidth)])
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: cellHeight, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AppError(.metal, "No se pudo crear la textura del atlas.")
        }
        texture.label = "asciirt.atlas"
        packed.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, cellHeight),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: width)
        }
        return texture
    }

    private static func glyphIDs(for characters: [Character],
                                 font: CTFont,
                                 selection: FontSelection) throws -> [CGGlyph] {
        // Se resuelve caracter por caracter porque un charset puede mezclar
        // largos de UTF-16 y una sola pasada mezclaria los indices.
        var glyphs: [CGGlyph] = []
        glyphs.reserveCapacity(characters.count)

        for character in characters {
            let utf16 = Array(String(character).utf16)
            var resolved = [CGGlyph](repeating: 0, count: utf16.count)
            let ok = CTFontGetGlyphsForCharacters(font, utf16, &resolved, utf16.count)
            guard ok, let first = resolved.first else {
                throw AppError(.shaders,
                               "«\(selection.displayName)» no tiene glifo para «\(character)».")
            }
            glyphs.append(first)
        }
        return glyphs
    }
}
