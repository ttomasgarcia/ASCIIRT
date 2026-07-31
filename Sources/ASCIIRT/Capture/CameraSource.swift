import AVFoundation
import CoreMedia
import Foundation

/// Descripcion estable de una camara para la UI (no retenemos AVCaptureDevice
/// en el modelo: los dispositivos se conectan y desconectan).
struct CameraInfo: Identifiable, Hashable {
    let id: String       // uniqueID
    let name: String
}

/// AVCaptureSession envuelto. Entrega CVPixelBuffer BGRA en una cola propia.
///
/// El formato de salida es BGRA y no 420v/YpCbCr a proposito: aunque el YUV nos
/// daria la luma gratis en el plano Y, ese plano viene con rango de video
/// (16-235) y matriz dependiente del formato de captura. Convertir de BGRA con
/// Rec.709 en la etapa [1] es un multiply-add en GPU y deja el pipeline igual
/// para camara y para archivo.
final class CameraSource: NSObject, FrameSource {
    weak var delegate: FrameSourceDelegate?

    /// Se llama en main cuando cambia el dispositivo: no todas las camaras
    /// soportan lock, y un control que no hace nada es peor que uno ausente.
    var onExposureLockSupport: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    /// Cola serial dedicada: los callbacks de AVFoundation no deben tocar main,
    /// y una cola propia evita competir con el resto del sistema.
    private let captureQueue = DispatchQueue(label: "asciirt.capture", qos: .userInitiated)

    private var currentInput: AVCaptureDeviceInput?
    private(set) var currentDevice: AVCaptureDevice?
    private(set) var format: FormatDescription?

    // MARK: - Enumeracion

    static func availableCameras() -> [CameraInfo] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera,
            .deskViewCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        return discovery.devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    // MARK: - Permisos

    /// Devuelve true si quedamos autorizados. `.denied`/`.restricted` no se
    /// pueden revertir desde la app: hay que mandar al usuario a Ajustes.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    // MARK: - Ciclo de vida

    func start(deviceID: String?) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configure(deviceID: deviceID)
                if !self.session.isRunning { self.session.startRunning() }
            } catch let error as AppError {
                self.delegate?.frameSource(self, didFail: error)
            } catch {
                self.delegate?.frameSource(self, didFail: AppError(.capture, "Fallo al iniciar la captura.", underlying: error))
            }
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure(deviceID: String?) throws {
        let device: AVCaptureDevice
        if let deviceID, let found = AVCaptureDevice(uniqueID: deviceID) {
            device = found
        } else if let fallback = AVCaptureDevice.default(for: .video) {
            device = fallback
        } else {
            throw AppError(.capture, "No se encontro ninguna camara conectada.")
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        // 1080p es el default de trabajo (criterio de aceptacion: 1080p60 sin drops).
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AppError(.capture, "No se pudo abrir «\(device.localizedName)».", underlying: error)
        }
        guard session.canAddInput(input) else {
            throw AppError(.capture, "La sesion rechazo la entrada de «\(device.localizedName)».")
        }
        session.addInput(input)
        currentInput = input
        currentDevice = device

        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // En Live preferimos frescura sobre completitud: si la GPU no llega,
            // el frame viejo se tira (spec §6).
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else {
                throw AppError(.capture, "La sesion rechazo la salida de video.")
            }
            session.addOutput(output)
        }

        publishFormat(for: device)

        let supported = device.isExposureModeSupported(.locked)
                     && device.isWhiteBalanceModeSupported(.locked)
        DispatchQueue.main.async { [weak self] in
            self?.onExposureLockSupport?(supported)
        }
    }

    /// Spec §4a: congelar exposicion y balance de blancos en el hardware. Es la
    /// mitad de la solucion al hervor de la rampa; la otra es la normalizacion
    /// en pipeline, que corrige lo que el AGC ya movio.
    func setExposureLocked(_ locked: Bool) {
        captureQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
                if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }

                let balance: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
                if device.isWhiteBalanceModeSupported(balance) { device.whiteBalanceMode = balance }
            } catch {
                self.delegate?.frameSource(self, didFail: AppError(
                    .capture, "No se pudo bloquear la exposicion.", underlying: error))
            }
        }
    }

    private func publishFormat(for device: AVCaptureDevice) {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let duration = device.activeVideoMinFrameDuration
        let fps = duration.seconds > 0 ? 1.0 / duration.seconds : 0
        let described = FormatDescription(width: Int(dims.width), height: Int(dims.height), fps: fps)
        format = described
        delegate?.frameSource(self, didChangeFormat: described)
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.frameSource(self, didOutput: pixelBuffer, at: pts)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // M6 muestra esto en la UI; por ahora solo interesa que no sea silencioso
        // a nivel de diseno (el contador vive en FrameRenderer).
    }
}
