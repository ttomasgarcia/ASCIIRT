import AppKit
import Foundation

/// Set completo de parametros como JSON (spec §8).
///
/// Es un DTO plano y no el `PipelineConfig` serializado a proposito: el config
/// tiene tipos que no sobreviven bien a JSON (`Set<Character>`, `FontSelection`)
/// y, sobre todo, un preset guardado hoy tiene que abrir en una version futura
/// que agrego parametros. Por eso todo campo faltante cae en su default en vez
/// de hacer fallar la decodificacion entera.
struct Preset: Codable, Equatable {
    var name: String = "Sin nombre"

    // Grid
    var tileWidth: Int = 8
    var aspectFollowsFont: Bool = true
    var cellAspect: Double = 2.0
    var asciiEnabled: Bool = true

    // Charset
    var charset: String = PipelineConfig.defaultCharset
    var excluded: String = ""
    var fontSystemName: String? = "Menlo-Regular"
    var fontPath: String?

    // Matrix
    var matrixEnabled: Bool = false
    var matrixSpeed: Double = 14
    var matrixTrail: Double = 18
    var matrixChurn: Double = 12
    var matrixDensity: Double = 1

    // Bordes
    var edgesEnabled: Bool = true
    var dogSigma1: Double = 0.8
    var dogSigma2: Double = 2.4
    var dogTau: Double = 0.9
    var edgeThreshold: Double = 0.12

    // Temporal y exposicion
    var hysteresisThreshold: Double = 0.75
    var autoLevelStrength: Double = 0.0
    var lumaSmoothAlpha: Double = 0.05
    var lumaTarget: Double = 0.5
    var exposureLocked: Bool = false

    // Export
    var exportCodec: ExportCodec = .proRes422HQ

    // Color y salida
    var outputPreset: String = "Fuente"
    var colorMode: UInt32 = 0
    var invert: Bool = false
    var transparentBackground: Bool = false
    var foreground: [Double] = [1, 1, 1]
    var background: [Double] = [0, 0, 0]

    // Fuente y ojo generativo
    /// Se guarda la fuente porque un preset de show tiene que abrir directo en
    /// el modo ojo, no en camara.
    var sourceKind: String = "Cámara"
    var eyeCenter: [Double] = [0.5, 0.5]
    var eyeRadius: Double = 0.22
    var eyeCoreRadius: Double = 0.22
    var eyeFalloff: Double = 2.4
    var eyeRingWidth: Double = 0.055
    var eyeRingIntensity: Double = 0.85
    var eyeHaloRadius: Double = 0.16
    var eyeHaloIntensity: Double = 0.14
    var eyeIris: [Double] = [1.0, 0.10, 0.05]
    var eyeBreathAmount: Double = 0.03
    var eyeBreathSpeed: Double = 0.12
    var eyePulseAmount: Double = 0.07
    var eyePulseSpeed: Double = 0.09
    var eyePulseFrequency: Double = 5.0
    var eyePulseDecay: Double = 4.5
    var eyeDriftAmount: Double = 0.004
    var eyeDriftSpeed: Double = 0.25
    var eyeStiffness: Double = 18
    var eyeDamping: Double = 5.5
    var eyeSolidAmount: Double = 0
    var eyeSolidGain: Double = 1.0
    var eyeSolidEdge: Double = 0.35
    var trailDecay: Double = 0
    var eyeFieldNoise: Double = 0.55
    var eyeFieldChurn: Double = 6
    var matrixImageMix: Double = 0.75

    var matrixBaseLevel: Double = 0.30

    var matrixSpawnBias: Double = 0
    var matrixSpawnStrength: Double = 0.6

    var matrixRelief: Double = 10
    var reliefRadius: Double = 5
    var subjectMatteEnabled: Bool = false
    var matteWeight: Double = 0.6

    var matrixHeadTintEnabled: Bool = false
    var matrixHeadCells: Double = 3
    var headColor: [Double] = [1.0, 0.10, 0.10]

    init() {}

    /// Decodificacion tolerante: lo que falte toma el default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preset()

        name = c.value(.name, d.name)
        tileWidth = c.value(.tileWidth, d.tileWidth)
        aspectFollowsFont = c.value(.aspectFollowsFont, d.aspectFollowsFont)
        cellAspect = c.value(.cellAspect, d.cellAspect)
        asciiEnabled = c.value(.asciiEnabled, d.asciiEnabled)

        charset = c.value(.charset, d.charset)
        excluded = c.value(.excluded, d.excluded)
        fontSystemName = c.value(.fontSystemName, d.fontSystemName)
        fontPath = c.value(.fontPath, d.fontPath)

        matrixEnabled = c.value(.matrixEnabled, d.matrixEnabled)
        matrixSpeed = c.value(.matrixSpeed, d.matrixSpeed)
        matrixTrail = c.value(.matrixTrail, d.matrixTrail)
        matrixChurn = c.value(.matrixChurn, d.matrixChurn)
        matrixDensity = c.value(.matrixDensity, d.matrixDensity)

        edgesEnabled = c.value(.edgesEnabled, d.edgesEnabled)
        dogSigma1 = c.value(.dogSigma1, d.dogSigma1)
        dogSigma2 = c.value(.dogSigma2, d.dogSigma2)
        dogTau = c.value(.dogTau, d.dogTau)
        edgeThreshold = c.value(.edgeThreshold, d.edgeThreshold)

        hysteresisThreshold = c.value(.hysteresisThreshold, d.hysteresisThreshold)
        autoLevelStrength = c.value(.autoLevelStrength, d.autoLevelStrength)
        lumaSmoothAlpha = c.value(.lumaSmoothAlpha, d.lumaSmoothAlpha)
        lumaTarget = c.value(.lumaTarget, d.lumaTarget)
        exposureLocked = c.value(.exposureLocked, d.exposureLocked)
        exportCodec = c.value(.exportCodec, d.exportCodec)
        outputPreset = c.value(.outputPreset, d.outputPreset)
        colorMode = c.value(.colorMode, d.colorMode)
        invert = c.value(.invert, d.invert)
        transparentBackground = c.value(.transparentBackground, d.transparentBackground)
        foreground = c.value(.foreground, d.foreground)
        background = c.value(.background, d.background)

        sourceKind = c.value(.sourceKind, d.sourceKind)
        eyeCenter = c.value(.eyeCenter, d.eyeCenter)
        eyeRadius = c.value(.eyeRadius, d.eyeRadius)
        eyeCoreRadius = c.value(.eyeCoreRadius, d.eyeCoreRadius)
        eyeFalloff = c.value(.eyeFalloff, d.eyeFalloff)
        eyeRingWidth = c.value(.eyeRingWidth, d.eyeRingWidth)
        eyeRingIntensity = c.value(.eyeRingIntensity, d.eyeRingIntensity)
        eyeHaloRadius = c.value(.eyeHaloRadius, d.eyeHaloRadius)
        eyeHaloIntensity = c.value(.eyeHaloIntensity, d.eyeHaloIntensity)
        eyeIris = c.value(.eyeIris, d.eyeIris)
        eyeBreathAmount = c.value(.eyeBreathAmount, d.eyeBreathAmount)
        eyeBreathSpeed = c.value(.eyeBreathSpeed, d.eyeBreathSpeed)
        eyePulseAmount = c.value(.eyePulseAmount, d.eyePulseAmount)
        eyePulseSpeed = c.value(.eyePulseSpeed, d.eyePulseSpeed)
        eyePulseFrequency = c.value(.eyePulseFrequency, d.eyePulseFrequency)
        eyePulseDecay = c.value(.eyePulseDecay, d.eyePulseDecay)
        eyeDriftAmount = c.value(.eyeDriftAmount, d.eyeDriftAmount)
        eyeDriftSpeed = c.value(.eyeDriftSpeed, d.eyeDriftSpeed)
        eyeStiffness = c.value(.eyeStiffness, d.eyeStiffness)
        eyeDamping = c.value(.eyeDamping, d.eyeDamping)
        eyeSolidAmount = c.value(.eyeSolidAmount, d.eyeSolidAmount)
        eyeSolidGain = c.value(.eyeSolidGain, d.eyeSolidGain)
        eyeSolidEdge = c.value(.eyeSolidEdge, d.eyeSolidEdge)
        trailDecay = c.value(.trailDecay, d.trailDecay)
        eyeFieldNoise = c.value(.eyeFieldNoise, d.eyeFieldNoise)
        eyeFieldChurn = c.value(.eyeFieldChurn, d.eyeFieldChurn)
        matrixImageMix = c.value(.matrixImageMix, d.matrixImageMix)

        matrixBaseLevel = c.value(.matrixBaseLevel, d.matrixBaseLevel)

        matrixSpawnBias = c.value(.matrixSpawnBias, d.matrixSpawnBias)
        matrixSpawnStrength = c.value(.matrixSpawnStrength, d.matrixSpawnStrength)

        matrixRelief = c.value(.matrixRelief, d.matrixRelief)
        reliefRadius = c.value(.reliefRadius, d.reliefRadius)
        subjectMatteEnabled = c.value(.subjectMatteEnabled, d.subjectMatteEnabled)
        matteWeight = c.value(.matteWeight, d.matteWeight)

        matrixHeadTintEnabled = c.value(.matrixHeadTintEnabled, d.matrixHeadTintEnabled)
        matrixHeadCells = c.value(.matrixHeadCells, d.matrixHeadCells)
        headColor = c.value(.headColor, d.headColor)
    }

    var font: FontSelection {
        if let fontPath { return .file(url: URL(fileURLWithPath: fontPath)) }
        return .system(name: fontSystemName ?? "Menlo-Regular")
    }

    mutating func setFont(_ selection: FontSelection) {
        switch selection {
        case .system(let name):
            fontSystemName = name
            fontPath = nil
        case .file(let url):
            fontSystemName = nil
            fontPath = url.path
        }
    }
}

private extension KeyedDecodingContainer {
    /// `decodeIfPresent` con default y sin propagar el error: un campo con tipo
    /// cambiado no debe invalidar el preset entero.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Presets en disco, en una carpeta que el usuario puede abrir en Finder
/// (spec §8). Un archivo JSON por preset, mas el estado de la ultima sesion.
enum PresetStore {

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ASCIIRT/Presets", isDirectory: true)
    }

    /// Estado que se restaura al abrir. Va fuera de la carpeta de presets para
    /// que no aparezca como uno mas en la lista.
    static var lastSessionURL: URL {
        folder.deletingLastPathComponent().appendingPathComponent("last-session.json")
    }

    static func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func url(for name: String) -> URL {
        // Los separadores de ruta en un nombre escribirian fuera de la carpeta.
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("\(safe).json")
    }

    static func save(_ preset: Preset, to url: URL) throws {
        try ensureFolder()
        let encoder = JSONEncoder()
        // Legible y con orden estable: un preset es un archivo que el usuario
        // puede abrir, versionar o mandar por mail.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(preset).write(to: url, options: .atomic)
        } catch {
            throw AppError(.capture, "No se pudo guardar el preset.", underlying: error)
        }
    }

    static func load(from url: URL) throws -> Preset {
        do {
            return try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
        } catch {
            throw AppError(.capture, "No se pudo leer «\(url.lastPathComponent)».", underlying: error)
        }
    }

    static func delete(named name: String) throws {
        do {
            try FileManager.default.removeItem(at: url(for: name))
        } catch {
            throw AppError(.capture, "No se pudo borrar «\(name)».", underlying: error)
        }
    }

    static func revealInFinder() {
        try? ensureFolder()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
