import Foundation
import Metal
import ShaderTypes
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

/// Como se presenta el texto.
enum ChatStyle: UInt32, CaseIterable, Identifiable {
    /// Globos de chat, alineados a un margen.
    case bubbles = 0
    /// Terminal: sin globo, centrado, tipeado con un cursor que parpadea.
    case terminal = 1

    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .bubbles: return "Globos"
        case .terminal: return "Terminal"
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

    /// Puntitos de «esta escribiendo» antes de cada mensaje.
    var typingEnabled = false
    /// Cuanto se ven antes de que aparezca el mensaje.
    var typingDuration: Float = 1.2
    /// Ciclos por segundo de la onda que recorre los puntos.
    var typingSpeed: Float = 1.4
    /// Diametro de cada punto, en alturas de celda.
    var typingSize: Float = 2

    /// Los globos, en pixeles, para que el shader dibuje el fondo por pixel.
    private(set) var rects: [ASCIIRTChatRect] = []
    /// Mas de esto no entra en pantalla en ninguna configuracion razonable.
    static let maxRects = 16

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
    /// Ancho del globo como FRACCION del ancho de pantalla.
    ///
    /// Se mide asi y no en caracteres porque en caracteres el ancho del globo
    /// queda atado al tamano de letra: agrandar la letra agrandaba el globo, y no
    /// habia forma de pedir "letra mas grande, globo igual". Con una fraccion, el
    /// ancho en pantalla lo fija este numero y la cantidad de caracteres por
    /// renglon cae sola de dividir por la escala.
    var widthFraction: Float = 0.35
    /// Margen interno del globo, en caracteres.
    var padX: Int = 1
    var padY: Int = 0    // renglones de aire arriba y abajo del texto
    /// Separación entre globos, en caracteres.
    var gap: Int = 1
    /// Distancia al borde de abajo y al de la izquierda, en caracteres.
    var marginBottom: Int = 2
    var marginLeft: Int = 2
    /// Forma del globo y si lleva piquito.
    var style: ChatStyle = .bubbles
    /// Terminal: caracteres por segundo del tipeado.
    var typeSpeed: Float = 22
    /// Terminal: altura del renglon, como fraccion de la pantalla.
    var terminalY: Float = 0.72
    /// Terminal: ancho del cursor como fraccion del ancho de celda, y parpadeos
    /// por segundo. Mas ancho que un caracter se lee como cursor de bloque.
    var cursorWidth: Float = 0.5
    var cursorBlink: Float = 1.6

    var shape: ChatBubbleShape = .rect
    var tail = false
    /// Cuanto se redondean las esquinas, de 0 a 1 sobre el lado corto del globo.
    /// En 1 el globo queda con los extremos semicirculares, tipo pastilla.
    var corner: Float = 0.5
    /// Ancho de celda en pixeles. Junto con el alto define la forma real de la
    /// celda, que no es cuadrada, y sin eso el redondeo saldria ovalado.
    var cellWidth: Int = 8
    /// Extension vertical de la letra dentro de su celda.
    ///
    /// El rasterizador del atlas escala cada glifo para que LLENE la celda —lo
    /// hace para que la rampa mida cobertura sobre la celda entera— asi que la
    /// tinta ocupa casi todo el alto y estos valores son casi 0 y 1. Se dejan
    /// como parametros igualmente porque el cursor y los puntitos se alinean
    /// contra esto, y si algun dia el atlas deja de llenar la celda hay un solo
    /// lugar que tocar.
    ///
    /// Se intento medirlos del bitmap y la medicion caia siempre en el valor de
    /// respaldo: cursor de 16 px contra 32 de texto. Antes que dejar una medicion
    /// que no mide, van los numeros que se verifican en pantalla.
    var inkTop: Float = 0.05
    var inkHeight: Float = 0.9

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
        rects.removeAll(keepingCapacity: true)

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
        let typing = typingEnabled ? max(typingDuration, 0) : 0
        let period = (mode == .single || style == .terminal)
            ? typing + visibleFor + max(pause, 0) : visibleFor
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
        // Cuantos caracteres entran en el ancho pedido, a la escala actual.
        let usable = max(boxCols - marginLeft - 1, 4)
        let wanted = Int((min(max(widthFraction, 0.05), 1) * Float(boxCols)).rounded())
        let innerWidth = max(min(wanted, usable) - padX * 2, 1)

        if style == .terminal {
            return layoutTerminal(texts: texts, boxCols: boxCols, boxRows: boxRows,
                                  rawClock: max(time - startDelay, 0),
                                  hold: visibleFor, pauseTime: max(pause, 0),
                                  innerWidth: innerWidth, typing: typing)
        }
        if mode == .single {
            return layoutSingle(texts: texts, innerWidth: innerWidth, boxRows: boxRows,
                                clock: clock, period: period, visibleFor: visibleFor,
                                typing: typing)
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

        // En pila los puntos van al pie, ocupando el lugar donde va a caer el
        // mensaje que viene, y el resto de la pila ya esta empujada hacia arriba.
        // Asi el globo nuevo no da un salto al reemplazarlos.
        if typingEnabled, entered < texts.count {
            let untilNext = Float(entered) * period - clock
            if untilNext <= max(typingDuration, 0) {
                let height = 1 + padY * 2
                cursorY -= height
                emitDots(boxRows: cursorY + height + marginBottom, time: clock, alpha: 1)
                cursorY -= gap
            }
        }

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
                              clock: Float, period: Float, visibleFor: Float,
                              typing: Float) -> [Balloon] {
        let index = min(Int(clock / period), texts.count - 1)
        let raw = clock - Float(index) * period

        // Los puntitos van ANTES del mensaje y en su mismo lugar: el globo chico
        // esta donde va a estar el grande, asi que se lee como que el mensaje se
        // esta escribiendo ahi y no como un elemento aparte.
        if typing > 0, raw < typing {
            pixelOffset = 0
            // Los puntos salen SUELTOS, sin globo: se emiten como circulos en
            // pixeles y no hay ningun caracter que dibujar.
            emitDots(boxRows: boxRows, time: clock,
                     alpha: min(raw / max(fadeIn, 0.01), 1)
                          * min((typing - raw) / max(fadeOut, 0.01), 1))
            return []
        }
        let age = raw - typing

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
        // Frecuencia y amortiguacion mas blandas que la primera version.
        //
        // Ese mapeo se calibro cuando el globo se movia de a celdas enteras y el
        // redondeo se comia los sobrepasos chicos. Al pasar a pixeles el mismo
        // numero paso a verse entero, y lo que antes era un rebote apenas
        // insinuado se volvio un golpe. Con esto, medio slider da un rebote
        // suave y el extremo sigue estando disponible para cuando se lo quiera.
        let omega = 4.6 / max(response, 0.03)
        let zeta = max(1 - min(max(bounce, 0), 1) * 0.72, 0.24)
        if zeta >= 0.999 {
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
    }

    /// Tres circulos sueltos, animados en pixeles.
    ///
    /// Van como rectangulos con el radio al maximo —o sea circulos— y no como
    /// caracteres: asi son redondos de verdad, tienen su propio tamano
    /// independiente de la escala del texto, y sobre todo pueden MOVERSE, porque
    /// los rectangulos viven en pixeles. Como caracteres solo podian latir de
    /// opacidad; subirlos costaba una celda entera de salto.
    private func emitDots(boxRows: Int, time: Float, alpha: Float) {
        guard alpha > 0.002 else { return }
        let ch = Float(max(cellHeight, 1))
        let cw = Float(max(cellWidth, 1))
        // El diametro sale del ALTO DE LA LETRA por el multiplicador, no de la
        // celda: asi los puntos miden lo mismo que las letras a cualquier escala
        // y el conjunto queda parejo.
        let size = max(typingSize, 0.1) * inkHeight * Float(max(scale, 1)) * ch
        let step = size * 1.6

        // Alineados con el TEXTO y no con el borde del globo: arrancan donde
        // arranca la primera letra —o sea despues del margen interno— y quedan
        // centrados en el renglon de mas abajo, que es donde va a leerse el
        // mensaje. Alineandolos con el globo, los puntos aparecian corridos
        // respecto del texto que venia despues y el salto se notaba.
        let step2 = Float(max(scale, 1))
        let baseX = Float(marginLeft + padX) * step2 * cw

        // Renglon inferior del mensaje que viene: el globo llega hasta
        // `marginBottom`, y adentro el texto deja `padY` renglones de aire.
        let textRow = Float(boxRows - marginBottom - padY - 1)
        let rowHeight = step2 * ch
        // Centrados en la TINTA del renglon, que es donde el ojo ve el texto.
        let inkMiddle = textRow * rowHeight + (inkTop + inkHeight * 0.5) * rowHeight
        let baseY = inkMiddle - size * 0.5
        emitDotsAt(x: baseX, y: baseY, size: size, time: time, alpha: alpha)
    }

    /// Los tres circulos en una posicion dada, en pixeles.
    private func emitDotsAt(x: Float, y: Float, size: Float, time: Float, alpha: Float) {
        guard alpha > 0.002 else { return }
        let step = size * 1.6
        for i in 0..<3 {
            guard rects.count < ChatLayer.maxRects else { return }
            let phase = time * max(typingSpeed, 0.05) - Float(i) * 0.33
            let wave = 0.5 - 0.5 * cos((phase - phase.rounded(.down)) * 2 * .pi)
            // Sube y baja medio diametro, y ademas late: las dos cosas juntas es
            // lo que hace que se lea como una onda recorriendolos.
            let lift = wave * size * 0.5
            rects.append(ASCIIRTChatRect(
                origin: SIMD2(x + Float(i) * step, y - lift),
                size: SIMD2(size, size),
                radius: size * 0.5,
                alpha: alpha * (0.35 + 0.65 * wave),
                _pad0: 0, _pad1: 0))
        }
    }

    /// Terminal: un renglon centrado que se escribe caracter por caracter, con
    /// un cursor que parpadea al final.
    ///
    /// No lleva globo: el texto va directo sobre lo que haya detras — el ojo, la
    /// camara, lo que sea. Por eso tampoco se alinea a un margen sino que se
    /// centra: sin caja que lo ancle, un texto pegado a la izquierda se lee como
    /// que quedo suelto, y centrado se lee como que el sistema esta hablando.
    private func layoutTerminal(texts: [String], boxCols: Int, boxRows: Int,
                                rawClock: Float, hold: Float, pauseTime: Float,
                                innerWidth: Int, typing: Float) -> [Balloon] {
        pixelOffset = 0

        // Cada mensaje dura LO QUE TARDA EN ESCRIBIRSE mas la permanencia, asi
        // que el ciclo es distinto para cada uno y no se puede dividir el reloj
        // por un periodo fijo: hay que recorrer la linea de tiempo acumulando.
        //
        // Medirlo con un periodo unico hacia que un mensaje largo se comiera su
        // propia permanencia — terminaba de escribirse y desaparecia— mientras
        // uno corto se quedaba una eternidad. La permanencia tiene que ser tiempo
        // de lectura, y el de lectura no depende de lo que tardo en aparecer.
        var durations: [Float] = []
        var wrapped: [[String]] = []
        for text in texts {
            let ls = wrap(text, width: innerWidth)
            let chars = Float(ls.reduce(0) { $0 + $1.count })
            wrapped.append(ls)
            durations.append(typing + chars / max(typeSpeed, 1) + hold + pauseTime)
        }
        let total = durations.reduce(0, +)
        var clock = rawClock
        if loops && total > 0 { clock = clock.truncatingRemainder(dividingBy: total) }

        var index = 0
        var raw = clock
        while index < durations.count - 1 && raw >= durations[index] {
            raw -= durations[index]
            index += 1
        }

        let lines = wrapped[index]
        let writeTime = Float(lines.reduce(0) { $0 + $1.count }) / max(typeSpeed, 1)
        let visibleFor = writeTime + hold
        let originYRow = max(min(Int(terminalY * Float(boxRows)), boxRows - lines.count), 0)

        // Los puntitos piensan ANTES de escribir, centrados en el mismo renglon
        // donde va a aparecer el texto.
        if typing > 0, raw < typing {
            let stepF = Float(max(scale, 1))
            let ch = Float(max(cellHeight, 1))
            let cw = Float(max(cellWidth, 1))
            let rowH = stepF * ch
            let size = max(typingSize, 0.1) * inkHeight * rowH
            // Ancho total de los tres: dos separaciones de 1.6 diametros mas el
            // ultimo circulo. Restarlo del ancho de pantalla y dividir por dos es
            // lo que los deja centrados de verdad.
            let ancho = size * 1.6 * 2 + size
            let inkMiddle = Float(originYRow) * rowH + (inkTop + inkHeight * 0.5) * rowH
            emitDotsAt(x: (Float(boxCols) * stepF * cw - ancho) * 0.5,
                       y: inkMiddle - size * 0.5,
                       size: size, time: clock,
                       alpha: min(raw / max(fadeIn, 0.01), 1)
                            * min((typing - raw) / max(fadeOut, 0.01), 1))
            return []
        }
        let age = raw - typing
        guard age <= visibleFor else { return [] }

        // El tipeado se mide en caracteres por segundo y no en una duracion:
        // asi un mensaje largo tarda mas que uno corto, que es lo que hace una
        // terminal de verdad. Con una duracion fija, los largos salen disparados.
        let charCount = lines.reduce(0) { $0 + $1.count }
        let revealed = min(Int(age * max(typeSpeed, 1)), charCount)

        let width = lines.map(\.count).max() ?? 0
        let originX = max((boxCols - width) / 2, 0)
        let originY = originYRow

        emitCursor(lines: lines, revealed: revealed, originX: originX, originY: originY,
                   time: clock)

        return [Balloon(lines: lines, width: width, height: lines.count,
                        originX: originX, originY: originY,
                        alpha: 1, revealed: revealed)]
    }

    /// Cursor de bloque despues del ultimo caracter escrito.
    private func emitCursor(lines: [String], revealed: Int,
                            originX: Int, originY: Int, time: Float) {
        guard rects.count < ChatLayer.maxRects else { return }
        let blink = time * max(cursorBlink, 0.05)
        guard blink - blink.rounded(.down) < 0.55 else { return }

        // En que renglon y columna quedo el cursor.
        var left = revealed
        var row = 0
        for (i, line) in lines.enumerated() {
            row = i
            if left <= line.count { break }
            left -= line.count
        }
        let column = min(left, lines[row].count)

        let stepF = Float(max(scale, 1))
        let cw = Float(max(cellWidth, 1))
        let ch = Float(max(cellHeight, 1))
        // Alto y posicion contra la TINTA, no contra la celda. Los dos valores
        // salen medidos del atlas, asi que el cursor calza con la letra en
        // cualquier fuente y a cualquier escala.
        let rowH = stepF * ch
        let w = max(cursorWidth, 0.05) * stepF * cw
        let h = inkHeight * rowH

        rects.append(ASCIIRTChatRect(
            origin: SIMD2(Float(originX + column) * stepF * cw,
                          Float(originY + row) * rowH + inkTop * rowH),
            size: SIMD2(w, h), radius: 0, alpha: 1, _pad0: 0, _pad1: 0))
    }

    // MARK: - Pintado

    private func paint(_ balloon: Balloon, atlas: TextAtlas,
                       boxCols: Int, boxRows: Int, step: Int, cols: Int, rows: Int) {
        let alpha = UInt8(max(0, min(255, Int(balloon.alpha * 255))))
        guard alpha > 0 else { return }

        // En terminal no hay caja, asi que el margen interno vertical no aplica:
        // sumandolo, el texto bajaba `padY` renglones y el cursor —que se ubica
        // contra el renglon pelado— quedaba flotando arriba. Era eso y no la
        // altura de la letra.
        let vpad = style == .terminal ? 0 : padY

        var written = 0
        for (row, line) in balloon.lines.enumerated() {
            let by = balloon.originY + vpad + row
            guard by >= 0, by < boxRows else { continue }
            let indent = style == .terminal ? (balloon.width - line.count) / 2 : padX
            for (column, character) in line.enumerated() {
                let bx = balloon.originX + indent + column
                guard bx >= 0, bx < boxCols else { continue }
                written += 1
                guard written <= balloon.revealed else { break }
                let index = atlas.index(of: character)

                stamp(box: SIMD2(bx, by), char: index, alpha: alpha,
                      step: step, cols: cols, rows: rows)
            }
            if written > balloon.revealed { break }
        }

        // El fondo ya no se pinta aca: se emite como rectangulo en pixeles y lo
        // resuelve el shader. Lo unico que queda en la textura es el texto.
        // En terminal no hay fondo: el texto va directo sobre la imagen.
        if style != .terminal { emitRect(balloon, step: step) }
    }

    /// Rectangulo del globo —y del piquito— en pixeles de salida.
    private func emitRect(_ balloon: Balloon, step: Int) {
        guard rects.count < ChatLayer.maxRects, balloon.alpha > 0.002 else { return }
        let cw = Float(max(cellWidth, 1))
        let ch = Float(max(cellHeight, 1))
        let origin = SIMD2<Float>(Float(balloon.originX * step) * cw,
                                  Float(balloon.originY * step) * ch)
        let size = SIMD2<Float>(Float(balloon.width * step) * cw,
                                Float(balloon.height * step) * ch)
        let radius = shape == .rounded
            ? min(max(corner, 0), 1) * min(size.x, size.y) * 0.5
            : 0
        rects.append(ASCIIRTChatRect(origin: origin, size: size,
                                     radius: radius, alpha: balloon.alpha,
                                     _pad0: 0, _pad1: 0))

        // Piquito: un rectangulo chico debajo del borde, con una punta redondeada
        // del mismo radio para que se lea como parte del globo y no como un
        // cuadradito pegado.
        guard tail, rects.count < ChatLayer.maxRects else { return }
        // Arranca DENTRO del globo y baja: si empezara en el borde, con el radio
        // alto quedaria colgando de la curva en vez de saliendo de ella.
        let tailW = cw * Float(step) * 1.5
        let tailH = ch * Float(step) * 1.5
        rects.append(ASCIIRTChatRect(
            origin: SIMD2(origin.x + cw * Float(step) * 1.0,
                          origin.y + size.y - tailH * 0.55),
            size: SIMD2(tailW, tailH),
            radius: min(tailW, tailH) * 0.35, alpha: balloon.alpha,
            _pad0: 0, _pad1: 0))
    }


    /// Pinta el fondo de UNA celda, sin tocar el caracter que pueda haber.
    private func stampCell(x: Int, y: Int, alpha: UInt8, cols: Int, rows: Int) {
        guard x >= 0, x < cols, y >= 0, y < rows else { return }
        let offset = (y * cols + x) * 2
        if buffer[offset + 1] == 0 { buffer[offset + 1] = alpha }
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
