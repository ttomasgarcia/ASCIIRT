import AppKit
import Foundation
import Metal
import MetalKit
import CoreMedia
import CoreVideo
import QuartzCore
import ShaderTypes

/// Contadores de salud del preview, publicados a la UI con throttle.
struct RenderStats: Equatable {
    var displayedFPS: Double = 0
    /// Frames de camara que llegaron y fueron reemplazados por uno mas nuevo
    /// antes de llegar a dibujarse. En Live esto es aceptable (spec §6); el
    /// numero esta para que sea visible, no para alarmar.
    var droppedFrames: Int = 0

    /// Cuanto tarda la GPU en un frame, promediado.
    ///
    /// Existe porque los fps solos mienten segun la fuente: con un archivo el
    /// preview dibuja cuando llega un cuadro nuevo, asi que el contador muestra
    /// la tasa DEL VIDEO y no lo que la app da de si. Un video de 8 fps se ve
    /// como «8 fps» y parece que la app va lenta cuando en realidad esta
    /// esperando. Con el tiempo de GPU al lado se distingue de un vistazo.
    var gpuMilliseconds: Double = 0
}

/// Renderer del preview: corre el pipeline ASCII y hace la etapa [9] hacia el
/// MTKView.
///
/// El render esta manejado por la camara, no por CVDisplayLink: el MTKView vive
/// en `isPaused = true` y se le pide `draw()` cuando hay frame nuevo. Asi un
/// frame de entrada produce como maximo un frame dibujado, que es la relacion
/// que el modo offline (spec §6) va a necesitar exacta.
final class FrameRenderer: NSObject, MTKViewDelegate {
    private let context: MetalContext
    private let pipelineState: MTLRenderPipelineState
    let ascii: ASCIIPipeline

    /// Bypass total del pipeline: dibuja la camara cruda. Es la comparacion
    /// "antes/despues" y ademas deja M1 disponible para diagnosticar.
    var asciiEnabled = true

    /// Fuente sintetica: no hay frame de entrada que esperar, el pipeline genera
    /// la imagen. Va siempre con `continuousRedraw`.
    var generative = false

    /// Se consulta en cada draw en vez de empujarse desde Vision: asi el matte
    /// que entra al frame es siempre el ultimo disponible, sin sincronizacion
    /// entre la cola de Vision y el render.
    var matteProvider: (() -> MTLTexture?)?

    /// Grabacion en modo Live. Se consulta por frame; si esta grabando, el
    /// mismo command buffer que dibuja el preview escribe tambien al archivo.
    var writer: VideoWriter?

    /// Protege el intercambio de `pendingBuffer` entre la cola de captura y main.
    private let bufferLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    /// PTS del frame pendiente. Se arrastra desde la fuente porque el archivo
    /// necesita el tiempo real del material, no el momento en que se dibujo.
    private var pendingTime: CMTime = .zero
    private var lastTime: CMTime = .zero
    /// Ultimo frame dibujado. Se conserva para poder repintar sin frame nuevo:
    /// el modo Matrix anima por reloj, no por entrada, y con el video en pausa
    /// no llegaria nada que disparara un draw.
    private var lastBuffer: CVPixelBuffer?
    private var drawScheduled = false

    /// Repinta al refresco de la pantalla aunque la fuente este quieta. Lo
    /// prende el modo Matrix, que anima por reloj y no por frame de entrada.
    ///
    /// Se usa un CADisplayLink propio en vez de `MTKView.isPaused = false`: el
    /// timer interno de MTKView no arranca de forma confiable cuando la vista se
    /// crea antes de que la ventana sea key, y el sintoma es una vista negra sin
    /// un solo `draw`. Con link propio el disparo es nuestro y verificable.
    var continuousRedraw = false {
        didSet {
            guard oldValue != continuousRedraw else { return }
            if continuousRedraw {
                startRedrawLink()
            } else {
                stopRedrawLink()
                // Al volver al camino manual hay que dejar limpio el flag y
                // pedir un draw: si la fuente esta quieta, nadie mas lo haria.
                bufferLock.lock()
                drawScheduled = false
                bufferLock.unlock()
                requestRedraw()
            }
        }
    }

    private var redrawLink: CADisplayLink?

    private weak var view: MTKView?

    private var stats = RenderStats()
    private var gpuTimeSum: Double = 0
    private var gpuTimeCount = 0
    private var framesSinceTick = 0
    private var lastStatsTick = CACurrentMediaTime()
    private var lastDrawTime: CFTimeInterval?

    /// Se invoca en main. Throttleado a ~2 Hz para no hacer hervir SwiftUI.
    var onStats: ((RenderStats) -> Void)?
    var onError: ((AppError) -> Void)?

    init(context: MetalContext, ascii: ASCIIPipeline) throws {
        self.context = context
        self.ascii = ascii

        guard let vertexFn = context.library.makeFunction(name: "blitVertex"),
              let fragmentFn = context.library.makeFunction(name: "blitFragment") else {
            throw AppError(.shaders, "Faltan las funciones blitVertex/blitFragment en la libreria.")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "asciirt.blit"
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try context.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw AppError(.metal, "No se pudo crear el pipeline de blit.", underlying: error)
        }
        super.init()
    }

    func attach(to view: MTKView) {
        self.view = view
        if continuousRedraw { startRedrawLink() }
    }

    private func startRedrawLink() {
        stopRedrawLink()
        guard let screen = view?.window?.screen ?? NSScreen.main else {
            onError?(AppError(.metal, "No hay pantalla para sincronizar el repintado."))
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(redrawTick(_:)))
        // .common para que el repintado no se corte mientras se arrastra un slider.
        link.add(to: .main, forMode: .common)
        redrawLink = link
    }

    private func stopRedrawLink() {
        redrawLink?.invalidate()
        redrawLink = nil
    }

    @objc private func redrawTick(_ link: CADisplayLink) {
        view?.draw()
    }

    // MARK: - Entrada de frames (cola de captura)

    func submit(pixelBuffer: CVPixelBuffer, at time: CMTime) {
        bufferLock.lock()
        pendingTime = time
        // Si ya habia uno esperando, ese frame nunca se va a ver.
        if pendingBuffer != nil { stats.droppedFrames += 1 }
        pendingBuffer = pixelBuffer
        // `drawScheduled` es estado del camino manual. Con repintado continuo el
        // display link es el que dispara, asi que no se toca: marcarlo y salir
        // por el guard lo dejaba clavado en true, y al apagar la lluvia ya no se
        // agendaba ningun draw nunca mas — la vista quedaba congelada.
        let needsSchedule = !continuousRedraw && !drawScheduled
        if needsSchedule { drawScheduled = true }
        bufferLock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view?.draw()
            self.bufferLock.lock()
            self.drawScheduled = false
            let hasMore = self.pendingBuffer != nil
            self.bufferLock.unlock()
            // Llego otro frame mientras dibujabamos: reencolar en vez de esperar
            // al proximo submit, que podria no venir si la camara se detuvo.
            if hasMore { self.requestRedraw() }
        }
    }

    private func requestRedraw() {
        bufferLock.lock()
        guard !drawScheduled else { bufferLock.unlock(); return }
        drawScheduled = true
        bufferLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view?.draw()
            self.bufferLock.lock()
            self.drawScheduled = false
            self.bufferLock.unlock()
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // autoResizeDrawable esta en false (spec §3): el drawable lo fija el
        // modelo segun la resolucion de salida, no el tamano de la ventana.
    }

    func draw(in view: MTKView) {
        bufferLock.lock()
        let buffer = pendingBuffer ?? lastBuffer
        if pendingBuffer != nil { lastTime = pendingTime }
        pendingBuffer = nil
        lastBuffer = buffer
        let frameTime = lastTime
        bufferLock.unlock()

        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else { return }
        // En modo generativo no hay buffer y no debe haberlo: el guard de abajo
        // solo aplica cuando la imagen viene de afuera.
        guard generative || buffer != nil else { return }

        do {
            var sourceTexture: MTLTexture?
            var keepAlive: CVMetalTexture?
            if let buffer {
                (sourceTexture, keepAlive) = try context.makeTexture(from: buffer)
            }

            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                throw AppError(.metal, "No se pudo crear el command buffer del preview.")
            }
            commandBuffer.label = "asciirt.preview"

            // Etapas [1]..[8] en el mismo command buffer que el blit: una sola
            // sumision por frame, sin sincronizaciones intermedias.
            if asciiEnabled {
                // dt real entre draws: la fisica del ojo tiene que ser
                // independiente de la tasa de refresco.
                let now = CACurrentMediaTime()
                let delta = Float(now - (lastDrawTime ?? now - 1.0 / 60.0))
                lastDrawTime = now

                ascii.matteTexture = matteProvider?()
                try ascii.encode(commandBuffer: commandBuffer, source: sourceTexture, deltaTime: delta)
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                throw AppError(.metal, "No se pudo crear el render encoder del preview.")
            }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(asciiEnabled ? ascii.outputTexture : sourceTexture,
                                       index: Int(ASCIIRTTextureIndexSource.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            // Grabacion: el resultado se dibuja tambien dentro de un buffer del
            // pool del writer, en este mismo command buffer. El frame no vuelve
            // a CPU en ningun momento.
            var recordedBuffer: CVPixelBuffer?
            var recordedKeepAlive: CVMetalTexture?
            if asciiEnabled, let writer, writer.isRecording, let target = writer.dequeuePixelBuffer() {
                do {
                    let (targetTexture, targetKeepAlive) = try context.makeTexture(from: target)
                    let descriptor = MTLRenderPassDescriptor()
                    descriptor.colorAttachments[0].texture = targetTexture
                    descriptor.colorAttachments[0].loadAction = .dontCare
                    descriptor.colorAttachments[0].storeAction = .store

                    if let fileEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                        fileEncoder.setRenderPipelineState(pipelineState)
                        fileEncoder.setFragmentTexture(ascii.outputTexture,
                                                       index: Int(ASCIIRTTextureIndexSource.rawValue))
                        fileEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        fileEncoder.endEncoding()
                        recordedBuffer = target
                        recordedKeepAlive = targetKeepAlive
                    }
                } catch let error as AppError {
                    onError?(error)
                }
            }

            // El CVMetalTexture tiene que sobrevivir a la ejecucion en GPU; la
            // captura en el completion handler es lo que lo mantiene vivo.
            commandBuffer.addCompletedHandler { [weak self] buffer in
                _ = keepAlive
                _ = recordedKeepAlive
                if let recordedBuffer {
                    self?.writer?.append(recordedBuffer, at: frameTime)
                }
                // Los tiempos de GPU los llena Metal recien al completarse. El
                // handler corre en una cola interna, asi que se acumula y el
                // promedio se calcula en el tick, que ya esta en main.
                let elapsed = buffer.gpuEndTime - buffer.gpuStartTime
                if elapsed > 0 {
                    DispatchQueue.main.async {
                        self?.gpuTimeSum += elapsed * 1000
                        self?.gpuTimeCount += 1
                    }
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()

            tickStats()
        } catch let error as AppError {
            onError?(error)
        } catch {
            onError?(AppError(.metal, "Fallo el render del preview.", underlying: error))
        }
    }

    private func tickStats() {
        framesSinceTick += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastStatsTick
        guard elapsed >= 0.5 else { return }

        stats.displayedFPS = Double(framesSinceTick) / elapsed
        if gpuTimeCount > 0 {
            stats.gpuMilliseconds = gpuTimeSum / Double(gpuTimeCount)
            gpuTimeSum = 0
            gpuTimeCount = 0
        }
        framesSinceTick = 0
        lastStatsTick = now
        onStats?(stats)
    }
}
