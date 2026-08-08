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
    case bounce = 4     // sube, se pasa y vuelve

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fundido"
        case .rise: return "Sube"
        case .riseFade: return "Sube y funde"
        case .type: return "Se escribe"
        case .bounce: return "Rebote"
        }
    }
}

/// Como se va cada globo. Solo aplica en «uno por vez»: en pila nada se va.
enum ChatExit: UInt32, CaseIterable, Identifiable {
    case fade = 0       // se apaga en el lugar
    case riseAway = 1   // sigue subiendo y se apaga
    case fallAway = 2   // cae y se apaga
    case cut = 3        // desaparece de un frame al otro

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fundido"
        case .riseAway: return "Se va arriba"
        case .fallAway: return "Se va abajo"
        case .cut: return "Corte"
        }
    }
}

/// Como se suceden los mensajes.
enum ChatMode: UInt32, CaseIterable, Identifiable {
    /// Se acumulan: el que llega entra al pie y empuja a los viejos hacia arriba.
    case stack = 0
    /// Uno por vez: entra, se queda, se va, y el siguiente ocupa su lugar.
    case single = 1

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .stack: return "Pila"
        case .single: return "Uno por vez"
        }
    }
}

/// Forma del globo. Todo se dibuja con celdas enteras, asi que "redondeado"
/// quiere decir esquinas recortadas en escalera, no una curva: en una grilla de
/// caracteres es lo unico que existe, y a escala 2 o mas ya se lee como redondeo.
enum ChatBubbleShape: UInt32, CaseIterable, Identifiable {
    case rect = 0
    case rounded = 1

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .rect: return "Recto"
        case .rounded: return "Redondeado"
        }
    }
}

final class ChatLayer {

    // MARK: Contenido

    var messages: [ChatMessage] = []

    // MARK: Tiempos

    /// Segundos entre la entrada de un mensaje y la del siguiente.
    var interval: Float = 2.5
    /// Pantalla vacia entre un mensaje y el proximo, en segundos.
    ///
    /// Solo tiene sentido en «uno por vez»: en pila nada se va, asi que el hueco
    /// no existe y el tiempo entre mensajes ya es el intervalo.
    var pause: Float = 0
    /// Cuánto dura la animación de entrada.
    var entranceDuration: Float = 0.45
    var entrance: ChatEntrance = .riseFade
    var mode: ChatMode = .stack
    var exit: ChatExit = .fade
    /// Cuanto dura la salida. Separada de la entrada porque casi nunca se
    /// quieren iguales: entrar llama la atencion, irse no deberia.
    var exitDuration: Float = 0.35
    /// Cuanto se pasa el rebote, de 0 (sin rebote) a 1 (elastico).
    var bounce: Float = 0.5
    /// Cuanto tarda la opacidad, aparte del movimiento. Un globo que se desliza
    /// en medio segundo pero tarda ese mismo medio segundo en aparecer se ve
    /// lavado todo el viaje; el fundido casi siempre quiere ser mas corto.
    var fadeIn: Float = 0.15
    var fadeOut: Float = 0.20

    /// Desplazamiento vertical en pixeles de salida, para el shader. Lo llena el
    /// maquetado del modo «uno por vez», que es el unico con un solo globo.
    private(set) var pixelOffset: Float = 0
    /// Alto de celda en pixeles: hace falta para pasar de casillas a pixeles.
    var cellHeight: Int = 16
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
    /// Forma del globo y si lleva piquito.
    var shape: ChatBubbleShape = .rect
    var tail = false

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

        // En «uno por vez» el ciclo de un mensaje es lo que dura en pantalla MAS
        // la pausa con la pantalla vacia. En pila no hay pausa: el intervalo ya
        // es el tiempo entre una llegada y la siguiente.
        let visibleFor = max(interval, 0.05)
        let period = mode == .single ? visibleFor + max(pause, 0) : visibleFor
        let total = Float(texts.count) * period
        var clock = max(time - startDelay, 0)
        // En pila se agrega un periodo de mas para que el ultimo mensaje se
        // quede a la vista antes de que la conversacion vuelva a empezar. En uno
        // por vez no hace falta: cada mensaje ya tiene su propia salida.
        if loops && total > 0 {
            let cycle = mode == .single ? total : total + period
            clock = clock.truncatingRemainder(dividingBy: cycle)
        }

        // El ancho pedido se acota a lo que entra de verdad. Con escala alta la
        // grilla de casillas es chica —a escala 6 sobre 160 columnas quedan 26— y
        // un globo de 28 caracteres se saldria de cuadro por la derecha.
        let usable = max(boxCols - marginLeft - 1, 4)
        let innerWidth = max(min(maxColumns, usable) - padX * 2, 1)

        if mode == .single {
            return layoutSingle(texts: texts, innerWidth: innerWidth, boxRows: boxRows,
                                clock: clock, period: period, visibleFor: visibleFor)
        }
        // En pila hay varios globos, cada uno en su momento de la animacion, y el
        // corrimiento del shader es uno solo para toda la capa. Ahi se sigue
        // moviendo de a celdas.
        pixelOffset = 0

        // Cuántos entraron ya, y hace cuánto entró el último.
        let entered = min(Int(clock / period) + 1, texts.count)
        guard entered > 0 else { return [] }

        var stack: [Balloon] = []
        var cursorY = boxRows - marginBottom   // borde inferior de la pila

        // Se recorre del más nuevo al más viejo, apilando hacia arriba.
        for i in stride(from: entered - 1, through: 0, by: -1) {
            let age = clock - Float(i) * period
            let t = min(max(age / max(entranceDuration, 0.01), 0), 1)
            let eased = entrance == .bounce ? spring(age, response: max(entranceDuration, 0.01))
                                            : t * t * (3 - 2 * t)

            let lines = wrap(texts[i], width: innerWidth)
            let bodyWidth = lines.map(\.count).max() ?? 0
            let width = bodyWidth + padX * 2
            let height = lines.count + padY * 2

            var alpha: Float = 1
            var offset = 0
            switch entrance {
            case .fade: alpha = min(age / max(fadeIn, 0.01), 1)
            case .rise: offset = Int((1 - eased) * riseCells)
            case .riseFade:
                alpha = min(age / max(fadeIn, 0.01), 1)
                offset = Int(((1 - eased) * riseCells).rounded())
            case .type: break
            case .bounce:
                offset = Int(((1 - eased) * riseCells).rounded())
                alpha = min(age / max(fadeIn, 0.01), 1)
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
            // El piquito baja dos casillas por debajo del globo, asi que con
            // separacion 1 se le montaba encima del mensaje de abajo.
            cursorY -= tail ? max(gap, 3) : gap
            if cursorY < 0 { break }
        }
        return stack
    }

    /// Uno por vez: entra, se queda, se va, y el siguiente ocupa exactamente el
    /// mismo lugar.
    ///
    /// El intervalo pasa a ser el ciclo COMPLETO — entrada, permanencia y
    /// salida— y no el tiempo entre mensajes. Con la pila los dos numeros
    /// coinciden porque nada se va; aca no, y medirlo de otra forma haria que
    /// subir la duracion de la animacion acortara el tiempo de lectura sin
    /// avisar.
    ///
    /// La salida no es la entrada al reves: sigue subiendo. Un globo que entra
    /// desde abajo y despues vuelve a bajar se lee como que alguien lo borro; uno
    /// que sigue de largo se lee como que paso.
    private func layoutSingle(texts: [String], innerWidth: Int, boxRows: Int,
                              clock: Float, period: Float, visibleFor: Float) -> [Balloon] {
        let index = min(Int(clock / period), texts.count - 1)
        let age = clock - Float(index) * period

        // Pausa: el mensaje ya se fue y el proximo todavia no llega.
        guard age <= visibleFor else {
            pixelOffset = 0
            return []
        }

        // Ni la entrada ni la salida pueden comerse el ciclo: entre las dos se
        // les deja como mucho el 90%, si no el mensaje nunca llega a estar quieto.
        let wanted = max(entranceDuration, 0.01) + max(exitDuration, 0)
        let squeeze = wanted > visibleFor * 0.9 ? visibleFor * 0.9 / wanted : 1
        let animIn = max(entranceDuration, 0.01) * squeeze
        let animOut = max(exitDuration, 0) * squeeze

        let tIn = min(max(age / animIn, 0), 1)
        let tOut: Float
        if exit == .cut || animOut <= 0 {
            tOut = age >= visibleFor - 1e-4 ? 1 : 0
        } else {
            tOut = min(max((age - (visibleFor - animOut)) / animOut, 0), 1)
        }
        // El movimiento del rebote se evalua en segundos y puede seguir despues
        // de `animIn`: un resorte se sigue asentando aunque ya haya llegado.
        let easeIn = entrance == .bounce ? spring(age, response: animIn)
                                         : tIn * tIn * (3 - 2 * tIn)
        let easeOut = tOut * tOut * (3 - 2 * tOut)

        // La opacidad tiene sus propios tiempos, mas cortos que el movimiento.
        let fadeInT = min(max(age / max(fadeIn, 0.01), 0), 1)
        let fadeOutStart = visibleFor - max(fadeOut, 0)
        let fadeOutT = max(fadeOut, 0) <= 0 ? (age >= visibleFor - 1e-4 ? 1 : 0)
                                            : min(max((age - fadeOutStart) / max(fadeOut, 0.01), 0), 1)
        let appear = fadeInT * fadeInT * (3 - 2 * fadeInT)
        let vanish = fadeOutT * fadeOutT * (3 - 2 * fadeOutT)

        let lines = wrap(texts[index], width: innerWidth)
        let bodyWidth = lines.map(\.count).max() ?? 0
        let height = lines.count + padY * 2

        var alpha: Float = 1
        var offset: Float = 0
        switch entrance {
        case .fade: break
        case .rise: offset = (1 - easeIn) * riseCells
        case .riseFade: offset = (1 - easeIn) * riseCells
        case .type: break
        case .bounce:
            // El rebote se pasa de largo: `easeIn` cruza 1 y vuelve, asi que el
            // desplazamiento se hace negativo un momento y el globo aparece un
            // poco mas arriba de su lugar antes de asentarse.
            offset = (1 - easeIn) * riseCells
        }
        // La opacidad NO sigue al movimiento: tiene su propio tiempo.
        if entrance != .type { alpha = appear }

        switch exit {
        case .fade: alpha *= 1 - vanish
        case .riseAway:
            alpha *= 1 - vanish
            offset -= easeOut * riseCells
        case .fallAway:
            alpha *= 1 - vanish
            offset += easeOut * riseCells
        case .cut: alpha *= tOut >= 1 ? 0 : 1
        }

        let revealed: Int
        if entrance == .type {
            let totalChars = lines.reduce(0) { $0 + $1.count }
            revealed = Int(easeIn * Float(totalChars) + 0.5)
        } else {
            revealed = Int.max
        }

        // Anclado abajo, igual que el mensaje mas nuevo de la pila: el lugar es
        // el mismo aunque el mensaje siguiente tenga otra cantidad de renglones.
        let originY = boxRows - marginBottom - height

        // El globo se maqueta en su lugar de reposo y el desplazamiento viaja en
        // pixeles al shader. Es lo que saca los saltos de celda: la CPU no puede
        // escribir medio caracter, pero correr de donde se lee si se puede.
        pixelOffset = offset * Float(max(scale, 1) * max(cellHeight, 1))

        return [Balloon(lines: lines, width: bodyWidth + padX * 2, height: height,
                        originX: marginLeft, originY: originY,
                        alpha: alpha, revealed: revealed)]
    }

    /// Curva de entrada con sobrepaso: resorte subamortiguado normalizado.
    ///
    /// Llega a 1 pasandose y volviendo, que es lo que hace un globo de mensaje en
    /// una UI. El sobrepaso se ve en escalones enteros de celda, no en fracciones
    /// —el maquetado vive en la grilla— asi que con la subida corta el rebote no
    /// llega a notarse: hacen falta unas cuantas celdas para que el sobrepaso
    /// cruce el redondeo.
    /// Resorte normalizado, evaluado en SEGUNDOS y no en fraccion de animacion.
    ///
    /// Antes corria sobre `t` de 0 a 1 con frecuencia fija, asi que la duracion
    /// estiraba o comprimia la curva entera y el rebote siempre tardaba lo mismo
    /// en proporcion: se sentia mecanico. Ahora la duracion es el TIEMPO DE
    /// RESPUESTA —cuanto tarda en llegar— y el rebote solo cambia cuanto se pasa,
    /// que es como se parametriza un resorte de UI.
    ///
    /// En rebote 0 queda criticamente amortiguado: llega derecho y no se pasa,
    /// que es lo mas rapido posible sin sobrepaso.
    private func spring(_ t: Float, response: Float) -> Float {
        guard t > 0 else { return 0 }
        let omega = 6.5 / max(response, 0.03)
        let zeta = max(1 - min(max(bounce, 0), 1) * 0.92, 0.08)
        if zeta >= 0.999 {
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
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
        let lastX = balloon.width - 1
        let lastY = balloon.height - 1
        for row in 0..<balloon.height {
            let by = balloon.originY + row
            guard by >= 0, by < boxRows else { continue }
            for column in 0..<balloon.width {
                // Redondeado: se saca la casilla de cada esquina. En una grilla de
                // caracteres no hay curva posible, y el recorte en escalera es lo
                // que la sugiere — a escala 2 o mas se lee como redondeo.
                if shape == .rounded, balloon.height > 1, balloon.width > 2,
                   (column == 0 || column == lastX), (row == 0 || row == lastY) {
                    continue
                }
                let bx = balloon.originX + column
                guard bx >= 0, bx < boxCols else { continue }
                stamp(box: SIMD2(bx, by), char: 0, alpha: alpha,
                      step: step, cols: cols, rows: rows, backgroundOnly: true)
            }
        }

        // Piquito. Va abajo a la izquierda, del mismo lado por el que se alinean
        // los globos, y en escalera: dos casillas y despues una. Es lo que en una
        // grilla se lee como la puntita de un globo de dialogo.
        if tail {
            let base = balloon.originY + balloon.height
            for (row, run) in [(0, 2), (1, 1)] {
                let by = base + row
                guard by >= 0, by < boxRows else { continue }
                for column in 0..<run {
                    let bx = balloon.originX + 1 + column
                    guard bx >= 0, bx < boxCols else { continue }
                    stamp(box: SIMD2(bx, by), char: 0, alpha: alpha,
                          step: step, cols: cols, rows: rows, backgroundOnly: true)
                }
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
