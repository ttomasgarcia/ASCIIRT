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

            // El arrastre va sobre una capa transparente encima del preview y
            // no sobre el MTKView: la vista de Metal no participa del layout de
            // SwiftUI y necesitariamos el tamano en pixeles para convertir.
            if model.sourceKind == .eye {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    // El preview esta centrado con aspect fit, asi
                                    // que hay que descontar las bandas antes de
                                    // normalizar o el ojo se corre.
                                    let fitted = fittedRect(in: geo.size, aspect: model.outputSize)
                                    guard fitted.width > 0, fitted.height > 0 else { return }
                                    let x = (value.location.x - fitted.minX) / fitted.width
                                    let y = (value.location.y - fitted.minY) / fitted.height
                                    model.eyeCenter = CGPoint(x: min(max(x, -0.5), 1.5),
                                                              y: min(max(y, -0.5), 1.5))
                                }
                        )
                }
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

    /// Rectangulo que ocupa el preview dentro del contenedor, con aspect fit.
    private func fittedRect(in container: CGSize, aspect: CGSize) -> CGRect {
        guard aspect.width > 0, aspect.height > 0 else { return .zero }
        let scale = min(container.width / aspect.width, container.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
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
    @State private var showEye = true
    @State private var showColor = false
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
                if model.sourceKind == .eye {
                    Divider()
                    PanelSection(title: "Ojo", systemImage: "circle.circle", isExpanded: $showEye) {
                        eyeContent
                    }
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
                PanelSection(title: "Color", systemImage: "paintpalette", isExpanded: $showColor) {
                    colorContent
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
            presetPicker("Look", names: model.lookPresets, current: model.currentLook)
            presetPicker("Movimiento", names: model.motionPresets, current: model.currentMotion)
            presetPicker("Escena", names: model.fullPresets, current: model.currentPresetName)

            HStack(spacing: 6) {
                Button("Guardar…") { promptSavePreset() }
                Spacer()
                Button {
                    model.revealPresetsFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Abrir la carpeta de presets en Finder")
            }
            .controlSize(.small)

            Text("Look y movimiento son independientes: cargar uno no toca al otro. Escena guarda los dos juntos.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetPicker(_ label: String, names: [String], current: String?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Picker("", selection: Binding(
                get: { current ?? "" },
                set: { if !$0.isEmpty { model.loadPreset(named: $0) } }
            )) {
                Text("—").tag("")
                ForEach(names, id: \.self) { name in Text(name).tag(name) }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(names.isEmpty)

            // El borrar vive en la fila del cajon, no en un boton global: sin
            // eso solo se podia borrar lo que estuviera cargado, y los presets
            // de look y de movimiento no siempre lo estan.
            Button(role: .destructive) {
                if let current { confirmDelete(current) }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(current == nil)
            .help(current.map { "Borrar «\($0)»" } ?? "Elegí un preset para borrarlo")
        }
    }

    /// Borrar un archivo del usuario merece una confirmacion: es un click de
    /// distancia del selector y no hay deshacer.
    private func confirmDelete(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "¿Borrar «\(name)»?"
        alert.informativeText = "El archivo se elimina de la carpeta de presets. No se puede deshacer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Borrar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            model.deletePreset(named: name)
        }
    }

    /// NSAlert y no un sheet de SwiftUI: son dos controles y el panel modal de
    /// AppKit no necesita estado extra en la vista.
    private func promptSavePreset() {
        let alert = NSAlert()
        alert.messageText = "Guardar preset"
        alert.informativeText = "El alcance decide qué toca al cargarlo."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.stringValue = model.currentPresetName ?? "Preset 1"
        container.addSubview(field)

        let scopePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        scopePopup.addItems(withTitles: ["Escena (todo)", "Solo look", "Solo movimiento"])
        container.addSubview(scopePopup)

        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let scope: PresetScope = [.full, .look, .motion][scopePopup.indexOfSelectedItem]
        model.savePreset(named: field.stringValue, scope: scope)
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

            case .eye:
                Text("Fuente generativa. Arrastrá sobre el preview para mover el ojo.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ParamReadout(label: "Entrada", value: model.format?.pretty ?? "—")
        }
    }

    // MARK: Ojo

    private var eyeContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            if model.colorMode != .original {
                Label("El iris rojo se ve con Color → Original.", systemImage: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelGroupLabel(text: "Forma", help: "Geometría del ojo: núcleo caliente, cuerpo del iris y su caída.")
            ParamSlider(label: "Radio", value: $model.eyeRadius, range: 0.02...0.45,
                        decimals: 3, help: "Relativo al lado corto de la salida.")
            ParamSlider(label: "Núcleo", value: $model.eyeCoreRadius, range: 0.02...0.8,
                        help: "Fracción del radio que quema a blanco. Es lo único que llega a los glifos más densos.")
            ParamSlider(label: "Dureza", value: $model.eyeFalloff, range: 0.3...8,
                        help: "Exponente de la caída del iris. Alto = borde duro.")

            PanelGroupLabel(text: "Anillo de lente", help: "Aro fino en el borde del iris. Existe para que el detector de bordes trace el contorno con - / | \\ en vez de dejar una mancha.")
            ParamSlider(label: "Ancho", value: $model.eyeRingWidth, range: 0.005...0.4, decimals: 3,
                        help: "Grosor del aro, como fracción del radio. Fino se lee como lente; ancho se funde con el iris.")
            ParamSlider(label: "Intensidad", value: $model.eyeRingIntensity, range: 0...2,
                        help: "El anillo existe para que el detector de bordes trace el contorno con - / | \\.")

            PanelGroupLabel(text: "Halo", help: "El campo tenue que rodea al ojo. Es de donde sale el código de alrededor.")
            ParamSlider(label: "Radio", value: $model.eyeHaloRadius, range: 0.02...1.5,
                        help: "Hasta dónde llega el campo. Grande lo desparrama por toda la pantalla; chico lo deja pegado al ojo.")
            ParamSlider(label: "Intensidad", value: $model.eyeHaloIntensity, range: 0...1,
                        help: "Hace que el código de alrededor se densifique hacia el centro.")

            HStack(spacing: 8) {
                ParamLabel(text: "Iris", help: "Color del cuerpo del ojo. El núcleo quema a blanco por encima de este color, así que un rojo saturado igual da centro blanco.")
                ColorPicker("", selection: $model.eyeIrisColor, supportsOpacity: false)
                    .labelsHidden()
                Spacer()
            }

            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Pleno", help: "Saca al ojo del ASCII y lo pinta como forma llena, para que pegue más fuerte que el código.")
            ParamSlider(label: "Mezcla", value: $model.eyeSolidAmount, range: 0...1,
                        help: "0 = el ojo es sólo glifos. 1 = disco pleno por encima del ASCII.")
            ParamSlider(label: "Intensidad", value: $model.eyeSolidGain, range: 0...3,
                        help: "Por encima de 1 el ojo pega más fuerte que el código que lo rodea.")
            ParamSlider(label: "Borde", value: $model.eyeSolidEdge, range: 0...1,
                        help: "0 respeta la caída del iris. 1 corta en disco de borde duro.")

            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Respiración", help: "Oscilación lenta del radio. Es lo que hace que el ojo parezca vivo aunque no se mueva de lugar.")
            ParamSlider(label: "Amplitud", value: $model.eyeBreathAmount, range: 0...0.3, decimals: 3,
                        help: "Cuánto crece y decrece el radio, en fracción. 0,03 es casi imperceptible; 0,2 late fuerte.")
            ParamSlider(label: "Velocidad", value: $model.eyeBreathSpeed, range: 0.01...2,
                        help: "Ciclos por segundo. Por debajo de 0,2 respira; por encima de 0,8 palpita.")

            PanelGroupLabel(text: "Pulsos de energía", help: "Ondas que salen del centro. Como todo pasa por la rampa, no se ven como resplandor sino como una ola de caracteres cambiando de densidad.")
            ParamSlider(label: "Amplitud", value: $model.eyePulseAmount, range: 0...0.6,
                        help: "Fuerza de la onda. Alto puede saturar el campo y tapar el degradado del halo.")
            ParamSlider(label: "Velocidad", value: $model.eyePulseSpeed, range: 0...1,
                        help: "Qué tan rápido viaja la onda hacia afuera. En 0 queda congelada como anillos fijos.")
            ParamSlider(label: "Frecuencia", value: $model.eyePulseFrequency, range: 0.5...20, decimals: 1,
                        help: "Cuántas ondas hay a la vez. Alto da anillos finos y juntos; bajo, una sola onda ancha.")
            ParamSlider(label: "Caída", value: $model.eyePulseDecay, range: 0...8, decimals: 1,
                        help: "Cuánto se apaga la onda con la distancia.")

            PanelGroupLabel(text: "Campo de código", help: "El grano que convierte el degradado del halo en textura de caracteres.")
            ParamSlider(label: "Grano", value: $model.eyeFieldNoise, range: 0...1.5,
                        help: "Rompe las bandas concéntricas que produce un degradado liso sobre la rampa.")
            ParamSlider(label: "Refresco", value: $model.eyeFieldChurn, range: 0...30, decimals: 1,
                        help: "Cambios por segundo del grano. Alto = el código se refresca solo.")

            PanelGroupLabel(text: "Mirada", help: "Cómo recorre la pantalla. Genera el objetivo; el resorte se encarga de llegar.")
            Picker("", selection: $model.gazeMode) {
                ForEach(GazeMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .labelsHidden()
            .controlSize(.small)

            ParamSlider(label: "Ritmo", value: $model.gazeRate, range: 0.02...3,
                        help: "Barridos o saltos por segundo.")
            ParamSlider(label: "Alcance X", value: $model.gazeExtentX, range: 0...0.5, decimals: 3,
                        help: "Un público es ancho y bajo: barrer mucho más en X es lo que hace que parezca que recorre butacas.")
            ParamSlider(label: "Alcance Y", value: $model.gazeExtentY, range: 0...0.3, decimals: 3,
                        help: "Cuánto sube y baja. Conviene mucho menor que el alcance en X: un público es ancho y bajo.")
            if model.gazeMode == .scan {
                ParamSlider(label: "Paradas", value: $model.gazeStops, range: 2...16, decimals: 0,
                            help: "Cuántas posiciones recorre antes de volver.")
            }

            PanelGroupLabel(text: "Físico", help: "Cómo viaja hasta el objetivo. Es lo que separa un movimiento vivo de un cursor.")
            ParamSlider(label: "Rigidez", value: $model.eyeStiffness, range: 1...80, decimals: 1,
                        help: "Cuánto tira el resorte hacia el objetivo. Alto = va derecho y rápido.")
            ParamSlider(label: "Rozamiento", value: $model.eyeDamping, range: 0.5...30, decimals: 1,
                        help: "Por debajo de 2·√rigidez el ojo sobrepasa y rebota al llegar. Ahí es donde se siente vivo.")
            Text(dampingNote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            PanelGroupLabel(text: "Temblor", help: "Micro-movimiento permanente, encima de cualquier mirada.")
            ParamSlider(label: "Amplitud", value: $model.eyeDriftAmount, range: 0...0.08, decimals: 4,
                        help: "Se suma siempre, encima de cualquier mirada. Sin él los modos con pausa se ven congelados.")
            ParamSlider(label: "Velocidad", value: $model.eyeDriftSpeed, range: 0.01...2,
                        help: "Frecuencia del temblor. Alto se lee como vibración; bajo, como respiración de la posición.")

            HStack {
                Button("Centrar") { model.centerEye() }
                    .help("Manda el ojo al centro dejando que el resorte lo lleve.")
                Button("Fijar") { model.snapEyeToCenter() }
                    .help("Salta al centro sin animación. Para dejarlo listo antes de que entre gente.")
                Spacer()
                Text(String(format: "%.3f, %.3f", model.eyeCenter.x, model.eyeCenter.y))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .controlSize(.small)
        }
    }

    /// El punto critico es donde deja de rebotar. Decirlo evita que haya que
    /// descubrirlo moviendo dos sliders a ciegas.
    private var dampingNote: String {
        let critical = 2 * (model.eyeStiffness).squareRoot()
        if model.eyeDamping < critical * 0.85 {
            return String(format: "Rebota al llegar. Crítico en %.1f.", critical)
        } else if model.eyeDamping > critical * 1.25 {
            return String(format: "Llega lento y sin rebote. Crítico en %.1f.", critical)
        }
        return String(format: "Cerca del crítico (%.1f): llega sin pasarse.", critical)
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

            ParamSlider(label: "Aspecto", value: $model.cellAspect, range: 0.5...3.0,
                        help: "Alto dividido ancho de la celda. 1 la hace cuadrada y el glifo sale estirado a lo ancho; ~2 es el aspecto natural de una monoespaciada.")
                .disabled(model.aspectFollowsFont)

            ParamReadout(label: "Celda", value: "\(model.config.tileSize.x)×\(model.config.tileSize.y) px",
                         help: "Tamaño de cada celda en píxeles. Cuanto más chica, más caracteres entran y más detalle, pero menos se lee cada glifo.")
            ParamReadout(label: "Salida", value: "\(model.config.outputSize.x)×\(model.config.outputSize.y)",
                         help: "Resolución del render. Se fija en Export; el grid se deriva de ella, nunca al revés.")
            ParamReadout(label: "Grid", value: "\(model.config.gridSize.x) × \(model.config.gridSize.y)",
                         help: "Columnas × filas de caracteres. Es la resolución real de la imagen ASCII.")

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

            ParamReadout(label: "Rampa", value: "\(model.ramp.count) / \(model.coverage.count)",
                         help: "Glifos en uso sobre glifos del charset. La rampa se arma midiendo la tinta de cada glifo y ordenándolos de más claro a más denso.")

            DisclosureGroup(isExpanded: $showCoverage) {
                CoverageTable(model: model)
            } label: {
                Text("Cobertura calibrada")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Color

    private var colorContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            HStack(spacing: 6) {
                Picker("", selection: $model.colorMode) {
                    ForEach(AppModel.ColorMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Mono: tinta sobre negro. Dos colores: tinta y fondo a elección. Original: cada carácter toma el color promedio de su celda en la imagen.")
            }

            HStack(spacing: 8) {
                Text(model.colorMode == .original ? "Fondo" : "Tinta")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: PanelMetrics.labelWidth, alignment: .leading)
                if model.colorMode == .original {
                    ColorPicker("", selection: $model.backgroundColor, supportsOpacity: false)
                        .labelsHidden()
                } else {
                    ColorPicker("", selection: $model.foregroundColor, supportsOpacity: false)
                        .labelsHidden()
                    if model.colorMode == .duotone {
                        Text("Fondo").font(.system(size: 11)).foregroundStyle(.secondary)
                        ColorPicker("", selection: $model.backgroundColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Spacer()
            }

            ParamToggle(label: "Invertir", isOn: $model.invert,
                        help: "Cambia quién es tinta y quién es fondo. No es el negativo fotográfico.")
            ParamToggle(label: "Fondo transparente", isOn: $model.transparentBackground,
                        help: "Solo lo conserva ProRes 4444 y la secuencia PNG; el resto lo aplasta contra negro.")

            if model.transparentBackground && !model.exportCodec.supportsAlpha {
                Label("«\(model.exportCodec.rawValue)» no lleva alpha.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Export

    private var exportContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            PanelGroupLabel(text: "Resolución de salida", help: "Tamaño del render. «Fuente» la toma de la cámara o del archivo; los presets la fijan y la imagen se encuadra dentro.")
            Picker("", selection: $model.outputPreset) {
                ForEach(AppModel.OutputPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            PanelGroupLabel(text: "Formato", help: "Destino del REC y del render offline. ProRes para post, H.264 para mandar, secuencia PNG para máxima calidad con alpha.")
            Picker("", selection: $model.exportCodec) {
                ForEach(ExportCodec.allCases) { codec in Text(codec.rawValue).tag(codec) }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(model.isRecording)

            Text(exportNote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRecording {
                ParamReadout(label: "Escritos", value: "\(model.recordStats.framesWritten)")
                ParamReadout(label: "Perdidos", value: "\(model.recordStats.framesDropped)")
            }

            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Render offline", help: "Procesa un archivo cuadro a cuadro sin reloj: cada frame de entrada da exactamente uno de salida, tarde lo que tarde.")
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
                PanelGroupLabel(text: "Diferencia de gaussianas", help: "Dos desenfoques restados. Lo que queda son los bordes: la diferencia entre un desenfoque fino y uno grueso es justamente el detalle.")
                ParamSlider(label: "Sigma 1", value: $model.dogSigma1, range: 0.2...4,
                            help: "Radio del desenfoque fino. Chico detecta bordes finos; grande los engorda.")
                ParamSlider(label: "Sigma 2", value: $model.dogSigma2, range: 0.5...10,
                            help: "Radio del desenfoque grueso. Tiene que ser mayor que Sigma 1; cuanto más lejos, más ancho el borde detectado.")
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
            ParamSlider(label: "Arrastre", value: $model.trailDecay, range: 0...0.98,
                        help: "Cuánto sobrevive el campo del frame anterior. Deja estela al moverse, como el fósforo de un tubo.")
            ParamSlider(label: "Histéresis", value: $model.hysteresisThreshold, range: 0...3,
                        help: "Zona muerta en escalones de rampa. En 0 la rampa hierve; por encima de ~2 los cambios lentos se atrasan.")

            PanelGroupLabel(text: "Exposición", help: "El AGC de la cámara mueve la luminancia media constantemente y la rampa hierve aunque la escena esté quieta. Esto lo corrige.")
            ParamToggle(label: "Lock de cámara", isOn: $model.exposureLocked,
                        help: model.supportsExposureLock
                            ? "Congela exposición y balance de blancos en el hardware."
                            : "Esta cámara no soporta lock de exposición.")
                .disabled(!model.supportsExposureLock)

            ParamSlider(label: "Auto nivel", value: $model.autoLevelStrength, range: 0...1,
                        help: "Mezcla entre luma cruda y normalizada.")
            ParamSlider(label: "Suavizado", value: $model.lumaSmoothAlpha, range: 0.01...0.5,
                        help: "Alpha de la media móvil. Chico reacciona lento pero no persigue al AGC.")
            ParamSlider(label: "Punto medio", value: $model.lumaTarget, range: 0.2...0.8,
                        help: "A qué luminancia se lleva el promedio de la imagen. 0,5 la centra en la rampa; más alto la aclara.")
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
                PanelGroupLabel(text: "Gota", help: "Cada columna tiene su propia velocidad y fase, si no la lluvia se lee como una persiana bajando.")
                ParamSlider(label: "Velocidad", value: $model.matrixSpeed, range: 1...60, decimals: 0)
                ParamSlider(label: "Densidad", value: $model.matrixDensity, range: 1...12, decimals: 0,
                            help: "Gotas simultáneas por columna.")
                ParamSlider(label: "Rastro", value: $model.matrixTrail, range: 3...60, decimals: 0)
                ParamSlider(label: "Mutación", value: $model.matrixChurn, range: 0...40, decimals: 0,
                            help: "Cambios de glifo por segundo dentro del rastro.")

                PanelGroupLabel(text: "Imagen", help: "Cómo la imagen de fondo compuerta la lluvia.")
                ParamSlider(label: "Peso", value: $model.matrixImageMix, range: -1...1,
                            help: "Positivo: llueve en la luz. Cero: parejo. Negativo: llueve en las sombras.")
                ParamSlider(label: "Fondo", value: $model.matrixBaseLevel, range: 0...1,
                            help: "Brillo del ASCII fuera del rastro.")

                PanelGroupLabel(text: "Origen", help: "De dónde nace cada gota. Sirve para que el brillo emita en vez de solo iluminarse al pasar.")
                ParamSlider(label: "Nacer brillo", value: $model.matrixSpawnBias, range: 0...1,
                            help: "0 nace arriba de todo, 1 en la celda más brillante de la columna.")
                ParamSlider(label: "Fuerza", value: $model.matrixSpawnStrength, range: 0...1,
                            help: "Cuánto modula el brillo del origen la intensidad de la gota.")

                PanelGroupLabel(text: "Volumen", help: "La luminancia funciona como campo de altura y curva el frente de la lluvia sobre la forma.")
                ParamSlider(label: "Relieve", value: $model.matrixRelief, range: -24...24, decimals: 0,
                            help: "Celdas que se adelanta o atrasa el frente según la altura.")
                ParamSlider(label: "Suavizado", value: $model.reliefRadius, range: 0...16, decimals: 0,
                            help: "Difumina la altura para que siga la forma y no la textura.")
                ParamToggle(label: "Detectar sujeto", isOn: $model.subjectMatteEnabled,
                            help: "Segmentación de persona por Vision, en la Neural Engine.")
                ParamSlider(label: "Peso sujeto", value: $model.matteWeight, range: 0...1)
                    .disabled(!model.subjectMatteEnabled)

                PanelGroupLabel(text: "Punta", help: "Tinte de la cabeza de cada gota y de las primeras celdas del rastro.")
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

    private var exportNote: String {
        switch model.exportCodec {
        case .h264:
            return "Bitrate a ~3× de lo normal: el ASCII es el peor caso para un codec de transformada."
        case .pngSequence:
            return "Sin pérdida y con alpha. Solo en render offline; es el único destino donde el frame vuelve a CPU."
        case .proRes4444:
            return "El único formato de video acá que conserva el fondo transparente."
        case .proRes422HQ:
            return "Sin pérdida perceptible, pesado. Es lo que va a post."
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
