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
struct EyeMotion {

    /// Adonde quiere ir. Lo escribe el mouse o el centro por defecto.
    var target = SIMD2<Float>(0.5, 0.5)

    /// Que tan fuerte tira el resorte. Alto = va derecho y rapido.
    var stiffness: Float = 18

    /// Rozamiento. Por debajo de `2·sqrt(stiffness)` el sistema esta
    /// subamortiguado y sobrepasa el objetivo antes de asentarse; por encima
    /// llega lento y sin rebote. El default queda apenas del lado del rebote.
    var damping: Float = 5.5

    /// Vagabundeo lento del objetivo cuando nadie lo toca.
    var driftAmount: Float = 0.004
    var driftSpeed: Float = 0.25

    private(set) var position = SIMD2<Float>(0.5, 0.5)
    private var velocity = SIMD2<Float>(0, 0)

    /// Suma de senos y no ruido: es periodica, asi que cuando agreguemos loop
    /// sin costura alcanza con cuantizar las frecuencias.
    private func drift(at time: Float) -> SIMD2<Float> {
        let t = time * driftSpeed
        return SIMD2(sin(t * 0.37) * 0.6 + sin(t * 0.83) * 0.4,
                     cos(t * 0.29) * 0.6 + cos(t * 0.71) * 0.4) * driftAmount
    }

    /// Integra un frame. `time` alimenta la deriva; en offline viene del indice
    /// de frame, asi que el resultado es reproducible entre corridas.
    mutating func step(deltaTime: Float, time: Float) {
        let goal = target + drift(at: time)

        // Un hitch de render puede dar un dt enorme y un resorte explicita en un
        // solo paso grande. Se acota y se subdivide en pasos chicos: cuesta
        // nada y el sistema no puede volarse.
        let clamped = min(max(deltaTime, 0), 0.1)
        let steps = max(Int((clamped / 0.008).rounded(.up)), 1)
        let h = clamped / Float(steps)

        for _ in 0..<steps {
            // Euler semi-implicito: se actualiza la velocidad primero y la
            // posicion con la velocidad nueva. Es incondicionalmente mas estable
            // que el explicito para un resorte, al mismo costo.
            let acceleration = (goal - position) * stiffness - velocity * damping
            velocity += acceleration * h
            position += velocity * h
        }
    }

    /// Salto instantaneo, sin fisica. Para "Centrar" y para no arrastrar
    /// velocidad de una sesion anterior al cargar un preset.
    mutating func snap(to point: SIMD2<Float>) {
        target = point
        position = point
        velocity = .zero
    }
}
