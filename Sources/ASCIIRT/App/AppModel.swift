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
    @Published var asciiEnabled = true { didSet { renderer.asciiEnabled = asciiEnabled; autosave() } }

    // MARK: - Charset

    /// Texto crudo del campo. No se aplica hasta "Recalibrar": recalibrar en
    /// cada tecla rearmaria el atlas por caracter tipeado.
    @Published var charsetText: String = PipelineConfig.defaultCharset
    @Published private(set) var selectedFont: FontSelection = .system(name: "Menlo-Regular")
    private var appliedCharset: [Character] = Array(PipelineConfig.defaultCharset)
    private var appliedExcluded: Set<Character> = []

    // MARK: - Bordes (M4)

    @Published var edgesEnabled = true { didSet { sync() } }
    @Published var dogSigma1: Double = 0.8 { didSet { sync() } }
    @Published var dogSigma2: Double = 2.4 { didSet { sync() } }
    @Published var dogTau: Double = 0.9 { didSet { sync() } }
    @Published var edgeThreshold: Double = 0.12 { didSet { sync() } }

    // MARK: - Temporal y exposicion (M5)

    @Published var hysteresisThreshold: Double = 0.08 { didSet { sync() } }
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
            renderer.continuousRedraw = matrixEnabled
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
        didSet { matte.isEnabled = subjectMatteEnabled; sync() }
    }
    @Published var matteWeight: Double = 0.6 { didSet { sync() } }

    @Published var matrixHeadTintEnabled = false { didSet { sync() } }
    @Published var matrixHeadCells: Double = 3 { didSet { sync() } }
    @Published var matrixHeadColor: Color = Color(red: 1.0, green: 0.10, blue: 0.10) {
        didSet { sync() }
    }

    // MARK: - Presets

    @Published private(set) var presetNames: [String] = []
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

        renderer.continuousRedraw = matrixEnabled
        matte.isEnabled = subjectMatteEnabled
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
        next.outputSize = sourceSize
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
        presetNames = PresetStore.list()
    }

    func snapshot(named name: String) -> Preset {
        var preset = Preset()
        preset.name = name
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

        // Los didSet se saltearon el pipeline; estos tres lo ponen al dia.
        renderer.asciiEnabled = asciiEnabled
        renderer.continuousRedraw = matrixEnabled
        matte.isEnabled = subjectMatteEnabled
        camera.setExposureLocked(exposureLocked)
        sync()

        if markCurrent { currentPresetName = preset.name }
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report(AppError(.capture, "El preset necesita un nombre."))
            return
        }
        do {
            try PresetStore.save(snapshot(named: trimmed), to: PresetStore.url(for: trimmed))
            currentPresetName = trimmed
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
        }
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
        }
    }

    /// Puede llegar fuera de main. No toca estado publicado: el frame va derecho
    /// a la GPU.
    func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        // Vision corre en su propia cola y descarta lo que no llega a procesar.
        matte.submit(pixelBuffer)
        renderer.submit(pixelBuffer: pixelBuffer)
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
