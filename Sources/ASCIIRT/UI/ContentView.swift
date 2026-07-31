import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showControls = true
    @State private var isDropTargeted = false
    @State private var recordPulse = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                preview
                if model.sourceKind == .file {
                    Divider()
                    TransportBar(model: model)
                }
            }
            if showControls {
                Divider()
                ControlPanel(model: model)
                    .frame(width: 316)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(model.isRecording ? "Detener" : "REC",
                          systemImage: model.isRecording ? "stop.fill" : "record.circle")
                }
                .tint(model.isRecording ? .red : nil)
                .help(model.isRecording ? "Detener y guardar" : "Grabar a archivo")
                .disabled(!model.isRunning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showControls.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Mostrar/ocultar controles")
            }
        }
        .task { await model.startCapture() }
        .onDisappear { model.stopCapture() }
        // Arrastrar un video a la ventana lo abre: es el gesto que uno espera de
        // algo con player.
        //
        // Se pide `.fileURL` y no `.movie`: Finder registra el item como
        // public.file-url mas el UTI concreto del archivo, y pedir el supertipo
        // hace que SwiftUI rechace el drop antes de que lleguemos a mirarlo.
        // Por la misma razon se lee con loadItem y no con loadObject(ofClass:),
        // que para file URLs devuelve nil sin decir por que.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            PreviewView(context: model.metal,
                        renderer: model.renderer,
                        drawableSize: model.outputSize)
                // El drawable es fijo; esto solo decide como se escala en pantalla.
                .aspectRatio(model.outputSize, contentMode: .fit)

            if !model.isRunning {
                Text(placeholder)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        // Los numeros de salud van sobre el preview y no en el panel: se miran
        // mientras se mira la imagen, no mientras se tocan parametros.
        .overlay(alignment: .topTrailing) { hud }
        .overlay(alignment: .topLeading) { recordBadge }
        .overlay { renderOverlay }
        .overlay(alignment: .bottom) { ErrorBanner(model: model) }
    }

    private var hud: some View {
        HStack(spacing: 10) {
            Label(String(format: "%.0f fps", model.stats.displayedFPS), systemImage: "speedometer")
            Text("\(model.config.gridSize.x)×\(model.config.gridSize.y)")
            if model.stats.droppedFrames > 0 {
                Label("\(model.stats.droppedFrames)", systemImage: "arrow.down.right.circle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(10)
        .opacity(model.isRunning ? 1 : 0)
    }

    /// Estado de grabacion sobre la imagen: mientras se graba, el usuario mira
    /// el preview, no el panel.
    @ViewBuilder private var recordBadge: some View {
        if model.isRecording {
            HStack(spacing: 7) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    // Parpadeo: un punto rojo fijo se confunde con un adorno.
                    .opacity(recordPulse ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recordPulse)
                Text(timecode(model.recordDuration))
                    .monospacedDigit()
                Text("\(model.recordStats.framesWritten)f")
                    .foregroundStyle(.secondary)
                if model.recordStats.framesDropped > 0 {
                    // Spec §7: los frames dropeados durante la grabacion tienen
                    // que verse, no quedar en un log.
                    Label("\(model.recordStats.framesDropped)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
            .onAppear { recordPulse = true }
            .onDisappear { recordPulse = false }
        }
    }

    /// El render offline tapa el preview a proposito: mientras corre, la
    /// reproduccion esta detenida y no hay nada que mirar debajo.
    @ViewBuilder private var renderOverlay: some View {
        if model.isRendering {
            ZStack {
                Color.black.opacity(0.72)
                VStack(spacing: 14) {
                    Text("Render offline")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    ProgressView(value: model.renderProgress.fraction)
                        .frame(width: 260)
                    Text("\(model.renderProgress.framesDone) / \(model.renderProgress.framesTotal) frames")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Cancelar") { model.cancelOfflineRender() }
                        .controlSize(.small)
                }
                .padding(24)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .allowsHitTesting(true)
        }
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var placeholder: String {
        if model.permissionDenied { return "Sin acceso a la cámara" }
        if model.sourceKind == .file { return "Arrastrá un video acá" }
        return "Sin señal"
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let identifier = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(identifier) }) else {
            model.report(AppError(.capture, "Eso que arrastraste no es un archivo."))
            return false
        }

        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
            // El item llega como Data con el bookmark del URL; el caso `as? URL`
            // es por si alguna app registra el objeto directo.
            let url: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                ?? (item as? URL)

            DispatchQueue.main.async {
                guard let url else {
                    model.report(AppError(.capture, "No se pudo leer el archivo arrastrado.",
                                          detail: error?.localizedDescription))
                    return
                }
                // Se valida el tipo aca y no en el `of:` del onDrop para poder dar
                // un error propio: el de AVFoundation sobre un archivo que no es
                // video es incomprensible.
                let type = UTType(filenameExtension: url.pathExtension)
                guard type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true else {
                    model.report(AppError(.capture, "«\(url.lastPathComponent)» no es un video."))
                    return
                }
                model.openFile(url)
            }
        }
        return true
    }
}

// MARK: - Transporte

private struct TransportBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.fileURL == nil)
                Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.borderless)

            Text(timecode(model.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()

            Slider(
                value: Binding(
                    get: { model.duration > 0 ? model.currentTime / model.duration : 0 },
                    set: { model.scrub(toFraction: $0) }
                ),
                in: 0...1,
                onEditingChanged: { model.isScrubbing = $0 }
            )
            .controlSize(.mini)
            .disabled(model.duration <= 0)

            Text(timecode(model.duration))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Toggle(isOn: $model.isLooping) { Image(systemName: "repeat") }
                    .help("Loop")
                Toggle(isOn: $model.isMuted) {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help("Silenciar")
            }
            .toggleStyle(.button)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Panel

private struct ControlPanel: View {
    @ObservedObject var model: AppModel

    // El plegado vive aca y no en cada seccion para que sobreviva a los
    // redibujos y para poder abrir la app con lo importante a la vista.
    @State private var showPresets = true
    @State private var showSource = true
    @State private var showGrid = true
    @State private var showCharset = false
    @State private var showExport = false
    @State private var showEdges = true
    @State private var showTemporal = false
    @State private var showMatrix = true
    @State private var showCoverage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: "Presets", systemImage: "square.stack.3d.up", isExpanded: $showPresets) {
                    presetContent
                }
                Divider()
                PanelSection(title: "Fuente", systemImage: "video", isExpanded: $showSource) {
                    sourceContent
                }
                Divider()
                PanelSection(title: "Grid", systemImage: "grid", isExpanded: $showGrid) {
                    gridContent
                }
                Divider()
                PanelSection(title: "Charset", systemImage: "textformat", isExpanded: $showCharset) {
                    charsetContent
                }
                Divider()
                PanelSection(title: "Export", systemImage: "square.and.arrow.down", isExpanded: $showExport) {
                    exportContent
                }
                Divider()
                PanelSection(title: "Bordes", systemImage: "scribble", isExpanded: $showEdges) {
                    edgesContent
                }
                Divider()
                PanelSection(title: "Temporal", systemImage: "waveform.path", isExpanded: $showTemporal) {
                    temporalContent
                }
                Divider()
                PanelSection(title: "Matrix", systemImage: "cloud.rain", isExpanded: $showMatrix) {
                    matrixContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(.background)
    }

    // MARK: Presets

    private var presetContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            Picker("", selection: Binding(
                get: { model.currentPresetName ?? "" },
                set: { if !$0.isEmpty { model.loadPreset(named: $0) } }
            )) {
                Text(model.currentPresetName == nil ? "— sin preset —" : "— elegir —").tag("")
                ForEach(model.presetNames, id: \.self) { name in Text(name).tag(name) }
            }
            .labelsHidden()
            .controlSize(.small)

            HStack(spacing: 6) {
                Button("Guardar…") { promptSavePreset() }
                if let current = model.currentPresetName {
                    Button("Actualizar") { model.savePreset(named: current) }
                    Button(role: .destructive) {
                        model.deletePreset(named: current)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Borrar «\(current)»")
                }
                Spacer()
                Button {
                    model.revealPresetsFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Abrir la carpeta de presets en Finder")
            }
            .controlSize(.small)

            Text("El estado se guarda solo y vuelve al abrir la app.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    /// NSAlert y no un sheet de SwiftUI: es un campo de texto y un boton, y el
    /// panel modal de AppKit no necesita estado extra en la vista.
    private func promptSavePreset() {
        let alert = NSAlert()
        alert.messageText = "Guardar preset"
        alert.informativeText = "Se guarda como JSON en la carpeta de presets."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = model.currentPresetName ?? "Preset 1"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            model.savePreset(named: field.stringValue)
        }
    }

    // MARK: Fuente

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            Picker("", selection: $model.sourceKind) {
                ForEach(SourceKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch model.sourceKind {
            case .camera:
                Picker("", selection: Binding(
                    get: { model.selectedCameraID ?? "" },
                    set: { model.selectedCameraID = $0.isEmpty ? nil : $0 }
                )) {
                    if model.cameras.isEmpty { Text("— ninguna —").tag("") }
                    ForEach(model.cameras) { camera in Text(camera.name).tag(camera.id) }
                }
                .labelsHidden()
                .controlSize(.small)

                HStack(spacing: 6) {
                    Button { model.refreshCameras() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Actualizar la lista de cámaras")
                    Spacer()
                    if model.isRunning {
                        Button("Detener") { model.stopCapture() }
                    } else {
                        Button("Iniciar") { Task { await model.startCapture() } }
                    }
                }
                .controlSize(.small)

            case .file:
                HStack(spacing: 6) {
                    Button("Abrir video…") { openMovie() }
                    Spacer()
                }
                .controlSize(.small)

                Text(model.fileURL?.lastPathComponent ?? "Ningún archivo")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ParamReadout(label: "Entrada", value: model.format?.pretty ?? "—")
        }
    }

    // MARK: Grid

    private var gridContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            Picker("", selection: $model.tileWidth) {
                ForEach(model.tileSizes, id: \.self) { size in Text("\(size)").tag(size) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            ParamToggle(label: "Aspecto de la fuente", isOn: $model.aspectFollowsFont,
                        help: "El alto de celda sigue el aspecto natural de la fuente. Apagalo para deformar el glifo a propósito.")

            ParamSlider(label: "Aspecto", value: $model.cellAspect, range: 0.5...3.0)
                .disabled(model.aspectFollowsFont)

            ParamReadout(label: "Celda", value: "\(model.config.tileSize.x)×\(model.config.tileSize.y) px")
            ParamReadout(label: "Salida", value: "\(model.config.outputSize.x)×\(model.config.outputSize.y)")
            ParamReadout(label: "Grid", value: "\(model.config.gridSize.x) × \(model.config.gridSize.y)")

            if let warning = model.gridWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            ParamToggle(label: "ASCII", isOn: $model.asciiEnabled,
                        help: "Apagado muestra la imagen cruda, para comparar.")
        }
    }

    // MARK: Charset

    private var charsetContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { model.selectedFont },
                    set: { model.setFont($0) }
                )) {
                    ForEach(FontSelection.systemDefaults, id: \.self) { font in
                        Text(font.displayName).tag(font)
                    }
                    if case .file = model.selectedFont {
                        Text(model.selectedFont.displayName).tag(model.selectedFont)
                    }
                }
                .labelsHidden()

                Button { openFont() } label: { Image(systemName: "plus") }
                    .help("Cargar un .ttf/.otf")
            }
            .controlSize(.small)

            TextField("", text: $model.charsetText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(2...5)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                .onSubmit { model.applyCharset() }

            HStack(spacing: 6) {
                Button("Recalibrar") { model.applyCharset() }
                Button("Default") { model.resetCharset() }
                Spacer()
            }
            .controlSize(.small)

            ParamReadout(label: "Rampa", value: "\(model.ramp.count) / \(model.coverage.count)")

            DisclosureGroup(isExpanded: $showCoverage) {
                CoverageTable(model: model)
            } label: {
                Text("Cobertura calibrada")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Export

    private var exportContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            Picker("", selection: $model.exportCodec) {
                ForEach(ExportCodec.allCases) { codec in Text(codec.rawValue).tag(codec) }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(model.isRecording)

            Text(model.exportCodec == .h264
                 ? "Bitrate a ~3× de lo normal: el ASCII es el peor caso para un codec de transformada."
                 : "ProRes: sin pérdida perceptible, pesado. Es lo que va a post.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRecording {
                ParamReadout(label: "Escritos", value: "\(model.recordStats.framesWritten)")
                ParamReadout(label: "Perdidos", value: "\(model.recordStats.framesDropped)")
            }

            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Render offline")
            Text("Desacoplado del reloj: cada frame de entrada produce uno de salida.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Renderizar archivo…") { model.startOfflineRender() }
                .controlSize(.small)
                .disabled(model.fileURL == nil || model.isRendering)

            if let summary = model.lastRenderSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: Bordes

    private var edgesContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            ParamToggle(label: "Glifos de borde", isOn: $model.edgesEnabled,
                        help: "Apagado deja solo la rampa de luminancia, para comparar.")

            VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
                ParamSlider(label: "Umbral", value: $model.edgeThreshold, range: 0...1,
                            help: "Por encima de esto el tile usa - / | \\ en vez de rampa.")
                PanelGroupLabel(text: "Diferencia de gaussianas")
                ParamSlider(label: "Sigma 1", value: $model.dogSigma1, range: 0.2...4)
                ParamSlider(label: "Sigma 2", value: $model.dogSigma2, range: 0.5...10)
                ParamSlider(label: "Tau", value: $model.dogTau, range: 0...1.2,
                            help: "Cuánto se resta la gaussiana ancha. Cerca de 1 queda casi solo borde.")
            }
            .disabled(!model.edgesEnabled)
            .opacity(model.edgesEnabled ? 1 : 0.45)
        }
    }

    // MARK: Temporal

    private var temporalContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            ParamSlider(label: "Histéresis", value: $model.hysteresisThreshold, range: 0...0.5,
                        help: "En 0 es el comportamiento clásico y la rampa hierve. 0,08 es el default.")

            PanelGroupLabel(text: "Exposición")
            ParamToggle(label: "Lock de cámara", isOn: $model.exposureLocked,
                        help: model.supportsExposureLock
                            ? "Congela exposición y balance de blancos en el hardware."
                            : "Esta cámara no soporta lock de exposición.")
                .disabled(!model.supportsExposureLock)

            ParamSlider(label: "Auto nivel", value: $model.autoLevelStrength, range: 0...1,
                        help: "Mezcla entre luma cruda y normalizada.")
            ParamSlider(label: "Suavizado", value: $model.lumaSmoothAlpha, range: 0.01...0.5,
                        help: "Alpha de la media móvil. Chico reacciona lento pero no persigue al AGC.")
            ParamSlider(label: "Punto medio", value: $model.lumaTarget, range: 0.2...0.8)
                .disabled(model.autoLevelStrength <= 0)
        }
    }

    // MARK: Matrix

    private var matrixContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            ParamToggle(label: "Lluvia de glifos", isOn: $model.matrixEnabled)

            // El .disabled va sobre los parametros, no sobre la seccion: si
            // envuelve al toggle tambien se deshabilita a si mismo.
            VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
                PanelGroupLabel(text: "Gota")
                ParamSlider(label: "Velocidad", value: $model.matrixSpeed, range: 1...60, decimals: 0)
                ParamSlider(label: "Densidad", value: $model.matrixDensity, range: 1...12, decimals: 0,
                            help: "Gotas simultáneas por columna.")
                ParamSlider(label: "Rastro", value: $model.matrixTrail, range: 3...60, decimals: 0)
                ParamSlider(label: "Mutación", value: $model.matrixChurn, range: 0...40, decimals: 0,
                            help: "Cambios de glifo por segundo dentro del rastro.")

                PanelGroupLabel(text: "Imagen")
                ParamSlider(label: "Peso", value: $model.matrixImageMix, range: -1...1,
                            help: "Positivo: llueve en la luz. Cero: parejo. Negativo: llueve en las sombras.")
                ParamSlider(label: "Fondo", value: $model.matrixBaseLevel, range: 0...1,
                            help: "Brillo del ASCII fuera del rastro.")

                PanelGroupLabel(text: "Origen")
                ParamSlider(label: "Nacer brillo", value: $model.matrixSpawnBias, range: 0...1,
                            help: "0 nace arriba de todo, 1 en la celda más brillante de la columna.")
                ParamSlider(label: "Fuerza", value: $model.matrixSpawnStrength, range: 0...1,
                            help: "Cuánto modula el brillo del origen la intensidad de la gota.")

                PanelGroupLabel(text: "Volumen")
                ParamSlider(label: "Relieve", value: $model.matrixRelief, range: -24...24, decimals: 0,
                            help: "Celdas que se adelanta o atrasa el frente según la altura.")
                ParamSlider(label: "Suavizado", value: $model.reliefRadius, range: 0...16, decimals: 0,
                            help: "Difumina la altura para que siga la forma y no la textura.")
                ParamToggle(label: "Detectar sujeto", isOn: $model.subjectMatteEnabled,
                            help: "Segmentación de persona por Vision, en la Neural Engine.")
                ParamSlider(label: "Peso sujeto", value: $model.matteWeight, range: 0...1)
                    .disabled(!model.subjectMatteEnabled)

                PanelGroupLabel(text: "Punta")
                HStack(spacing: 8) {
                    ParamToggle(label: "En color", isOn: $model.matrixHeadTintEnabled)
                    Spacer()
                    ColorPicker("", selection: $model.matrixHeadColor, supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!model.matrixHeadTintEnabled)
                }
                ParamSlider(label: "Caracteres", value: $model.matrixHeadCells, range: 1...20, decimals: 0)
                    .disabled(!model.matrixHeadTintEnabled)
            }
            .disabled(!model.matrixEnabled)
            .opacity(model.matrixEnabled ? 1 : 0.45)
        }
    }

    // MARK: Paneles de archivo

    private func openMovie() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openFile(url)
        }
    }

    private func openFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("public.truetype-font") ?? .data,
                                     UTType("public.opentype-font") ?? .data,
                                     UTType("public.font") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.setFont(.file(url: url))
        }
    }
}

/// Spec §2: el usuario tiene que poder ver por que un caracter cayo donde cayo,
/// y sacarlo del set. Va ordenada por cobertura, no por tipeo — asi la lista
/// *es* la rampa, leida de arriba a abajo.
private struct CoverageTable: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 1) {
            ForEach(sorted) { glyph in
                HStack(spacing: 7) {
                    Toggle("", isOn: Binding(
                        get: { glyph.included },
                        set: { model.setExcluded(glyph.character, !$0) }
                    ))
                    .labelsHidden()
                    .controlSize(.mini)

                    Text(glyph.label)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 14)
                        .opacity(glyph.included ? 1 : 0.35)

                    // La barra hace evidente de un vistazo si la fuente tiene
                    // huecos o amontonamientos en la rampa.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(glyph.included ? Color.accentColor : Color.secondary)
                                .frame(width: max(2, geo.size.width * glyph.coverage))
                        }
                    }
                    .frame(height: 4)

                    Text(String(format: "%.2f", glyph.coverage))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
                .opacity(glyph.included ? 1 : 0.55)
            }
        }
        .padding(.top, 6)
    }

    private var sorted: [GlyphCoverage] {
        model.coverage.sorted { $0.coverage < $1.coverage }
    }
}

/// Spec §12: los errores se ven. Se apilan abajo del preview hasta que el
/// usuario los descarta.
private struct ErrorBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.errors) { error in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("[\(error.stage.rawValue)] \(error.message)")
                            .font(.system(size: 11, design: .monospaced))
                        if let detail = error.detail {
                            Text(detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.dismiss(error)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(12)
    }
}
