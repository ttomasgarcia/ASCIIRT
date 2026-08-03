import AVFoundation
import AppKit
import Combine
import CoreVideo
import Foundation
import SwiftUI
import simd

enum SourceKind: String, CaseIterable, Identifiable {
    case camera = "Cámara"
    case file = "Archivo"
    /// Sin entrada: la imagen la genera el pipeline (el ojo).
    case eye = "Ojo"

    var id: String { rawValue }
}

/// Estado observable de la app.
///
/// Los parametros del usuario viven aca como propiedades publicadas y se
/// proyectan al pipeline con un unico `syncConfig()`, en vez de que cada
/// propiedad mute su campo del config. Es lo que hace que cargar un preset —
/// veinte valores de golpe — cueste una sola reconstruccion en vez de veinte:
/// `ASCIIPipeline.update` compara el config entero y solo rearma atlas o
/// texturas si cambio algo que lo justifique.
final class AppModel: ObservableObject {

    // MARK: - Fuente

    @Published var sourceKind: SourceKind = .camera { didSet { switchSource(from: oldValue) } }
    @Published private(set) var cameras: [CameraInfo] = []
    @Published var selectedCameraID: String? {
        didSet {
            guard oldValue != selectedCameraID, isRunning, sourceKind == .camera else { return }
            camera.start(deviceID: selectedCameraID)
        }
    }
    @Published private(set) var format: FormatDescription?
    @Published private(set) var permissionDenied = false
    @Published private(set) var isRunning = false

    // MARK: - Transporte de archivo

    @Published private(set) var fileURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var isLooping = true { didSet { file.isLooping = isLooping } }
    @Published var isMuted = false { didSet { file.isMuted = isMuted } }
    /// Mientras el usuario arrastra la barra no queremos que el observer de
    /// tiempo le pise la posicion debajo del dedo.
    @Published var isScrubbing = false

    // MARK: - Grid

    /// Ancho de celda en px. El alto se deriva del aspecto.
    @Published var tileWidth: UInt32 = 8 { didSet { sync() } }
    /// En `true` el alto de celda sigue el aspecto natural de la fuente, que es
    /// lo que hace que el glifo no salga deformado.
    @Published var aspectFollowsFont = true { didSet { sync() } }
    /// Aspecto manual cuando `aspectFollowsFont` esta apagado. 1.0 = celda
    /// cuadrada (glifo estirado a lo ancho).
    @Published var cellAspect: Double = 2.0 { didSet { sync() } }
    @Published var asciiEnabled = true { didSet { syncRenderFlags(); autosave() } }

    // MARK: - Charset

    /// Texto crudo del campo. No se aplica hasta "Recalibrar": recalibrar en
    /// cada tecla rearmaria el atlas por caracter tipeado.
    @Published var charsetText: String = PipelineConfig.defaultCharset
    @Published private(set) var selectedFont: FontSelection = .system(name: "Menlo-Regular")
    private var appliedCharset: [Character] = Array(PipelineConfig.defaultCharset)
    private var appliedExcluded: Set<Character> = []

    // MARK: - Ojo (fuente generativa)

    @Published var eyeCenter = CGPoint(x: 0.5, y: 0.5) { didSet { sync() } }
    @Published var eyeRadius: Double = 0.22 { didSet { sync() } }
    @Published var eyeCoreRadius: Double = 0.22 { didSet { sync() } }
    @Published var eyeFalloff: Double = 2.4 { didSet { sync() } }
    @Published var eyeRingWidth: Double = 0.055 { didSet { sync() } }
    @Published var eyeRingIntensity: Double = 0.85 { didSet { sync() } }
    @Published var eyeHaloRadius: Double = 0.38 { didSet { sync() } }
    @Published var eyeHaloIntensity: Double = 0.14 { didSet { sync() } }
    @Published var eyeIrisColor: Color = Color(red: 1.0, green: 0.10, blue: 0.05) { didSet { sync() } }
    @Published var eyeBreathAmount: Double = 0.03 { didSet { sync() } }
    @Published var eyeBreathSpeed: Double = 0.12 { didSet { sync() } }
    @Published var eyePulseAmount: Double = 0.07 { didSet { sync() } }
    @Published var eyePulseSpeed: Double = 0.09 { didSet { sync() } }
    @Published var eyePulseFrequency: Double = 5.0 { didSet { sync() } }
    @Published var eyePulseDecay: Double = 4.5 { didSet { sync() } }
    @Published var eyePulseDrag: Double = 0.6 { didSet { sync() } }
    @Published var eyeDriftAmount: Double = 0.004 { didSet { sync() } }
    @Published var eyeDriftSpeed: Double = 0.25 { didSet { sync() } }
    /// Fuerza del resorte hacia el objetivo.
    @Published var eyeStiffness: Double = 18 { didSet { sync() } }
    /// Rozamiento. Por debajo de 2·√rigidez el ojo sobrepasa y rebota al
    /// asentarse, que es de donde sale la sensacion de que esta vivo.
    @Published var eyeDamping: Double = 5.5 { didSet { sync() } }
    @Published var gazeMode: GazeMode = .fixed { didSet { sync() } }
    @Published var gazeRate: Double = 0.25 { didSet { sync() } }
    @Published var gazeExtentX: Double = 0.22 { didSet { sync() } }
    @Published var gazeExtentY: Double = 0.05 { didSet { sync() } }
    @Published var gazeHold: Double = 0.55 { didSet { sync() } }
    @Published var gazeStops: Double = 7 { didSet { sync() } }
    /// Arrastre en curso sobre el preview.
    @Published var isDraggingEye = false { didSet { sync() } }
    @Published var eyeClampToScreen = true { didSet { sync() } }

    /// Pleno: cuanto se sale el ojo del ASCII para ganar intensidad.
    @Published var eyeSolidAmount: Double = 0 { didSet { sync() } }
    @Published var eyeSolidGain: Double = 1.0 { didSet { sync() } }
    @Published var eyeSolidEdge: Double = 0.35 { didSet { sync() } }

    /// Arrastre del campo. Sirve para cualquier fuente, no solo el ojo.
    // MARK: - Estela (macro)

    /// Un solo control que escribe los cuatro parametros que hacen la estela.
    ///
    /// Escribe los valores reales en vez de multiplicarlos por detras: asi los
    /// sliders individuales se mueven y se ve exactamente que quedo puesto. Un
    /// macro que actua en secreto es imposible de depurar cuando algo se ve raro.
    @Published var trailMacro: Double = 0 { didSet { applyTrailMacro() } }

    /// Valores neutros a los que vuelve el macro en 0.
    private static let neutralTrail = (decay: 0.0, stiffness: 18.0, damping: 5.5, hysteresis: 0.75)

    private func applyTrailMacro() {
        // Al cargar un preset los cuatro parametros ya vienen guardados; dejar
        // que el macro los reescriba pisaria lo que el preset dice.
        guard !isApplyingPreset else { return }

        let t = min(max(trailMacro, 0), 1)
        let n = AppModel.neutralTrail

        // El macro se mapea al TIEMPO de desvanecido y no al factor de
        // decaimiento. El factor es exponencial: entre 0,5 y 0,9 hay medio
        // segundo de diferencia y entre 0,9 y 0,98 hay dos segundos, asi que
        // cualquier curva sobre el factor da un slider con todo amontonado en un
        // extremo. Sobre el tiempo, el recorrido es parejo.
        let fadeSeconds = 2.0 * pow(t, 1.8)
        let frames = fadeSeconds * 60
        // Se despeja el factor que lleva de 1 a medio escalon de rampa en esos
        // frames. Con frames < 1 da practicamente 0, o sea sin estela.
        trailDecay = frames < 0.5 ? 0 : pow(0.007, 1.0 / frames)

        // Menos resorte y menos rozamiento: el ojo va mas atras del objetivo y
        // se pasa al llegar, con lo que el campo se estira mientras viaja. Es la
        // otra mitad de la sensacion de estela, y sin esto el arrastre solo se
        // ve como un eco y no como movimiento.
        eyeStiffness = n.stiffness + (6.0 - n.stiffness) * t
        eyeDamping = n.damping + (2.6 - n.damping) * t

        // La disgregacion entra despues del primer tercio: con colas cortas
        // desarmar no se llega a ver, solo ensucia el borde de la estela.
        trailDisperse = t < 0.33 ? 0 : (t - 0.33) / 0.67 * 0.75

        // La histeresis baja acompanando: con la estela larga, retener glifos
        // ademas confunde el residuo de la histeresis con la cola de verdad.
        hysteresisThreshold = n.hysteresis + (0.30 - n.hysteresis) * t
    }

    @Published var trailDecay: Double = 0 { didSet { sync() } }
    @Published var trailDisperse: Double = 0 { didSet { sync() } }

    /// Interior del ojo.
    @Published var eyeHollow = false { didSet { sync() } }
    @Published var eyeGradientMode: UInt32 = 0 { didSet { sync() } }
    @Published var eyeGradientSpeed: Double = 0.15 { didSet { sync() } }
    @Published var eyeGradientCycles: Double = 1 { didSet { sync() } }
    @Published var eyeIrisOuterColor: Color = Color(red: 0.35, green: 0.02, blue: 0.10) { didSet { sync() } }
    @Published var eyeCoreColor: Color = .white { didSet { sync() } }
    @Published var eyeCoreBlend: Double = 1 { didSet { sync() } }
    @Published var eyeFieldNoise: Double = 0.55 { didSet { sync() } }
    @Published var eyeFieldChurn: Double = 6 { didSet { sync() } }

    /// Manda el ojo al centro dejando que el resorte lo lleve. Es lo que uno
    /// quiere en vivo: un salto instantaneo se veria como un corte.
    func centerEye() { eyeCenter = CGPoint(x: 0.5, y: 0.5) }

    /// Salto duro al centro, sin fisica. Para preparar antes de que entre gente.
    func snapEyeToCenter() {
        eyeCenter = CGPoint(x: 0.5, y: 0.5)
        renderer.ascii.eyeMotion.snap(to: SIMD2(0.5, 0.5))
    }

    // MARK: - Color y salida (M8)

    /// Presets de spec §8 mas "seguir a la fuente", que es el default util.
    enum OutputPreset: String, CaseIterable, Identifiable {
        case source = "Fuente"
        case hd1080 = "1080p"
        case qhd1440 = "1440p"
        case uhd4K = "4K"

        var id: String { rawValue }

        var size: SIMD2<UInt32>? {
            switch self {
            case .source: return nil
            case .hd1080: return SIMD2(1920, 1080)
            case .qhd1440: return SIMD2(2560, 1440)
            case .uhd4K: return SIMD2(3840, 2160)
            }
        }
    }

    @Published var outputPreset: OutputPreset = .source { didSet { sync() } }

    enum ColorMode: UInt32, CaseIterable, Identifiable {
        case mono = 0
        case duotone = 1
        case original = 2

        var id: UInt32 { rawValue }
        var label: String {
            switch self {
            case .mono: return "Mono"
            case .duotone: return "Dos colores"
            case .original: return "Original"
            }
        }
    }

    @Published var colorMode: ColorMode = .mono { didSet { sync() } }
    @Published var invert = false { didSet { sync() } }
    @Published var transparentBackground = false { didSet { sync() } }
    @Published var foregroundColor: Color = .white { didSet { sync() } }
    @Published var backgroundColor: Color = .black { didSet { sync() } }

    // MARK: - Bordes (M4)

    @Published var edgesEnabled = true { didSet { sync() } }
    @Published var dogSigma1: Double = 0.8 { didSet { sync() } }
    @Published var dogSigma2: Double = 2.4 { didSet { sync() } }
    @Published var dogTau: Double = 0.9 { didSet { sync() } }
    @Published var edgeThreshold: Double = 0.12 { didSet { sync() } }

    // MARK: - Temporal y exposicion (M5)

    @Published var hysteresisThreshold: Double = 0.75 { didSet { sync() } }
    @Published var autoLevelStrength: Double = 0.0 { didSet { sync() } }
    @Published var lumaSmoothAlpha: Double = 0.05 { didSet { sync() } }
    @Published var lumaTarget: Double = 0.5 { didSet { sync() } }
    @Published var exposureLocked = false {
        didSet { camera.setExposureLocked(exposureLocked); autosave() }
    }
    @Published private(set) var supportsExposureLock = false

    // MARK: - Matrix

    @Published var matrixEnabled = false {
        didSet {
            // La lluvia avanza por reloj: sin repintado continuo se congelaria
            // con el video en pausa o con la camara detenida.
            syncRenderFlags()
            sync()
        }
    }
    @Published var matrixSpeed: Double = 14 { didSet { sync() } }
    @Published var matrixTrail: Double = 18 { didSet { sync() } }
    @Published var matrixChurn: Double = 12 { didSet { sync() } }
    /// Gotas simultaneas por columna.
    @Published var matrixDensity: Double = 1 { didSet { sync() } }
    @Published var matrixImageMix: Double = 0.75 { didSet { sync() } }

    @Published var matrixBaseLevel: Double = 0.30 { didSet { sync() } }

    @Published var matrixSpawnBias: Double = 0 { didSet { sync() } }
    @Published var matrixSpawnStrength: Double = 0.6 { didSet { sync() } }

    @Published var matrixRelief: Double = 10 { didSet { sync() } }
    @Published var reliefRadius: Double = 5 { didSet { sync() } }
    @Published var subjectMatteEnabled = false {
        didSet { syncRenderFlags(); sync() }
    }
    @Published var matteWeight: Double = 0.6 { didSet { sync() } }

    @Published var matrixHeadTintEnabled = false { didSet { sync() } }
    @Published var matrixHeadCells: Double = 3 { didSet { sync() } }
    @Published var matrixHeadColor: Color = Color(red: 1.0, green: 0.10, blue: 0.10) {
        didSet { sync() }
    }

    // MARK: - Grabacion (M6)

    @Published var exportCodec: ExportCodec = .proRes422HQ { didSet { autosave() } }
    @Published private(set) var isRecording = false
    @Published private(set) var recordStats = VideoWriter.Stats()
    /// Se muestra una sola vez por sesion (spec §7): repetirla en cada export
    /// la vuelve ruido y el usuario deja de leerla.
    @Published var showedH264Warning = false

    // MARK: - Render offline (M7)

    @Published private(set) var isRendering = false
    @Published private(set) var renderProgress = OfflineRenderer.Progress()
    @Published private(set) var lastRenderSummary: String?

    // MARK: - Presets

    /// Tres cajones separados: un preset de look no toca el recorrido y uno de
    /// movimiento no toca la forma. El completo guarda las dos cosas y es lo que
    /// uno arma cuando ya encontro la combinacion.
    @Published private(set) var lookPresets: [String] = []
    @Published private(set) var motionPresets: [String] = []
    @Published private(set) var fullPresets: [String] = []
    @Published private(set) var currentLook: String?
    @Published private(set) var currentMotion: String?
    @Published private(set) var currentPresetName: String?

    // MARK: - Salida

    @Published private(set) var config = PipelineConfig()
    @Published private(set) var stats = RenderStats()
    @Published private(set) var errors: [AppError] = []

    /// Presets de ancho de celda. 8 es el piso util: por debajo el glifo no tiene
    /// pixeles suficientes para distinguirse de su vecino en la rampa.
    let tileSizes: [UInt32] = [8, 12, 16, 24, 32]

    var coverage: [GlyphCoverage] { renderer.ascii.atlas.coverage }
    var ramp: [Character] { renderer.ascii.atlas.ramp }

    var outputSize: CGSize {
        CGSize(width: Int(config.outputSize.x), height: Int(config.outputSize.y))
    }

    /// Spec §3: si la resolucion de salida no divide entero por el tile, se avisa
    /// y se ofrece el valor valido mas cercano. No se resamplea en silencio.
    var gridWarning: String? {
        guard !config.dividesEvenly else { return nil }
        return "\(config.outputSize.x)×\(config.outputSize.y) no divide entero por \(config.tileSize.x)×\(config.tileSize.y). "
             + "Válido más cercano: \(config.nearestValidWidth)×\(config.nearestValidHeight)."
    }

    let metal: MetalContext
    let renderer: FrameRenderer
    private let ascii: ASCIIPipeline
    private let camera = CameraSource()
    private let file = FileSource()
    private let matte: SubjectMatte
    private let writer = VideoWriter()
    private var offline: OfflineRenderer!
    private var openFileObserver: NSObjectProtocol?

    /// Mientras se aplica un preset, los didSet no tocan el pipeline: se hace un
    /// solo `sync()` al final.
    private var isApplyingPreset = false
    private var autosaveWork: DispatchWorkItem?

    /// Resolucion de salida vigente. Sigue a la fuente hasta que M8 agregue los
    /// presets propios de resolucion.
    private var sourceSize = SIMD2<UInt32>(1920, 1080)

    init() throws {
        let context = try MetalContext()
        self.metal = context

        let initial = PipelineConfig()
        self.config = initial

        let pipeline = try ASCIIPipeline(context: context, config: initial)
        self.ascii = pipeline
        self.renderer = try FrameRenderer(context: context, ascii: pipeline)
        self.matte = SubjectMatte(device: context.device)

        camera.delegate = self
        file.delegate = self

        renderer.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.stats = stats }
        }
        renderer.onError = { [weak self] error in
            DispatchQueue.main.async { self?.report(error) }
        }
        renderer.matteProvider = { [weak self] in self?.matte.texture }
        renderer.writer = writer
        self.offline = OfflineRenderer(context: context)
        writer.onStats = { [weak self] stats in self?.recordStats = stats }
        writer.onError = { [weak self] error in self?.report(error) }
        matte.onError = { [weak self] error in self?.report(error) }
        camera.onExposureLockSupport = { [weak self] supported in
            self?.supportsExposureLock = supported
        }

        file.onTime = { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = time.seconds
        }
        file.onPlaybackChange = { [weak self] playing in
            self?.isPlaying = playing
        }

        syncRenderFlags()
        refreshCameras()
        refreshPresets()

        // Estado de la ultima sesion. Si no existe o esta roto, se arranca con
        // los defaults y no se molesta al usuario: no es un error suyo.
        if let restored = try? PresetStore.load(from: PresetStore.lastSessionURL) {
            apply(restored, markCurrent: false)
        } else {
            sync()
        }

        openFileObserver = NotificationCenter.default.addObserver(
            forName: .asciirtOpenFile, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            self?.openFile(url)
        }
    }

    deinit {
        if let openFileObserver { NotificationCenter.default.removeObserver(openFileObserver) }
    }

    // MARK: - Proyeccion al pipeline

    /// Unico punto donde el estado del modelo se convierte en `PipelineConfig`.
    private func sync() {
        guard !isApplyingPreset else { return }

        var next = PipelineConfig()
        next.generative = sourceKind == .eye
        next.eyeCenter = SIMD2(Float(eyeCenter.x), Float(eyeCenter.y))
        next.eyeRadius = Float(eyeRadius)
        next.eyeCoreRadius = Float(eyeCoreRadius)
        next.eyeFalloff = Float(eyeFalloff)
        next.eyeRingWidth = Float(eyeRingWidth)
        next.eyeRingIntensity = Float(eyeRingIntensity)
        next.eyeHaloRadius = Float(eyeHaloRadius)
        next.eyeHaloIntensity = Float(eyeHaloIntensity)
        next.eyeIris = AppModel.components(of: eyeIrisColor)
        next.eyeBreathAmount = Float(eyeBreathAmount)
        next.eyeBreathSpeed = Float(eyeBreathSpeed)
        next.eyePulseAmount = Float(eyePulseAmount)
        next.eyePulseSpeed = Float(eyePulseSpeed)
        next.eyePulseFrequency = Float(eyePulseFrequency)
        next.eyePulseDecay = Float(eyePulseDecay)
        next.eyePulseDrag = Float(eyePulseDrag)
        next.eyeDriftAmount = Float(eyeDriftAmount)
        next.eyeDriftSpeed = Float(eyeDriftSpeed)
        next.eyeStiffness = Float(eyeStiffness)
        next.eyeDamping = Float(eyeDamping)
        next.gazeMode = gazeMode
        next.gazeRate = Float(gazeRate)
        next.gazeExtent = SIMD2(Float(gazeExtentX), Float(gazeExtentY))
        next.gazeHold = Float(gazeHold)
        next.gazeStops = Float(gazeStops)
        next.eyeManualOverride = isDraggingEye
        next.eyeClampToScreen = eyeClampToScreen
        next.eyeSolidAmount = Float(eyeSolidAmount)
        next.eyeSolidGain = Float(eyeSolidGain)
        next.eyeSolidEdge = Float(eyeSolidEdge)
        next.trailDecay = Float(trailDecay)
        next.trailDisperse = Float(trailDisperse)
        next.eyeHollow = eyeHollow
        next.eyeGradientMode = eyeGradientMode
        next.eyeGradientSpeed = Float(eyeGradientSpeed)
        next.eyeGradientCycles = Float(eyeGradientCycles)
        next.eyeIrisOuter = AppModel.components(of: eyeIrisOuterColor)
        next.eyeCoreColor = AppModel.components(of: eyeCoreColor)
        next.eyeCoreBlend = Float(eyeCoreBlend)
        next.eyeFieldNoise = Float(eyeFieldNoise)
        next.eyeFieldChurn = Float(eyeFieldChurn)

        next.outputSize = outputPreset.size ?? sourceSize
        next.outputFollowsSource = outputPreset == .source
        next.colorMode = colorMode.rawValue
        next.invert = invert
        next.transparentBackground = transparentBackground
        next.foreground = AppModel.components(of: foregroundColor)
        next.background = AppModel.components(of: backgroundColor)
        next.tileSize = SIMD2(tileWidth, resolvedCellHeight())
        next.font = selectedFont
        next.charset = appliedCharset
        next.excluded = appliedExcluded

        next.matrixEnabled = matrixEnabled
        next.matrixSpeed = Float(matrixSpeed)
        next.matrixTrail = Float(matrixTrail)
        next.matrixChurn = Float(matrixChurn)
        next.matrixDensity = UInt32(max(1, matrixDensity.rounded()))
        next.edgesEnabled = edgesEnabled
        next.dogSigma1 = Float(dogSigma1)
        next.dogSigma2 = Float(dogSigma2)
        next.dogTau = Float(dogTau)
        next.edgeThreshold = Float(edgeThreshold)
        next.hysteresisThreshold = Float(hysteresisThreshold)
        next.autoLevelStrength = Float(autoLevelStrength)
        next.lumaSmoothAlpha = Float(lumaSmoothAlpha)
        next.lumaTarget = Float(lumaTarget)
        next.matrixImageMix = Float(matrixImageMix)
        next.matrixBaseLevel = Float(matrixBaseLevel)
        next.matrixSpawnBias = Float(matrixSpawnBias)
        next.matrixSpawnStrength = Float(matrixSpawnStrength)
        next.matrixRelief = Float(matrixRelief)
        next.reliefRadius = UInt32(max(0, reliefRadius.rounded()))
        next.subjectMatteEnabled = subjectMatteEnabled
        next.matteWeight = Float(matteWeight)
        next.matrixHeadTintEnabled = matrixHeadTintEnabled
        next.matrixHeadCells = Float(matrixHeadCells)
        next.matrixHeadColor = AppModel.components(of: matrixHeadColor)

        do {
            try ascii.update(config: next)
            config = next
        } catch let error as AppError {
            report(error)
        } catch {
            report(AppError(.metal, "No se pudo reconfigurar el pipeline.", underlying: error))
        }
        autosave()
    }

    /// Alto de celda a partir del ancho y el aspecto vigente.
    private func resolvedCellHeight() -> UInt32 {
        var aspect = cellAspect
        if aspectFollowsFont {
            if let natural = try? selectedFont.naturalCellAspect() {
                aspect = natural
                // Se refleja en el control para que el numero no sea un misterio.
                // Sin el guard de tolerancia esto reentraria en `sync` por el
                // didSet de cellAspect en cada frame de configuracion.
                if abs(natural - cellAspect) > 0.001 {
                    let wasApplying = isApplyingPreset
                    isApplyingPreset = true
                    cellAspect = natural
                    isApplyingPreset = wasApplying
                }
            }
        }
        return UInt32(max(1, (Double(tileWidth) * aspect).rounded()))
    }

    /// SwiftUI Color no expone componentes; hay que bajar a NSColor y forzar
    /// sRGB, si no un color de otro espacio revienta al leerlo.
    private static func components(of color: Color) -> SIMD3<Float> {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return SIMD3(1, 0, 0) }
        return SIMD3(Float(converted.redComponent),
                     Float(converted.greenComponent),
                     Float(converted.blueComponent))
    }

    // MARK: - Charset

    /// Re-lee el campo y recalibra. Spec §2: el orden no se asume, se mide.
    func applyCharset() {
        appliedCharset = Array(charsetText)
        // Las exclusiones de glifos que ya no estan en el charset se caen solas;
        // mantenerlas confundiria la tabla.
        appliedExcluded = appliedExcluded.intersection(Set(appliedCharset))
        sync()
    }

    func setExcluded(_ character: Character, _ excluded: Bool) {
        if excluded { appliedExcluded.insert(character) } else { appliedExcluded.remove(character) }
        sync()
    }

    func resetCharset() {
        charsetText = PipelineConfig.defaultCharset
        appliedCharset = Array(PipelineConfig.defaultCharset)
        appliedExcluded = []
        sync()
    }

    func setFont(_ selection: FontSelection) {
        selectedFont = selection
        sync()
    }

    // MARK: - Presets

    func refreshPresets() {
        let all = PresetStore.listDetailed()
        lookPresets = all.filter { $0.scope == .look }.map(\.name)
        motionPresets = all.filter { $0.scope == .motion }.map(\.name)
        fullPresets = all.filter { $0.scope == .full }.map(\.name)
    }

    func snapshot(named name: String, scope: PresetScope = .full) -> Preset {
        var preset = Preset()
        preset.name = name
        preset.scope = scope.rawValue
        preset.tileWidth = Int(tileWidth)
        preset.aspectFollowsFont = aspectFollowsFont
        preset.cellAspect = cellAspect
        preset.asciiEnabled = asciiEnabled
        preset.charset = String(appliedCharset)
        preset.excluded = String(appliedExcluded)
        preset.setFont(selectedFont)

        preset.matrixEnabled = matrixEnabled
        preset.matrixSpeed = matrixSpeed
        preset.matrixTrail = matrixTrail
        preset.matrixChurn = matrixChurn
        preset.matrixDensity = matrixDensity
        preset.edgesEnabled = edgesEnabled
        preset.dogSigma1 = dogSigma1
        preset.dogSigma2 = dogSigma2
        preset.dogTau = dogTau
        preset.edgeThreshold = edgeThreshold
        preset.hysteresisThreshold = hysteresisThreshold
        preset.autoLevelStrength = autoLevelStrength
        preset.lumaSmoothAlpha = lumaSmoothAlpha
        preset.lumaTarget = lumaTarget
        preset.exposureLocked = exposureLocked
        preset.exportCodec = exportCodec
        preset.outputPreset = outputPreset.rawValue
        preset.colorMode = colorMode.rawValue
        preset.invert = invert
        preset.transparentBackground = transparentBackground
        let fg = AppModel.components(of: foregroundColor)
        let bg = AppModel.components(of: backgroundColor)
        preset.foreground = [Double(fg.x), Double(fg.y), Double(fg.z)]
        preset.background = [Double(bg.x), Double(bg.y), Double(bg.z)]

        preset.sourceKind = sourceKind.rawValue
        preset.eyeCenter = [Double(eyeCenter.x), Double(eyeCenter.y)]
        preset.eyeRadius = eyeRadius
        preset.eyeCoreRadius = eyeCoreRadius
        preset.eyeFalloff = eyeFalloff
        preset.eyeRingWidth = eyeRingWidth
        preset.eyeRingIntensity = eyeRingIntensity
        preset.eyeHaloRadius = eyeHaloRadius
        preset.eyeHaloIntensity = eyeHaloIntensity
        let iris = AppModel.components(of: eyeIrisColor)
        preset.eyeIris = [Double(iris.x), Double(iris.y), Double(iris.z)]
        preset.eyeBreathAmount = eyeBreathAmount
        preset.eyeBreathSpeed = eyeBreathSpeed
        preset.eyePulseAmount = eyePulseAmount
        preset.eyePulseSpeed = eyePulseSpeed
        preset.eyePulseFrequency = eyePulseFrequency
        preset.eyePulseDecay = eyePulseDecay
        preset.eyePulseDrag = eyePulseDrag
        preset.eyeDriftAmount = eyeDriftAmount
        preset.eyeDriftSpeed = eyeDriftSpeed
        preset.eyeStiffness = eyeStiffness
        preset.eyeDamping = eyeDamping
        preset.gazeMode = gazeMode.rawValue
        preset.gazeRate = gazeRate
        preset.gazeExtentX = gazeExtentX
        preset.gazeExtentY = gazeExtentY
        preset.gazeHold = gazeHold
        preset.gazeStops = gazeStops
        preset.eyeClampToScreen = eyeClampToScreen
        preset.eyeSolidAmount = eyeSolidAmount
        preset.eyeSolidGain = eyeSolidGain
        preset.eyeSolidEdge = eyeSolidEdge
        preset.trailDecay = trailDecay
        preset.trailMacro = trailMacro
        preset.trailDisperse = trailDisperse
        preset.eyeHollow = eyeHollow
        preset.eyeGradientMode = eyeGradientMode
        preset.eyeGradientSpeed = eyeGradientSpeed
        preset.eyeGradientCycles = eyeGradientCycles
        let outer = AppModel.components(of: eyeIrisOuterColor)
        preset.eyeIrisOuter = [Double(outer.x), Double(outer.y), Double(outer.z)]
        let coreRGB = AppModel.components(of: eyeCoreColor)
        preset.eyeCoreColor = [Double(coreRGB.x), Double(coreRGB.y), Double(coreRGB.z)]
        preset.eyeCoreBlend = eyeCoreBlend
        preset.eyeFieldNoise = eyeFieldNoise
        preset.eyeFieldChurn = eyeFieldChurn
        preset.matrixImageMix = matrixImageMix
        preset.matrixBaseLevel = matrixBaseLevel
        preset.matrixSpawnBias = matrixSpawnBias
        preset.matrixSpawnStrength = matrixSpawnStrength
        preset.matrixRelief = matrixRelief
        preset.reliefRadius = reliefRadius
        preset.subjectMatteEnabled = subjectMatteEnabled
        preset.matteWeight = matteWeight
        preset.matrixHeadTintEnabled = matrixHeadTintEnabled
        preset.matrixHeadCells = matrixHeadCells

        let rgb = AppModel.components(of: matrixHeadColor)
        preset.headColor = [Double(rgb.x), Double(rgb.y), Double(rgb.z)]
        return preset
    }

    func apply(_ preset: Preset, markCurrent: Bool = true) {
        isApplyingPreset = true

        // Alcance: un preset de movimiento no puede pisar la forma del ojo, ni
        // al reves. Es lo que permite combinar cualquier look con cualquier
        // recorrido sin rehacer uno de los dos.
        let scope = PresetScope(rawValue: preset.scope) ?? .full
        let wantsMotion = scope != .look
        let wantsLook = scope != .motion

        if wantsMotion {
                    gazeMode = GazeMode(rawValue: preset.gazeMode) ?? .fixed
            gazeRate = preset.gazeRate
            gazeExtentX = preset.gazeExtentX
            gazeExtentY = preset.gazeExtentY
            gazeHold = preset.gazeHold
            gazeStops = preset.gazeStops
            eyeClampToScreen = preset.eyeClampToScreen
                    if preset.eyeCenter.count >= 2 {
                eyeCenter = CGPoint(x: preset.eyeCenter[0], y: preset.eyeCenter[1])
                renderer.ascii.eyeMotion.snap(to: SIMD2(Float(preset.eyeCenter[0]),
                                                        Float(preset.eyeCenter[1])))
            }
        }

        guard wantsLook else {
            isApplyingPreset = false
            syncRenderFlags()
            sync()
            if markCurrent { currentMotion = preset.name }
            return
        }

        tileWidth = UInt32(max(1, preset.tileWidth))
        aspectFollowsFont = preset.aspectFollowsFont
        cellAspect = preset.cellAspect
        asciiEnabled = preset.asciiEnabled
        charsetText = preset.charset
        appliedCharset = Array(preset.charset)
        appliedExcluded = Set(preset.excluded)
        selectedFont = preset.font

        matrixEnabled = preset.matrixEnabled
        matrixSpeed = preset.matrixSpeed
        matrixTrail = preset.matrixTrail
        matrixChurn = preset.matrixChurn
        matrixDensity = preset.matrixDensity
        edgesEnabled = preset.edgesEnabled
        dogSigma1 = preset.dogSigma1
        dogSigma2 = preset.dogSigma2
        dogTau = preset.dogTau
        edgeThreshold = preset.edgeThreshold
        hysteresisThreshold = preset.hysteresisThreshold
        autoLevelStrength = preset.autoLevelStrength
        lumaSmoothAlpha = preset.lumaSmoothAlpha
        lumaTarget = preset.lumaTarget
        exposureLocked = preset.exposureLocked
        exportCodec = preset.exportCodec
        outputPreset = OutputPreset(rawValue: preset.outputPreset) ?? .source
        colorMode = ColorMode(rawValue: preset.colorMode) ?? .mono
        invert = preset.invert
        transparentBackground = preset.transparentBackground
        if preset.foreground.count >= 3 {
            foregroundColor = Color(red: preset.foreground[0], green: preset.foreground[1], blue: preset.foreground[2])
        }
        if preset.background.count >= 3 {
            backgroundColor = Color(red: preset.background[0], green: preset.background[1], blue: preset.background[2])
        }

        eyeRadius = preset.eyeRadius
        eyeCoreRadius = preset.eyeCoreRadius
        eyeFalloff = preset.eyeFalloff
        eyeRingWidth = preset.eyeRingWidth
        eyeRingIntensity = preset.eyeRingIntensity
        eyeHaloRadius = preset.eyeHaloRadius
        eyeHaloIntensity = preset.eyeHaloIntensity
        if preset.eyeIris.count >= 3 {
            eyeIrisColor = Color(red: preset.eyeIris[0], green: preset.eyeIris[1], blue: preset.eyeIris[2])
        }
        eyeBreathAmount = preset.eyeBreathAmount
        eyeBreathSpeed = preset.eyeBreathSpeed
        eyePulseAmount = preset.eyePulseAmount
        eyePulseSpeed = preset.eyePulseSpeed
        eyePulseFrequency = preset.eyePulseFrequency
        eyePulseDecay = preset.eyePulseDecay
        eyePulseDrag = preset.eyePulseDrag
        eyeDriftAmount = preset.eyeDriftAmount
        eyeDriftSpeed = preset.eyeDriftSpeed
        eyeStiffness = preset.eyeStiffness
        eyeDamping = preset.eyeDamping
        eyeSolidAmount = preset.eyeSolidAmount
        eyeSolidGain = preset.eyeSolidGain
        eyeSolidEdge = preset.eyeSolidEdge
        trailDecay = preset.trailDecay
        trailMacro = preset.trailMacro
        trailDisperse = preset.trailDisperse
        eyeHollow = preset.eyeHollow
        eyeGradientMode = preset.eyeGradientMode
        eyeGradientSpeed = preset.eyeGradientSpeed
        eyeGradientCycles = preset.eyeGradientCycles
        if preset.eyeIrisOuter.count >= 3 {
            eyeIrisOuterColor = Color(red: preset.eyeIrisOuter[0], green: preset.eyeIrisOuter[1], blue: preset.eyeIrisOuter[2])
        }
        if preset.eyeCoreColor.count >= 3 {
            eyeCoreColor = Color(red: preset.eyeCoreColor[0], green: preset.eyeCoreColor[1], blue: preset.eyeCoreColor[2])
        }
        eyeCoreBlend = preset.eyeCoreBlend
        eyeFieldNoise = preset.eyeFieldNoise
        eyeFieldChurn = preset.eyeFieldChurn
        // La fuente va al final: cambiarla arranca o detiene captura, y quiero
        // que lo haga con todos los parametros ya puestos.
        sourceKind = SourceKind(rawValue: preset.sourceKind) ?? .camera
        matrixImageMix = preset.matrixImageMix
        matrixBaseLevel = preset.matrixBaseLevel
        matrixSpawnBias = preset.matrixSpawnBias
        matrixSpawnStrength = preset.matrixSpawnStrength
        matrixRelief = preset.matrixRelief
        reliefRadius = preset.reliefRadius
        subjectMatteEnabled = preset.subjectMatteEnabled
        matteWeight = preset.matteWeight
        matrixHeadTintEnabled = preset.matrixHeadTintEnabled
        matrixHeadCells = preset.matrixHeadCells

        if preset.headColor.count >= 3 {
            matrixHeadColor = Color(red: preset.headColor[0],
                                    green: preset.headColor[1],
                                    blue: preset.headColor[2])
        }

        isApplyingPreset = false

        // Los didSet se saltearon el pipeline; esto lo pone al dia.
        syncRenderFlags()
        camera.setExposureLocked(exposureLocked)
        sync()

        if markCurrent {
            switch scope {
            case .look: currentLook = preset.name
            case .motion: currentMotion = preset.name
            case .full:
                currentPresetName = preset.name
                // Un completo define las dos cosas, asi que los otros dos
                // selectores dejan de representar lo que hay en pantalla.
                currentLook = nil
                currentMotion = nil
            }
        }
    }

    func savePreset(named name: String, scope: PresetScope = .full) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report(AppError(.capture, "El preset necesita un nombre."))
            return
        }
        do {
            try PresetStore.save(snapshot(named: trimmed, scope: scope), to: PresetStore.url(for: trimmed))
            switch scope {
            case .look: currentLook = trimmed
            case .motion: currentMotion = trimmed
            case .full: currentPresetName = trimmed
            }
            refreshPresets()
        } catch let error as AppError {
            report(error)
        } catch {
            report(AppError(.capture, "No se pudo guardar el preset.", underlying: error))
        }
    }

    func loadPreset(named name: String) {
        do {
            apply(try PresetStore.load(from: PresetStore.url(for: name)))
        } catch let error as AppError {
            report(error)
        } catch {
            report(AppError(.capture, "No se pudo cargar «\(name)».", underlying: error))
        }
    }

    func deletePreset(named name: String) {
        do {
            try PresetStore.delete(named: name)
            if currentPresetName == name { currentPresetName = nil }
            if currentLook == name { currentLook = nil }
            if currentMotion == name { currentMotion = nil }
            refreshPresets()
        } catch let error as AppError {
            report(error)
        } catch {
            report(AppError(.capture, "No se pudo borrar «\(name)».", underlying: error))
        }
    }

    func revealPresetsFolder() { PresetStore.revealInFinder() }

    /// Guarda el estado vigente con retardo. Sin el retardo, arrastrar un slider
    /// escribiria el archivo en cada frame.
    private func autosave() {
        guard !isApplyingPreset else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let name = self.currentPresetName ?? "Sesión anterior"
            try? PresetStore.ensureFolder()
            try? PresetStore.save(self.snapshot(named: name), to: PresetStore.lastSessionURL)
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Fuentes

    private func adoptSourceSize(_ description: FormatDescription) {
        let size = SIMD2<UInt32>(UInt32(description.width), UInt32(description.height))
        guard size != sourceSize else { return }
        sourceSize = size
        sync()
    }

    private func switchSource(from previous: SourceKind) {
        guard previous != sourceKind else { return }
        switch previous {
        case .camera: camera.stop()
        case .file: file.stop()
        case .eye: break
        }
        isRunning = false
        format = nil

        switch sourceKind {
        case .camera:
            fileURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            Task { await startCapture() }
        case .file:
            break // espera a que abran un archivo
        case .eye:
            fileURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            // Sin fuente externa la resolucion la fija el preset; 1080p es el
            // default razonable para proyectar.
            sourceSize = SIMD2(1920, 1080)
            isRunning = true
        }
        syncRenderFlags()
        sync()
    }

    /// Unico lugar que decide los flags del renderer.
    ///
    /// Estaban repetidos en tres puntos y el de `apply` pisaba lo que acababa de
    /// poner el cambio de fuente: al abrir en modo ojo el repintado continuo
    /// quedaba apagado y la pantalla en negro. Un solo metodo, llamado desde
    /// todos los didSet que puedan afectarlos.
    private func syncRenderFlags() {
        renderer.generative = sourceKind == .eye
        renderer.asciiEnabled = asciiEnabled
        // El generador anima por reloj, no por frame de entrada: sin repintado
        // continuo quedaria congelado en el primer cuadro.
        renderer.continuousRedraw = matrixEnabled || sourceKind == .eye
        matte.isEnabled = subjectMatteEnabled
    }

    func refreshCameras() {
        cameras = CameraSource.availableCameras()
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first?.id
        }
    }

    func startCapture() async {
        guard sourceKind == .camera else { return }
        guard await CameraSource.requestAccess() else {
            permissionDenied = true
            report(AppError(.permissions, "Acceso a la camara denegado.",
                            detail: "Ajustes del Sistema › Privacidad y seguridad › Cámara → habilitar ASCIIRT."))
            return
        }
        permissionDenied = false
        refreshCameras()
        isRunning = true
        camera.start(deviceID: selectedCameraID)
    }

    func stopCapture() {
        isRunning = false
        camera.stop()
        file.stop()
    }

    func openFile(_ url: URL) {
        sourceKind = .file
        fileURL = url
        isRunning = true
        Task { await file.load(url: url) }
    }

    // MARK: - Grabacion

    /// Duracion de la grabacion en curso, en segundos.
    var recordDuration: Double { recordStats.duration }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard !exportCodec.isImageSequence else {
            report(AppError(.capture, "La secuencia PNG solo sale del render offline.",
                            detail: "Escribir PNG por frame no entra en tiempo real: es el único destino "
                                  + "donde el frame vuelve a CPU."))
            return
        }
        guard isRunning else {
            report(AppError(.capture, "No hay señal para grabar."))
            return
        }

        if exportCodec == .h264 && !showedH264Warning {
            showedH264Warning = true
            report(AppError(.capture, "H.264 es el peor caso para material ASCII.",
                            detail: "Bordes de altísima frecuencia producen ringing que se come los glifos finos. "
                                  + "El bitrate ya va a ~3x de lo normal, pero para post usá ProRes."))
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ASCIIRT.\(exportCodec.fileExtension)"
        panel.allowedContentTypes = exportCodec == .h264 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try writer.start(url: url,
                             size: config.outputSize,
                             codec: exportCodec,
                             fps: format?.fps ?? 30,
                             realTime: true)
            isRecording = true
        } catch let error as AppError {
            report(error)
        } catch {
            report(AppError(.capture, "No se pudo iniciar la grabación.", underlying: error))
        }
    }

    private func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        switch await writer.finish() {
        case .success(let url):
            // Revelar en Finder en vez de un cartel de "listo": lo primero que
            // uno hace despues de grabar es ir a buscar el archivo.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            report(error)
        }
    }

    // MARK: - Render offline

    /// Spec §6: cada frame de entrada produce exactamente uno de salida. Se
    /// detiene la reproduccion primero — el preview y el render competirian por
    /// la GPU y por el decodificador del mismo archivo.
    func startOfflineRender() {
        guard !isRendering, let source = fileURL else {
            report(AppError(.capture, "Abrí un archivo de video primero."))
            return
        }
        if isRecording { Task { await stopRecording() } }
        file.pause()

        if exportCodec == .h264 && !showedH264Warning {
            showedH264Warning = true
            report(AppError(.capture, "H.264 es el peor caso para material ASCII.",
                            detail: "Bordes de altísima frecuencia producen ringing que se come los glifos finos. "
                                  + "El bitrate ya va a ~3x de lo normal, pero para post usá ProRes."))
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent
            + "_ascii." + exportCodec.fileExtension
        panel.allowedContentTypes = exportCodec == .h264 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isRendering = true
        renderProgress = OfflineRenderer.Progress()
        lastRenderSummary = nil

        offline.render(source: source, destination: destination,
                       config: config, codec: exportCodec,
                       onProgress: { [weak self] progress in
                           self?.renderProgress = progress
                       },
                       onFinish: { [weak self] result in
                           guard let self else { return }
                           self.isRendering = false
                           switch result {
                           case .success(let frames):
                               self.lastRenderSummary = "\(frames) frames escritos"
                               NSWorkspace.shared.activateFileViewerSelecting([destination])
                           case .failure(let error):
                               self.report(error)
                           }
                       })
    }

    func cancelOfflineRender() {
        offline.cancel()
    }

    // MARK: - Transporte

    func togglePlayback() { file.togglePlayback() }

    func scrub(toFraction fraction: Double) {
        currentTime = duration * fraction
        file.seek(toFraction: fraction)
    }

    /// Salto por frame usando el fps nominal del archivo.
    func step(frames: Int) {
        let fps = file.nominalFPS > 0 ? file.nominalFPS : 30
        let target = max(0, min(duration, currentTime + Double(frames) / fps))
        currentTime = target
        file.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    // MARK: - Errores

    func report(_ error: AppError) {
        // Sin duplicados consecutivos: un fallo por frame llenaria la lista.
        guard errors.last?.message != error.message else { return }
        errors.append(error)
    }

    func dismiss(_ error: AppError) {
        errors.removeAll { $0.id == error.id }
    }
}

extension AppModel: FrameSourceDelegate {
    /// Detener una fuente no es instantaneo: AVFoundation puede seguir entregando
    /// desde su propia cola un rato despues del switch. Sin este filtro la fuente
    /// vieja pisa el formato de la nueva y manda frames de mas.
    private func isCurrent(_ source: FrameSource) -> Bool {
        switch sourceKind {
        case .camera: return source === camera
        case .file: return source === file
        case .eye: return false   // el generador no entrega frames por delegate
        }
    }

    /// Puede llegar fuera de main. No toca estado publicado: el frame va derecho
    /// a la GPU.
    func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        // Vision corre en su propia cola y descarta lo que no llega a procesar.
        matte.submit(pixelBuffer)
        renderer.submit(pixelBuffer: pixelBuffer, at: time)
    }

    func frameSource(_ source: FrameSource, didChangeFormat description: FormatDescription) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(source) else { return }
            self.format = description
            self.adoptSourceSize(description)
            if source === self.file {
                self.duration = self.file.duration.seconds
            }
        }
    }

    func frameSource(_ source: FrameSource, didFail error: AppError) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(source) else { return }
            self.isRunning = false
            self.report(error)
        }
    }
}
