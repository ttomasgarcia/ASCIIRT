import Foundation
import Metal
import simd

/// Globos de diálogo escritos DIRECTO en la grilla de caracteres.
///
/// La alternativa era dibujar los globos en una imagen y dejar que el pipeline
/// los convirtiera a ASCII como a cualquier otra fuente. No sirve: a los tamaños
/// de celda que se usan, un texto pasado por la rampa queda ilegible — se lee
/// como una mancha de densidad con forma de renglón. Escribiendo una letra por
/// celda el texto queda nítido y además la app dibuja lo que es: caracteres en
/// una grilla.
///
/// El maquetado corre en CPU y produce, por celda, qué carácter va y con cuánta
/// opacidad. Son 7360 celdas en una salida de 1080p con celda de 12: recorrerlas
/// enteras todos los frames cuesta menos que decidir cuándo hace falta.
struct ChatMessage: Equatable {
    var text: String
}

/// Cómo entra cada globo.
enum ChatEntrance: UInt32, CaseIterable, Identifiable {
    case fade = 0       // aparece en el lugar
    case rise = 1       // sube desde abajo
    case riseFade = 2   // sube y aparece
    case type = 3       // se escribe letra por letra

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fundido"
        case .rise: return "Sube"
        case .riseFade: return "Sube y funde"
        case .type: return "Se escribe"
        }
    }
}

final class ChatLayer {

    // MARK: Contenido

    var messages: [ChatMessage] = []

    // MARK: Tiempos

    /// Segundos entre la entrada de un mensaje y la del siguiente.
    var interval: Float = 2.5
    /// Cuánto dura la animación de entrada.
    var entranceDuration: Float = 0.45
    var entrance: ChatEntrance = .riseFade
    /// Cuántas celdas sube el globo mientras entra.
    var riseCells: Float = 4
    /// Si repite la conversación desde el principio al terminar.
    var loops = true
    /// Segundos de espera antes del primer mensaje.
    var startDelay: Float = 0.5

    // MARK: Forma

    /// Cuántas celdas ocupa cada carácter, por lado. La escala mueve el globo
    /// entero, así que todo el maquetado vive en una grilla más gruesa que la de
    /// celdas y por eso las posiciones siempre caen en múltiplos de este número.
    var scale: Int = 2
    /// Ancho máximo del globo en caracteres, antes de cortar el renglón.
    var maxColumns: Int = 28
    /// Margen interno del globo, en caracteres.
    var padX: Int = 1
    var padY: Int = 0
    /// Separación entre globos, en caracteres.
    var gap: Int = 1
    /// Distancia al borde de abajo y al de la izquierda, en caracteres.
    var marginBottom: Int = 2
    var marginLeft: Int = 2

    // MARK: Salida

    private(set) var texture: MTLTexture?
    private var gridSize = SIMD2<UInt32>(0, 0)
    private var buffer: [UInt8] = []

    /// Recalcula el maquetado y sube la textura.
    ///
    /// `chars` lleva el índice de carácter + 1 por celda (0 = vacío) y `alphas`
    /// la opacidad del globo. Van en dos canales de la misma textura para que el
    /// shader resuelva todo con una sola lectura.
    /// Crea la textura si hace falta. Se llama SIEMPRE, aunque el chat este
    /// apagado: el shader la lee por una condicion de runtime, asi que el binding
    /// tiene que existir igual.
    func ensure(device: MTLDevice, gridSize size: SIMD2<UInt32>) {
        guard size != gridSize || texture == nil else { return }
        gridSize = size
        makeTexture(device: device)
        upload()
    }

    func update(device: MTLDevice,
                gridSize size: SIMD2<UInt32>,
                atlas: TextAtlas,
                time: Float) {
        ensure(device: device, gridSize: size)
        guard let texture, gridSize.x > 0, gridSize.y > 0 else { return }

        let cols = Int(gridSize.x)
        let rows = Int(gridSize.y)
        for i in buffer.indices { buffer[i] = 0 }

        let step = max(scale, 1)
        // Todo el maquetado se hace en "casillas" de `scale` celdas de lado, y
        // recién al final se expande a celdas. Así un carácter nunca queda
        // partido entre dos casillas y el globo entero cae en la misma grilla.
        let boxCols = cols / step
        let boxRows = rows / step
        guard boxCols > 4, boxRows > 2 else { upload(); return }

        let visible = layout(boxCols: boxCols, boxRows: boxRows, time: time)

        for balloon in visible {
            paint(balloon, atlas: atlas, boxCols: boxCols, boxRows: boxRows, step: step, cols: cols, rows: rows)
        }

        texture.replace(region: MTLRegionMake2D(0, 0, cols, rows),
                        mipmapLevel: 0, withBytes: buffer, bytesPerRow: cols * 2)
    }

    // MARK: - Maquetado

    private struct Balloon {
        var lines: [String]
        var width: Int      // en casillas, incluido el margen interno
        var height: Int
        var originX: Int    // en casillas
        var originY: Int    // borde superior, en casillas
        var alpha: Float
        var revealed: Int   // caracteres visibles, para la entrada tipeada
    }

    /// Corta el texto en renglones que entren en `maxColumns`, sin partir
    /// palabras salvo que una sola palabra no entre.
    private func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [text] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= width {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                var rest = String(word)
                while rest.count > width {
                    lines.append(String(rest.prefix(width)))
                    rest = String(rest.dropFirst(width))
                }
                current = rest
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Qué globos se ven y dónde, para este instante.
    ///
    /// La pila se ancla ABAJO: el mensaje nuevo entra al pie y empuja a los
    /// viejos hacia arriba. Es lo que hace cualquier chat, y es lo que permite
    /// que la entrada "sube" se lea como que el mensaje llega y no como que la
    /// pantalla hace scroll.
    private func layout(boxCols: Int, boxRows: Int, time: Float) -> [Balloon] {
        let texts = messages.map(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return [] }

        let period = max(interval, 0.05)
        let total = Float(texts.count) * period
        var clock = max(time - startDelay, 0)
        if loops && total > 0 { clock = clock.truncatingRemainder(dividingBy: total + period) }

        // El ancho pedido se acota a lo que entra de verdad. Con escala alta la
        // grilla de casillas es chica —a escala 6 sobre 160 columnas quedan 26— y
        // un globo de 28 caracteres se saldria de cuadro por la derecha.
        let usable = max(boxCols - marginLeft - 1, 4)
        let innerWidth = max(min(maxColumns, usable) - padX * 2, 1)

        // Cuántos entraron ya, y hace cuánto entró el último.
        let entered = min(Int(clock / period) + 1, texts.count)
        guard entered > 0 else { return [] }

        var stack: [Balloon] = []
        var cursorY = boxRows - marginBottom   // borde inferior de la pila

        // Se recorre del más nuevo al más viejo, apilando hacia arriba.
        for i in stride(from: entered - 1, through: 0, by: -1) {
            let age = clock - Float(i) * period
            let t = min(max(age / max(entranceDuration, 0.01), 0), 1)
            let eased = t * t * (3 - 2 * t)

            let lines = wrap(texts[i], width: innerWidth)
            let bodyWidth = lines.map(\.count).max() ?? 0
            let width = bodyWidth + padX * 2
            let height = lines.count + padY * 2

            var alpha: Float = 1
            var offset = 0
            switch entrance {
            case .fade: alpha = eased
            case .rise: offset = Int((1 - eased) * riseCells)
            case .riseFade:
                alpha = eased
                offset = Int((1 - eased) * riseCells)
            case .type: break
            }

            let revealed: Int
            if entrance == .type {
                let totalChars = lines.reduce(0) { $0 + $1.count }
                revealed = Int(eased * Float(totalChars) + 0.5)
            } else {
                revealed = Int.max
            }

            cursorY -= height
            stack.append(Balloon(lines: lines, width: width, height: height,
                                 originX: marginLeft, originY: cursorY + offset,
                                 alpha: alpha, revealed: revealed))
            cursorY -= gap
            if cursorY < 0 { break }
        }
        return stack
    }

    // MARK: - Pintado

    private func paint(_ balloon: Balloon, atlas: TextAtlas,
                       boxCols: Int, boxRows: Int, step: Int, cols: Int, rows: Int) {
        let alpha = UInt8(max(0, min(255, Int(balloon.alpha * 255))))
        guard alpha > 0 else { return }

        var written = 0
        for (row, line) in balloon.lines.enumerated() {
            let by = balloon.originY + padY + row
            guard by >= 0, by < boxRows else { continue }
            for (column, character) in line.enumerated() {
                let bx = balloon.originX + padX + column
                guard bx >= 0, bx < boxCols else { continue }
                written += 1
                guard written <= balloon.revealed else { break }
                let index = atlas.index(of: character)
                stamp(box: SIMD2(bx, by), char: index, alpha: alpha,
                      step: step, cols: cols, rows: rows)
            }
            if written > balloon.revealed { break }
        }

        // Fondo del globo. Se pinta despues de las letras y solo donde no hay
        // ninguna, para no tener que ordenar dos pasadas.
        for by in balloon.originY..<(balloon.originY + balloon.height) {
            guard by >= 0, by < boxRows else { continue }
            for bx in balloon.originX..<(balloon.originX + balloon.width) {
                guard bx >= 0, bx < boxCols else { continue }
                stamp(box: SIMD2(bx, by), char: 0, alpha: alpha,
                      step: step, cols: cols, rows: rows, backgroundOnly: true)
            }
        }
    }

    /// Expande una casilla a las `step x step` celdas que ocupa.
    private func stamp(box: SIMD2<Int>, char: UInt8, alpha: UInt8,
                       step: Int, cols: Int, rows: Int, backgroundOnly: Bool = false) {
        for dy in 0..<step {
            let y = box.y * step + dy
            guard y >= 0, y < rows else { continue }
            for dx in 0..<step {
                let x = box.x * step + dx
                guard x >= 0, x < cols else { continue }
                let offset = (y * cols + x) * 2
                if backgroundOnly {
                    if buffer[offset + 1] == 0 { buffer[offset + 1] = alpha }
                } else {
                    buffer[offset] = char
                    buffer[offset + 1] = alpha
                }
            }
        }
    }

    // MARK: - Textura

    private func makeTexture(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Uint,
            width: Int(gridSize.x), height: Int(gridSize.y), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "asciirt.chat"
        buffer = [UInt8](repeating: 0, count: Int(gridSize.x) * Int(gridSize.y) * 2)
    }

    private func upload() {
        guard let texture, gridSize.x > 0 else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, Int(gridSize.x), Int(gridSize.y)),
                        mipmapLevel: 0, withBytes: buffer, bytesPerRow: Int(gridSize.x) * 2)
    }
}
