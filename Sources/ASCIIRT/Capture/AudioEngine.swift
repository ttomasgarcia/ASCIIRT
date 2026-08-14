import Accelerate
import CoreAudio
import AVFoundation
import Foundation
import Metal

/// Captura de audio para la fuente Audio.
///
/// Toma el micrófono del sistema con AVAudioEngine y deja lista, cada frame, una
/// textura de 1 x N con la forma de onda ya suavizada. El shader la lee como un
/// arreglo: no hay geometría que subir ni buffers que sincronizar.
///
/// **Por qué el micrófono y no el audio del sistema:** macOS no deja capturar la
/// salida sin un dispositivo virtual de por medio (BlackHole, Loopback) o sin
/// ScreenCaptureKit y su permiso de grabación de pantalla. El micrófono funciona
/// con parlantes en la sala, que es el caso de un vivo, y si alguien instala un
/// dispositivo virtual aparece en la lista de entradas como cualquier otro.
final class AudioEngine {

    /// Muestras que ve el shader. Potencia de dos por el FFT, y 512 alcanza:
    /// la onda se dibuja sobre una grilla de doscientas y pico de celdas, así
    /// que más resolución no llega a verse.
    static let bins = 512

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    /// Onda en el dominio del tiempo, en -1..1, ya reducida a `bins`.
    private var wave = [Float](repeating: 0, count: AudioEngine.bins)
    /// Espectro en 0..1, una banda por bin.
    private var spectrum = [Float](repeating: 0, count: AudioEngine.bins)
    /// Nivel general en 0..1 y las tres bandas clásicas.
    private var levels = SIMD4<Float>(repeating: 0)

    /// Suavizado temporal. Sin esto la onda tiembla cuadro a cuadro y el ASCII
    /// —que cuantiza a celdas— lo convierte en un hervidero ilegible.
    var smoothing: Float = 0.5
    var gain: Float = 1

    private(set) var isRunning = false

    // El FFT se arma una vez: crearlo por frame cuesta más que la transformada.
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    private var texture: MTLTexture?

    init() {
        let log2n = vDSP_Length(log2(Float(AudioEngine.bins * 2)))
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self,
                             usingSequence: .hanningDenormalized,
                             count: AudioEngine.bins * 2,
                             isHalfWindow: false)
    }

    // MARK: - Dispositivos

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    /// Cuál entrada usar. `nil` = la que tenga puesta el sistema.
    ///
    /// Hace falta elegirla explícitamente: la entrada por defecto suele ser un
    /// dispositivo que existe pero no está entregando nada —unos AirPods
    /// guardados, un Zoom o Teams virtual— y eso se ve exactamente igual que un
    /// bug: onda plana, nivel cero y ningún error.
    var deviceID: AudioDeviceID?

    /// Entradas con canales de entrada reales. Un dispositivo virtual de
    /// loopback aparece acá como cualquier otro micrófono, que es justo lo que
    /// hace falta para tomar el audio del sistema.
    static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannels(of: id) > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil,
                                             &nameSize, &name) == noErr else { return nil }
            return Device(id: id, name: name as String)
        }
    }

    /// Un dispositivo de salida pura tiene cero canales de entrada; sin este
    /// filtro los parlantes aparecen en la lista de micrófonos.
    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// El dispositivo que el sistema tiene puesto como entrada.
    static func defaultDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    // MARK: - Ciclo

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode

        // El dispositivo se fija ANTES de leer el formato: cambiarlo despues
        // deja el tap armado con la tasa de muestreo del anterior.
        if let deviceID {
            do { try input.auAudioUnit.setDeviceID(deviceID) }
            catch {
                throw AppError(.capture, "No se pudo usar esa entrada de audio.",
                               detail: error.localizedDescription)
            }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError(.capture, "No hay entrada de audio disponible.",
                           detail: "Elegí un dispositivo de entrada en Ajustes del Sistema › Sonido.")
        }

        // El tamaño del buffer lo decide el sistema; se pide el doble de bins
        // para que cada tap alcance a llenar una ventana entera de FFT.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioEngine.bins * 2),
                         format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AppError(.capture, "No se pudo arrancar la captura de audio.",
                           detail: error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        // Dejar el estado en cero, no congelado: una onda quieta a mitad de
        // camino se lee como que la captura sigue viva.
        lock.lock()
        wave = [Float](repeating: 0, count: AudioEngine.bins)
        spectrum = [Float](repeating: 0, count: AudioEngine.bins)
        levels = SIMD4(repeating: 0)
        lock.unlock()
    }

    // MARK: - Análisis

    /// Corre en el hilo de audio: sin locks largos, sin allocaciones grandes y
    /// sin tocar nada de UI.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let n = AudioEngine.bins
        var frame = [Float](repeating: 0, count: n * 2)

        // Se toma la ventana MÁS RECIENTE del buffer, no un promedio de todo:
        // promediar corre la onda hacia atrás y la deja fuera de sincronía con
        // lo que se escucha.
        let take = min(count, n * 2)
        let offset = count - take
        for i in 0..<take { frame[n * 2 - take + i] = channel[offset + i] }

        // Onda: se reduce a `bins` tomando el pico de cada tramo. El promedio
        // aplasta la forma —los cruces por cero se comen los picos— y la onda
        // sale como una línea recta apenas hay contenido agudo.
        var reduced = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = frame[i * 2], b = frame[i * 2 + 1]
            reduced[i] = abs(a) > abs(b) ? a : b
        }

        // Espectro.
        var windowed = [Float](repeating: 0, count: n * 2)
        vDSP.multiply(frame, window, result: &windowed)

        var realIn = [Float](repeating: 0, count: n)
        var imagIn = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: n)
        var imagOut = [Float](repeating: 0, count: n)
        var magnitudes = [Float](repeating: 0, count: n)

        windowed.withUnsafeBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) { complex in
                realIn.withUnsafeMutableBufferPointer { re in
                    imagIn.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n))
                    }
                }
            }
        }

        realIn.withUnsafeMutableBufferPointer { re in
            imagIn.withUnsafeMutableBufferPointer { im in
                realOut.withUnsafeMutableBufferPointer { ore in
                    imagOut.withUnsafeMutableBufferPointer { oim in
                        let input = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        var output = DSPSplitComplex(realp: ore.baseAddress!, imagp: oim.baseAddress!)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }

        realOut.withUnsafeMutableBufferPointer { re in
            imagOut.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n))
            }
        }

        // A decibeles y normalizado. Lineal, el espectro de música real es casi
        // todo grave y las barras agudas no se mueven nunca.
        let scale = 2.0 / Float(n)
        for i in 0..<n {
            let db = 20 * log10(max(magnitudes[i] * scale, 1e-7))
            magnitudes[i] = min(max((db + 72) / 72, 0), 1)
        }

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n * 2))

        func band(_ from: Int, _ to: Int) -> Float {
            let slice = magnitudes[from..<min(to, n)]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
        }
        // Cortes por octavas aproximadas a 48 kHz: el bin i cubre i * sr / 2n Hz.
        let nuevo = SIMD4<Float>(min(rms * 4, 1), band(0, 12), band(12, 80), band(80, n))

        lock.lock()
        let k = min(max(smoothing, 0), 0.98)
        for i in 0..<n {
            wave[i] = wave[i] * k + reduced[i] * (1 - k)
            spectrum[i] = spectrum[i] * k + magnitudes[i] * (1 - k)
        }
        levels = levels * k + nuevo * (1 - k)
        lock.unlock()
    }

    // MARK: - Salida a la GPU

    /// Nivel general y bandas, para que la CPU pueda modular parámetros.
    var currentLevels: SIMD4<Float> {
        lock.lock(); defer { lock.unlock() }
        return levels
    }

    /// Textura RG32Float de 1 x bins: canal R la onda, canal G el espectro.
    ///
    /// Va en una sola textura porque los dos los necesita el mismo kernel y una
    /// segunda textura sería otro bind por frame para 4 KB de datos.
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        if texture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg32Float, width: AudioEngine.bins, height: 1, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture else { return nil }

        lock.lock()
        var packed = [Float](repeating: 0, count: AudioEngine.bins * 2)
        for i in 0..<AudioEngine.bins {
            packed[i * 2] = wave[i] * max(gain, 0)
            packed[i * 2 + 1] = spectrum[i] * max(gain, 0)
        }
        lock.unlock()

        packed.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, AudioEngine.bins, 1),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: AudioEngine.bins * 2 * MemoryLayout<Float>.size)
        }
        return texture
    }
}
