import AVFoundation
import Foundation
import ScreenCaptureKit

/// Captura el audio que está sonando en la Mac, sin driver de por medio.
///
/// ScreenCaptureKit entrega el audio del sistema desde macOS 13. La alternativa
/// clásica es un dispositivo virtual de loopback —BlackHole, Loopback—, que hay
/// que instalar con contraseña de administrador; esto no necesita nada instalado,
/// solo el permiso de grabación de pantalla.
///
/// **Se pide un stream de video igual.** SCStream no tiene modo solo-audio: hay
/// que darle un filtro de pantalla. Se pide el mínimo que acepta y un cuadro cada
/// tanto, así el costo es despreciable y el frame se descarta sin mirarlo.
///
/// **Se excluye el audio propio.** Sin eso, si alguna vez la app llega a emitir
/// sonido, se escucharía a sí misma y realimentaría la onda.
final class SystemAudioCapture: NSObject, SCStreamOutput {

    /// Recibe muestras mono intercaladas ya listas para analizar.
    private let onSamples: (UnsafePointer<Float>, Int) -> Void

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "asciirt.systemaudio", qos: .userInitiated)

    /// Último error, para que el modelo pueda contar por qué no hay sonido.
    private(set) var failure: String?

    init(onSamples: @escaping (UnsafePointer<Float>, Int) -> Void) {
        self.onSamples = onSamples
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    self.failure = "No hay pantalla desde donde tomar el audio."
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                // El video es peaje, no contenido: el mínimo tamaño y un cuadro
                // cada dos segundos.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                configuration.queueDepth = 3

                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self, type: .audio,
                                           sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.stream = stream
                self.failure = nil
            } catch {
                // El rechazo de TCC llega como un error largo y en tono de
                // sistema. Se traduce a lo unico accionable: falta el permiso.
                let ns = error as NSError
                // -3801 = userDeclined. La constante no esta expuesta en Swift.
                let declined = ns.domain == SCStreamErrorDomain && ns.code == -3801
                self.failure = declined ? "permiso denegado" : error.localizedDescription
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        var listSize = 0
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: listSize, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block) == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }

        // ScreenCaptureKit entrega los canales por separado. Se suman a mono: la
        // onda es una sola línea, y quedarse con el canal izquierdo perdería lo
        // que esté paneado a la derecha.
        if buffers.count > 1, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            var mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames { mono[i] = (data[i] + second[i]) * 0.5 }
            mono.withUnsafeBufferPointer { onSamples($0.baseAddress!, frames) }
        } else {
            onSamples(data, frames)
        }
    }
}
