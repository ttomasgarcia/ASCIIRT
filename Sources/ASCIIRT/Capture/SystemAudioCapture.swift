import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captura el audio que está sonando en la Mac.
///
/// Usa los **taps de proceso de Core Audio** (macOS 14.2+): se engancha un tap a
/// la salida del sistema, se arma un dispositivo agregado privado que lo tiene
/// como entrada, y se lee de ahí con un IOProc. El audio sigue sonando por los
/// parlantes — el tap escucha, no intercepta.
///
/// **Por qué no ScreenCaptureKit.** También entrega el audio del sistema, pero
/// pasa por el permiso de Grabación de pantalla: para escuchar música habría que
/// autorizar a la app a ver la pantalla, que es muchísimo más de lo que hace
/// falta. Esta vía no pide nada de eso.
///
/// **Por qué no un dispositivo de loopback.** BlackHole y Loopback funcionan, y
/// si están instalados aparecen igual en el selector de entrada. Pero hay que
/// instalarlos con contraseña de administrador y reconfigurar la salida del
/// sistema para que pase por ellos. Esto no toca nada de la máquina.
///
/// Los taps llegaron en macOS 14.2. Por debajo de eso la app sigue andando y lo
/// único que no está es este toggle, así que no justifica subir el mínimo.
@available(macOS 14.2, *)
final class SystemAudioCapture {

    /// Recibe muestras mono ya listas para analizar.
    private let onSamples: (UnsafePointer<Float>, Int) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Último error, para que el modelo pueda contar por qué no hay sonido.
    private(set) var failure: String?

    /// Buffer de mezcla reutilizado. Reservarlo por callback allocaría en el
    /// hilo de audio, que es donde no se puede.
    private var mono = [Float](repeating: 0, count: 8192)

    init(onSamples: @escaping (UnsafePointer<Float>, Int) -> Void) {
        self.onSamples = onSamples
    }

    // MARK: - Arranque

    func start() {
        do {
            try build()
            failure = nil
        } catch let error as AppError {
            failure = error.detail ?? error.message
            teardown()
        } catch {
            failure = error.localizedDescription
            teardown()
        }
    }

    private func build() throws {
        // Tap global: toda la salida, sin excluir ningún proceso. `.unmuted` es
        // lo que hace que el audio se siga escuchando mientras se lo mira.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "ASCIIRT"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr else {
            throw AppError(.capture, "No se pudo enganchar la salida de audio.",
                           detail: status(created, "crear el tap"))
        }
        tapID = tap

        // El agregado necesita un dispositivo de reloj: se usa la salida por
        // defecto, que es de donde viene el audio que se quiere escuchar.
        guard let outputUID = defaultOutputUID() else {
            throw AppError(.capture, "No se encontró la salida de audio del sistema.")
        }

        var tapUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil,
                                         &uidSize, &tapUID) == noErr else {
            throw AppError(.capture, "No se pudo identificar el tap de audio.")
        }

        // Privado: el agregado no aparece en Ajustes de Sonido ni en la lista de
        // dispositivos de otras apps. Es un detalle interno, no un dispositivo
        // que el usuario tenga que ver ni elegir.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ASCIIRT audio del sistema",
            kAudioAggregateDeviceUIDKey: "tv.tomasgarcia.asciirt.tap",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID,
                 kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var device = AudioObjectID(kAudioObjectUnknown)
        let made = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard made == noErr else {
            throw AppError(.capture, "No se pudo armar el dispositivo de captura.",
                           detail: status(made, "crear el agregado"))
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        let installed = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.receive(inputData)
        }
        guard installed == noErr, let proc else {
            throw AppError(.capture, "No se pudo instalar la lectura de audio.",
                           detail: status(installed, "crear el IOProc"))
        }
        procID = proc

        let started = AudioDeviceStart(aggregateID, proc)
        guard started == noErr else {
            // Es acá donde cae la falta de permiso: el tap se crea, el agregado
            // se arma, y recién al arrancar el sistema decide si esta app puede
            // escuchar. Se traduce a algo accionable en vez del código crudo.
            let detail = started == 1_768_910_707   // 'priv' — sin autorización
                ? "macOS no autorizó a ASCIIRT a escuchar el audio del sistema."
                : status(started, "arrancar el dispositivo")
            throw AppError(.capture, "No se pudo arrancar el audio del sistema.", detail: detail)
        }
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { teardown() }

    // MARK: - Lectura

    /// Corre en el hilo de audio de Core Audio: sin locks, sin allocaciones.
    private func receive(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }

        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(channels, 1)
        guard frames > 0, frames <= mono.count else { return }

        if channels <= 1 {
            onSamples(data, frames)
            return
        }

        // A mono. Quedarse con el canal izquierdo perdería lo que esté paneado a
        // la derecha, y la onda es una sola línea de todos modos.
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += data[i * channels + c] }
            mono[i] = sum / Float(channels)
        }
        mono.withUnsafeBufferPointer { onSamples($0.baseAddress!, frames) }
    }

    // MARK: - Auxiliares

    private func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return nil }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil,
                                         &uidSize, &uid) == noErr else { return nil }
        return uid as String
    }

    /// Los OSStatus de Core Audio son cuatro caracteres empaquetados en un
    /// entero; impresos como número no dicen nada.
    private func status(_ code: OSStatus, _ what: String) -> String {
        let value = UInt32(bitPattern: code)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((value >> $0) & 0xff))) }
        let readable = chars.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
            ? String(chars) : String(code)
        return "Falló al \(what): \(readable)."
    }
}
