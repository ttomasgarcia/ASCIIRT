import AVFoundation
import AppKit
import CoreVideo
import Foundation
import QuartzCore

/// Reproduccion de archivo para el modo Live (spec §6): acoplada al reloj real,
/// con transporte. El modo offline de M7 no usa esto — usa AVAssetReader y
/// avanza frame a frame sin reloj de pared.
///
/// Los frames se sacan con AVPlayerItemVideoOutput tirado por un CADisplayLink:
/// pedir el buffer para el `targetTimestamp` del link (y no para "ahora") es lo
/// que hace que el frame que se decodifica sea el que corresponde al refresco
/// que se esta por presentar.
final class FileSource: NSObject, FrameSource {
    weak var delegate: FrameSourceDelegate?

    private let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private(set) var url: URL?
    private(set) var duration: CMTime = .zero
    private(set) var nominalFPS: Double = 0

    /// Se llaman en main.
    var onTime: ((CMTime) -> Void)?
    var onPlaybackChange: ((Bool) -> Void)?

    var isLooping = true {
        didSet { player.actionAtItemEnd = isLooping ? .none : .pause }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var isPlaying: Bool { player.rate != 0 }

    // MARK: - Carga

    func load(url: URL) async {
        stop()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                fail(AppError(.capture, "El archivo no tiene pista de video.", detail: url.lastPathComponent))
                return
            }

            let (naturalSize, transform, fps, assetDuration) = try await (
                track.load(.naturalSize),
                track.load(.preferredTransform),
                track.load(.nominalFrameRate),
                asset.load(.duration)
            )

            // Video rotado (tipico de material de telefono): el buffer sale con la
            // orientacion de codificacion. Componer aplica el preferredTransform
            // antes de que lo veamos, asi el pipeline nunca tiene que saber de
            // rotaciones. Se arma aca, fuera de main, porque construirla lee el
            // asset.
            let composition = transform.isIdentity
                ? nil
                : try await AVVideoComposition.videoComposition(withPropertiesOf: asset)

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])

            let displaySize = naturalSize.applying(transform)
            let width = Int(abs(displaySize.width).rounded())
            let height = Int(abs(displaySize.height).rounded())

            await MainActor.run {
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = composition
                item.add(output)

                self.url = url
                self.videoOutput = output
                self.duration = assetDuration
                self.nominalFPS = Double(fps)
                self.player.replaceCurrentItem(with: item)
                self.player.actionAtItemEnd = self.isLooping ? .none : .pause
                self.installObservers(for: item)
                self.startDisplayLink()
                self.delegate?.frameSource(self, didChangeFormat: FormatDescription(
                    width: width, height: height, fps: Double(fps)
                ))
                self.play()
            }
        } catch {
            fail(AppError(.capture, "No se pudo abrir «\(url.lastPathComponent)».", underlying: error))
        }
    }

    // MARK: - Transporte

    func play() {
        player.play()
        onPlaybackChange?(true)
    }

    func pause() {
        player.pause()
        onPlaybackChange?(false)
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to time: CMTime) {
        // Tolerancia cero: al hacer scrub queremos el frame exacto, no el
        // keyframe mas cercano. Es mas caro pero es lo que se espera de un
        // player de trabajo.
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        onTime?(time)
    }

    func seek(toFraction fraction: Double) {
        guard duration.isValid, duration.seconds > 0 else { return }
        seek(to: CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600))
    }

    func stop() {
        stopDisplayLink()
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        url = nil
        duration = .zero
    }

    // MARK: - Bombeo de frames

    private func startDisplayLink() {
        stopDisplayLink()
        guard let screen = NSScreen.main else {
            fail(AppError(.capture, "No hay pantalla disponible para sincronizar la reproduccion."))
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // .common para que el scrub (que corre en tracking mode) no congele el video.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// El link sigue corriendo con el player en pausa: es lo que hace que al
    /// hacer scrub detenido se vea el frame nuevo.
    @objc private func step(_ link: CADisplayLink) {
        guard let output = videoOutput else { return }
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        delegate?.frameSource(self, didOutput: buffer, at: itemTime)
    }

    // MARK: - Observadores

    private func installObservers(for item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            self?.onTime?(time)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isLooping {
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.play()
            } else {
                self.onPlaybackChange?(false)
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func fail(_ error: AppError) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.frameSource(self, didFail: error)
        }
    }
}
