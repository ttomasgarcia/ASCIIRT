import SwiftUI
import MetalKit

/// Puente SwiftUI -> MTKView.
///
/// Spec §3: `autoResizeDrawable = false` y drawable clavado a la resolucion de
/// salida. La ventana escala la vista (el .aspectRatio del contenedor), el
/// render nunca cambia de tamano por mover el borde de la ventana.
struct PreviewView: NSViewRepresentable {
    let context: MetalContext
    let renderer: FrameRenderer
    let drawableSize: CGSize

    func makeNSView(context nsContext: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.drawableSize = drawableSize
        // El renderer decide cuando dibujar: por frame de entrada, o por su
        // propio display link cuando el efecto anima por reloj.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderer.attach(to: view)
        return view
    }

    func updateNSView(_ view: MTKView, context nsContext: Context) {
        if view.drawableSize != drawableSize, drawableSize.width > 0, drawableSize.height > 0 {
            view.drawableSize = drawableSize
        }
    }
}
