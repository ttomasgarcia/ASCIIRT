import Foundation
import simd

/// Fisica de la posicion del ojo: resorte amortiguado hacia un objetivo.
///
/// El mouse no mueve el ojo, mueve el OBJETIVO. Sin eso el movimiento se lee
/// como lo que es — un cursor — porque arranca y frena instantaneo, y ningun
/// ojo hace eso. Con resorte hay aceleracion al salir, inercia al llegar y, si
/// esta subamortiguado, un pequeno rebote al asentarse. Ese rebote es la mayor
/// parte de la sensacion de que algo esta vivo.
///
/// Vive en CPU y no en el shader porque necesita estado entre frames. La deriva
/// pasa por el mismo resorte en vez de sumarse aparte: si se sumara directo al
/// centro tendria movimiento instantaneo mientras el resto tiene inercia, y se
/// notaria la diferencia.
/// Como recorre la pantalla. Todos los modos son funciones puras del tiempo,
/// sin estado: eso los hace reproducibles en el render offline y evita tener que
/// rebobinar nada al hacer scrub.
enum GazeMode: UInt32, CaseIterable, Identifiable {
    case fixed = 0      // quieto donde lo dejaste
    case drift = 1      // vagabundeo suave
    case sweep = 2      // barrido continuo
    case saccade = 3    // saltos a puntos al azar, con pausa
    case scan = 4       // recorrido sistematico de la fila, en zigzag
    case orbit = 5      // circulo

    var id: UInt32 { rawValue }

    var label: String {
        switch self {
        case .fixed: return "Quieto"
        case .drift: return "Deriva"
        case .sweep: return "Barrido"
        case .saccade: return "Saltos"
        case .scan: return "Escaneo"
        case .orbit: return "Órbita"
        }
    }
}

struct EyeMotion {

    /// Punto base. Lo escribe el mouse; la mirada se suma encima.
    var target = SIMD2<Float>(0.5, 0.5)

    // MARK: Mirada

    var gazeMode: GazeMode = .fixed
    /// Barridos o saltos por segundo.
    var gazeRate: Float = 0.25
    /// Cuanto se aleja del punto base. Separado por eje porque un publico es
    /// ancho y bajo: barrer en x mucho mas que en y es lo que hace que parezca
    /// que recorre butacas y no que flota.
    var gazeExtent = SIMD2<Float>(0.22, 0.05)
    /// Fraccion del intervalo que se queda quieto antes de moverse, en los modos
    /// por pasos. Sin pausa un escaneo se lee como un pendulo.
    var gazeHold: Float = 0.55
    /// Cuantas posiciones recorre un escaneo antes de volver.
    var gazeStops: Float = 7

    /// Que tan fuerte tira el resorte. Alto = va derecho y rapido.
    var stiffness: Float = 18

    /// Rozamiento. Por debajo de `2·sqrt(stiffness)` el sistema esta
    /// subamortiguado y sobrepasa el objetivo antes de asentarse; por encima
    /// llega lento y sin rebote. El default queda apenas del lado del rebote.
    var damping: Float = 5.5

    /// Vagabundeo lento del objetivo cuando nadie lo toca.
    var driftAmount: Float = 0.004
    var driftSpeed: Float = 0.25

    /// Mientras el usuario arrastra, la mirada no corre el ojo: el objetivo es
    /// el puntero y nada mas. Sin esto, con cualquier modo que no sea Quieto el
    /// ojo aparece desplazado hasta un cuarto de pantalla del cursor y parece
    /// que el arrastre esta descalibrado.
    var manualOverride = false

    /// Margen que el ojo no puede cruzar, en coordenadas normalizadas y por eje.
    /// Lo calcula el pipeline a partir del radio del halo y del aspecto de la
    /// salida, porque es el unico lugar que conoce los dos.
    var clampMargin = SIMD2<Float>(0, 0)
    var clampEnabled = true

    private(set) var position = SIMD2<Float>(0.5, 0.5)
    private var velocity = SIMD2<Float>(0, 0)

    /// Temblor de alta frecuencia y amplitud minima. Se suma SIEMPRE, encima de
    /// cualquier modo de mirada: un ojo real nunca esta perfectamente quieto, y
    /// sin esto los modos con pausa se ven congelados durante la pausa.
    ///
    /// Suma de senos y no ruido: es periodica, asi que para un loop sin costura
    /// alcanza con cuantizar las frecuencias.
    private func tremor(at time: Float) -> SIMD2<Float> {
        let t = time * driftSpeed
        guard loopPeriod > 0 else {
            return SIMD2(sin(t * 0.37) * 0.6 + sin(t * 0.83) * 0.4,
                         cos(t * 0.29) * 0.6 + cos(t * 0.71) * 0.4) * driftAmount
        }
        // Se cuantiza el ritmo COMPUESTO —driftSpeed por cada constante— y no
        // driftSpeed solo: lo que tiene que cerrar es cada seno, y con un unico
        // factor comun los cuatro no pueden cerrar a la vez.
        let tau = Float.pi * 2
        let f = [0.37, 0.83, 0.29, 0.71].map { (k: Float) in
            snap(driftSpeed * k / tau, floor: 0) * tau
        }
        return SIMD2(sin(time * f[0]) * 0.6 + sin(time * f[1]) * 0.4,
                     cos(time * f[2]) * 0.6 + cos(time * f[3]) * 0.4) * driftAmount
    }

    /// Periodo del loop en segundos; 0 = sin loop.
    var loopPeriod: Float = 0

    /// Redondea una frecuencia (en ciclos por segundo) para que entre un numero
    /// entero de ciclos en el periodo del loop.
    ///
    /// `floor` es el minimo de ciclos admitido. Para el temblor es 0 —una
    /// oscilacion mas lenta que el loop entero no puede cerrar, y dejarla quieta
    /// no se nota a esa amplitud— pero para la mirada es 1: congelar el recorrido
    /// del ojo porque no llegaba a completar una vuelta seria peor que acelerarlo
    /// hasta que complete una.
    private func snap(_ rate: Float, floor minimum: Float) -> Float {
        guard loopPeriod > 0 else { return rate }
        return max(minimum, (rate * loopPeriod).rounded()) / loopPeriod
    }

    /// El ritmo de los modos por pasos. En `scan` el recorrido completo son
    /// `2 * stops` pasos —ida y vuelta—, asi que no alcanza con que entren pasos
    /// enteros en el loop: tienen que entrar zigzags enteros.
    private func steppedRate(stops: Float?) -> Float {
        guard loopPeriod > 0 else { return gazeRate }
        let steps = max(1, (gazeRate * loopPeriod).rounded())
        guard let stops else { return steps / loopPeriod }
        let block = max(2 * stops, 2)
        return max(block, (steps / block).rounded() * block) / loopPeriod
    }

    /// Hash determinista para los modos por pasos. No necesita calidad; lo unico
    /// que importa es que dependa solo del indice de paso, para que el render
    /// offline de exactamente la misma secuencia de miradas.
    private func hash(_ n: Float) -> Float {
        let x = sin(n * 127.1 + 311.7) * 43758.5453
        return x - x.rounded(.down)
    }

    /// Desplazamiento de la mirada respecto del punto base.
    private func gaze(at time: Float) -> SIMD2<Float> {
        let tau = Float.pi * 2

        switch gazeMode {
        case .fixed:
            return .zero

        case .drift:
            let f = [0.31, 0.73, 0.23, 0.61].map { (k: Float) in
                snap(gazeRate * k, floor: 1) * tau
            }
            return SIMD2(sin(time * f[0]) * 0.7 + sin(time * f[1]) * 0.3,
                         cos(time * f[2]) * 0.7 + cos(time * f[3]) * 0.3) * gazeExtent

        case .sweep:
            // La y va a la mitad de frecuencia y desfasada: sin eso el recorrido
            // es una linea recta de ida y vuelta.
            return SIMD2(sin(time * snap(gazeRate, floor: 1) * tau),
                         sin(time * snap(gazeRate * 0.5, floor: 1) * tau + 1.3)) * gazeExtent

        case .saccade:
            // El objetivo salta en cada paso y se queda quieto hasta el
            // siguiente; el resorte se encarga del viaje. La pausa sale sola de
            // que el objetivo sea constante dentro del paso.
            let step = (time * steppedRate(stops: nil)).rounded(.down)
            return SIMD2(hash(step) * 2 - 1, hash(step + 91.7) * 2 - 1) * gazeExtent

        case .scan:
            // Recorrido sistematico de izquierda a derecha y vuelta en zigzag,
            // como quien pasa la vista por una fila de butacas.
            let stops = max(gazeStops, 2)
            let step = (time * steppedRate(stops: stops)).rounded(.down)
            let index = step - (step / stops).rounded(.down) * stops
            let cycle = (step / stops).rounded(.down)
            let forward = cycle - (cycle / 2).rounded(.down) * 2 < 1
            let position = index / (stops - 1)
            let x = forward ? position : 1 - position
            return SIMD2((x * 2 - 1), (hash(step) * 2 - 1) * 0.35) * gazeExtent

        case .orbit:
            let t = time * snap(gazeRate, floor: 1) * tau
            return SIMD2(cos(t), sin(t)) * gazeExtent
        }
    }

    /// Integra un frame. `time` alimenta la deriva; en offline viene del indice
    /// de frame, asi que el resultado es reproducible entre corridas.
    mutating func step(deltaTime: Float, time: Float) {
        // El temblor se mantiene incluso arrastrando: es de amplitud minima y
        // sacarlo hace que el ojo se sienta muerto justo cuando lo estas tocando.
        let goal = target + (manualOverride ? .zero : gaze(at: time)) + tremor(at: time)

        // Un hitch de render puede dar un dt enorme y un resorte explicita en un
        // solo paso grande. Se acota y se subdivide en pasos chicos: cuesta
        // nada y el sistema no puede volarse.
        let clamped = min(max(deltaTime, 0), 0.1)
        let steps = max(Int((clamped / 0.008).rounded(.up)), 1)
        let h = clamped / Float(steps)

        // El objetivo tambien se acota: si el resorte apuntara afuera, el ojo
        // quedaria empujando contra la pared todo el tiempo y el temblor se
        // aplastaria contra el borde en vez de leerse.
        let bounded = clampEnabled ? clamp(goal) : goal

        for _ in 0..<steps {
            // Euler semi-implicito: se actualiza la velocidad primero y la
            // posicion con la velocidad nueva. Es incondicionalmente mas estable
            // que el explicito para un resorte, al mismo costo.
            let acceleration = (bounded - position) * stiffness - velocity * damping
            velocity += acceleration * h
            position += velocity * h

            guard clampEnabled else { continue }
            // Ademas de acotar el objetivo hay que acotar la posicion: con poca
            // amortiguacion el sobrepaso se pasa igual del limite. Al chocar se
            // anula la velocidad de ese eje nada mas, asi que el ojo puede seguir
            // deslizandose a lo largo del borde en vez de frenar en seco.
            let limited = clamp(position)
            if limited.x != position.x { velocity.x = 0 }
            if limited.y != position.y { velocity.y = 0 }
            position = limited
        }
    }

    /// Acota un punto al rectangulo util. Si el margen pedido no entra —halo mas
    /// grande que media pantalla— el eje queda clavado al centro, que es la
    /// consecuencia honesta de la regla: con un halo asi el ojo no se puede mover
    /// sin que el campo se salga de cuadro.
    private func clamp(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let mx = min(clampMargin.x, 0.5)
        let my = min(clampMargin.y, 0.5)
        return SIMD2(min(max(point.x, mx), 1 - mx),
                     min(max(point.y, my), 1 - my))
    }

    /// Salto instantaneo, sin fisica. Para "Centrar" y para no arrastrar
    /// velocidad de una sesion anterior al cargar un preset.
    mutating func snap(to point: SIMD2<Float>) {
        target = point
        position = point
        velocity = .zero
    }
}
