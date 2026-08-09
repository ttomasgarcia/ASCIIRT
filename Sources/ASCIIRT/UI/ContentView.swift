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
            // Lo que rodea al cuadro es un negro apenas mas claro que el negro
            // de la imagen. Con los dos en cero no habia forma de saber donde
            // termina la salida y donde empieza la ventana: un ojo cerca del
            // borde parecia estar adentro cuando en realidad ya estaba fuera de
            // cuadro. Es solo del preview — lo que se graba no lo lleva.
            Color(white: 0.09)
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
                                    // El preview esta centrado con aspect fit,
                                    // asi que hay que descontar las bandas antes
                                    // de normalizar o el ojo queda corrido
                                    // respecto del puntero.
                                    let fitted = fittedRect(in: geo.size, aspect: model.outputSize)
                                    guard fitted.width > 0, fitted.height > 0 else { return }
                                    let x = (value.location.x - fitted.minX) / fitted.width
                                    let y = (value.location.y - fitted.minY) / fitted.height
                                    // Camino rapido: no publica en cada evento.
                                    model.dragEye(to: CGPoint(x: min(max(x, -0.5), 1.5),
                                                              y: min(max(y, -0.5), 1.5)))
                                }
                                .onEnded { _ in
                                    // Al soltar, la mirada retoma su recorrido
                                    // desde donde quedo el ojo.
                                    model.endEyeDrag()
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
            // El tiempo de GPU al lado de los fps. Con archivo, los fps son los
            // del video —el preview dibuja cuando llega un cuadro— asi que solos
            // no dicen si la app llega o no. Los milisegundos si.
            if model.stats.gpuMilliseconds > 0 {
                Text(String(format: "%.1f ms", model.stats.gpuMilliseconds))
                    .foregroundStyle(model.stats.gpuMilliseconds > 12 ? .orange : .secondary)
            }
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
        // Los indicadores viven encima del preview: sin esto se comen los
        // clicks en las esquinas y arrastrar el ojo ahi no registra.
        .allowsHitTesting(false)
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
            .allowsHitTesting(false)
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
    @State private var showTrail = true
    @State private var showEye = true
    @State private var showColor = false
    @State private var showExport = false
    @State private var showEdges = true
    @State private var showTemporal = false
    @State private var showMatrix = true
    @State private var showEyeLife = true
    @State private var showEyeMotion = true
    @State private var showChat = true
    @State private var showGlitch = true
    @State private var showProject = true
    @State private var showCoverage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: "Proyecto", systemImage: "rectangle.ratio.16.to.9",
                             help: "La resolución a la que se genera todo. Está primero porque es la decisión que condiciona al resto: el grid se deriva de ella —nunca al revés— así que cambiarla cambia cuántos caracteres entran en pantalla y, con eso, el aspecto del efecto entero. Conviene fijarla al empezar y no tocarla más.",
                             isExpanded: $showProject) {
                    projectContent
                }
                Divider()
                PanelSection(title: "Presets", systemImage: "square.stack.3d.up",
                             help: "Tres cajones independientes. Un preset de «look» define la forma y el color del ojo; uno de «movimiento» define cómo recorre la pantalla; uno de «escena» guarda las dos cosas juntas. Cargar un look no pisa el recorrido y viceversa, así que probar diez looks contra diez recorridos es cuestión de clics y no de rehacer nada. Los archivos son JSON en una carpeta que podés abrir, versionar o mandar por mail.",
                             isExpanded: $showPresets) {
                    presetContent
                }
                Divider()
                PanelSection(title: "Fuente", systemImage: "video",
                             help: "De dónde sale la imagen. Cámara y Archivo transforman algo que entra; Ojo no tiene entrada, la genera. Los tres pasan por exactamente el mismo pipeline de abajo, así que todo lo que configures acá abajo funciona igual con cualquiera de los tres.",
                             isExpanded: $showSource) {
                    sourceContent
                }
                if model.sourceKind == .chat {
                    Divider()
                    PanelSection(title: "Chat", systemImage: "bubble.left.and.bubble.right",
                                 help: "Globos de diálogo escritos DIRECTO en la grilla, una letra por celda. La alternativa era dibujarlos en una imagen y dejar que el pipeline los convirtiera a ASCII como a cualquier fuente, pero a los tamaños de celda que se usan un texto pasado por la rampa queda ilegible — se lee como una mancha de densidad con forma de renglón. Escribiéndolos en la grilla el texto queda nítido y además la app dibuja lo que es: caracteres en una grilla.",
                                 isExpanded: $showChat) {
                        chatContent
                    }
                }

                // Las tres secciones del ojo estan separadas por lo que HACEN, y
                // el corte coincide con el alcance de los presets: forma y vida
                // son «look», movimiento y estela son «movimiento». Antes era una
                // sola seccion con todo adentro y la inercia aparecia dos veces,
                // en dos grupos distintos, con dos textos de ayuda distintos.
                if model.sourceKind == .eye {
                    Divider()
                    PanelSection(title: "Ojo · forma", systemImage: "circle.circle",
                             help: "Cómo es el ojo cuando está quieto: núcleo, iris, anillo de lente, halo y relleno. Está armado por capas y cada una tiene su función — el anillo, por ejemplo, existe para que el detector de bordes trace el contorno con caracteres en vez de dejar una mancha. Todo esto es lo que guarda un preset de «look».",
                             isExpanded: $showEye) {
                        eyeShapeContent
                    }
                    Divider()
                    PanelSection(title: "Ojo · vida", systemImage: "waveform.path.ecg",
                             help: "Lo que se mueve sin que el ojo cambie de lugar: respiración, parpadeo del núcleo, pulsos de energía y el grano del campo de código. Es lo que hace que la pantalla no parezca congelada cuando el ojo está fijo. Como todo pasa por la rampa, nada de esto se ve como brillo: se ve como caracteres cambiando de densidad. También es parte del «look».",
                             isExpanded: $showEyeLife) {
                        eyeLifeContent
                    }
                    Divider()
                    PanelSection(title: "Ojo · movimiento", systemImage: "scope",
                             help: "Cómo recorre la pantalla y cómo viaja hasta cada punto. La mirada genera un objetivo y el resorte se encarga de llegar: esa separación es lo que hace que el movimiento se lea como algo vivo y no como un cursor. Es lo que guarda un preset de «movimiento», independiente del look.",
                             isExpanded: $showEyeMotion) {
                        eyeMotionContent
                    }
                }

                Divider()
                PanelSection(title: "Estela", systemImage: "wind",
                             help: "El rastro que deja el movimiento. «Cantidad» es el control rápido: escribe de una vez el arrastre, la disgregación y la inercia del ojo, porque la estela no es sólo el eco — es también que el ojo vaya atrás del objetivo y se pase al llegar. Escribe valores reales, así que los sliders que toca se mueven y ves exactamente qué quedó puesto.",
                             isExpanded: $showTrail) {
                    trailContent
                }
                Divider()
                PanelSection(title: "Grid", systemImage: "grid",
                             help: "El tamaño de cada carácter y, por lo tanto, cuántos entran en pantalla. Es el compromiso central del efecto: celdas chicas dan más detalle en la imagen pero menos legibilidad en cada glifo. La resolución de salida manda y el grid se deriva de ella, nunca al revés.",
                             isExpanded: $showGrid) {
                    gridContent
                }
                Divider()
                PanelSection(title: "Charset", systemImage: "textformat",
                             help: "Qué caracteres se usan y con qué fuente. El orden no se asume: se rasteriza cada glifo, se mide cuánta tinta ocupa y se ordenan de más claro a más denso. Por eso cambiar de fuente reordena la rampa y cambia visiblemente la salida. Menos glifos dan escalones más marcados y se lee más como pantalla que como foto.",
                             isExpanded: $showCharset) {
                    charsetContent
                }
                Divider()
                PanelSection(title: "Color", systemImage: "paintpalette",
                             help: "Cómo se pinta el resultado. Mono y Dos colores usan las tintas que elijas; Original le da a cada carácter el color promedio de su celda en la imagen. El promedio por celda y no el color del píxel: pintando cada píxel del glifo con su color, el carácter se convierte en una ventana a la imagen y se pierde la lectura tipográfica.",
                             isExpanded: $showColor) {
                    colorContent
                }
                Divider()
                PanelSection(title: "Export", systemImage: "square.and.arrow.down",
                             help: "A dónde va la imagen. El botón REC de la barra graba en vivo lo que ves; el render offline procesa un archivo cuadro a cuadro sin reloj, garantizando que cada frame de entrada da uno de salida. El frame nunca vuelve a la CPU en ninguno de los dos caminos, salvo en secuencia PNG, que es compresión sobre bytes y no tiene ruta de hardware.",
                             isExpanded: $showExport) {
                    exportContent
                }
                Divider()
                PanelSection(title: "Bordes", systemImage: "scribble",
                             help: "Detección de contornos, para que los bordes se dibujen con - / | \\ en lugar de resolverse como manchas de densidad. Es lo que separa esto de un filtro de brillo. Los bordes ganan sobre la luminancia: si un tile tiene un contorno fuerte, se dibuja el contorno y no el tono.",
                             isExpanded: $showEdges) {
                    edgesContent
                }
                Divider()
                PanelSection(title: "Temporal", systemImage: "waveform.path",
                             help: "Todo lo que tiene que ver con el tiempo: cuánto dura la imagen de un frame en el siguiente, cuánto tiene que cambiar algo para que el carácter cambie, y cómo se compensa el automático de exposición de la cámara. Sin histéresis la salida hierve aunque la escena esté quieta, y eso es lo que más delata que es un filtro.",
                             isExpanded: $showTemporal) {
                    temporalContent
                }
                Divider()
                PanelSection(title: "Glitch", systemImage: "waveform.badge.exclamationmark",
                             help: "Corrupción del código, cuantizada a la celda. Nada se corre medio carácter, así que la grilla tipográfica nunca se rompe y el resultado sale duro y geométrico en vez de baboso. Va a ráfagas y no continuo: un glitch permanente deja de leerse como falla y pasa a ser textura. Todo sale de hashes del número de ráfaga, que es una función del tiempo, así que el render offline saca exactamente la misma secuencia de fallas que viste en pantalla.",
                             isExpanded: $showGlitch) {
                    glitchContent
                }
                Divider()
                PanelSection(title: "Matrix", systemImage: "cloud.rain",
                             help: "Lluvia de caracteres que mutan mientras caen. Convive con cualquier fuente: sobre cámara, sobre archivo o sobre el ojo. La imagen no queda tapada sino que compuerta la lluvia y le da relieve, así que la figura sigue leyéndose dentro del efecto.",
                             isExpanded: $showMatrix) {
                    matrixContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(.background)
    }

    // MARK: Proyecto

    private var projectContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            Picker("", selection: $model.outputPreset) {
                ForEach(AppModel.OutputPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if model.sourceKind != .eye {
                HStack(spacing: 6) {
                    Picker("", selection: $model.sourceFill) {
                        Text("Ajustar").tag(false)
                        Text("Llenar").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HelpMark("Qué hacer cuando la fuente y la salida no tienen la misma proporción. Ajustar: la imagen entra completa y lo que sobra queda negro. Llenar: la imagen se agranda hasta cubrir la salida y se recorta lo que se pasa. Con una cámara 16:9 y una salida de 2,11:1 la diferencia es entre dos franjas negras arriba y abajo, o perder los costados. Ajustar es el default porque recortar es perder imagen y eso no debería pasar sin que lo pidas.",
                             title: "Encuadre de la fuente")
                }
            }

            ParamReadout(label: "Salida", value: "\(model.config.outputSize.x)×\(model.config.outputSize.y)",
                         help: "Resolución a la que se genera todo. «Fuente» la toma de la cámara o del archivo; las demás la fijan y la imagen entra encuadrada dentro, con negro en lo que sobra — nunca se recorta en silencio. Para proyectar conviene fijarla a la resolución real del proyector, así lo que ves es exactamente lo que sale.")
            ParamReadout(label: "Aspecto", value: aspectNote,
                         help: "Proporción de la salida. 2432×1152 es 2,11:1, bastante más ancha que 16:9: el ojo se mide contra el lado corto, así que al pasar de una a otra no cambia de tamaño, pero le queda mucho más campo a los costados para el código y para que la mirada recorra.")
            ParamReadout(label: "Grid", value: "\(model.config.gridSize.x) × \(model.config.gridSize.y)",
                         help: "Cuántos caracteres entran, derivado de la resolución y del tamaño de celda. El tamaño de celda se elige en Grid.")
        }
    }

    /// Proporcion de la salida, en la forma en que se habla de ella.
    private var aspectNote: String {
        let w = Double(model.config.outputSize.x), h = Double(model.config.outputSize.y)
        guard h > 0 else { return "—" }
        return String(format: "%.2f:1", w / h)
    }

    // MARK: Presets

    private var presetContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            presetPicker("Look", names: model.lookPresets, current: model.currentLook,
                         help: "Forma y color del ojo: radio, núcleo, anillo, halo, pleno, gradiente, respiración, pulsos y grano. No toca el recorrido, así que podés cambiar de aspecto sin perder el movimiento que ya ajustaste.")
            // Un preset de movimiento son mirada, fisica, temblor y estela: todo
            // del ojo. Con camara o archivo el selector estaria ahi para cargar
            // algo que no cambia nada de lo que se ve.
            if model.sourceKind == .eye {
                presetPicker("Movimiento", names: model.motionPresets, current: model.currentMotion,
                             help: "Cómo recorre la pantalla: modo de mirada, ritmo, alcance, física del resorte, temblor y estela. No toca la forma del ojo. Los diez que vienen van de mirar fijo al frente a escanear la sala butaca por butaca.")
            }
            presetPicker("Escena", names: model.fullPresets, current: model.currentPresetName,
                         help: "Look y movimiento juntos, más todo lo demás: grid, charset, color, bordes, temporal y formato de export. Es lo que guardás cuando ya encontraste la combinación y no querés volver a armarla.")

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

            Text(model.sourceKind == .eye
                 ? "Look y movimiento son independientes: cargar uno no toca al otro. Escena guarda los dos juntos."
                 : "Los presets de movimiento son del ojo y aparecen al elegir esa fuente.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetPicker(_ label: String, names: [String], current: String?,
                              help: String) -> some View {
        HStack(spacing: 6) {
            ParamLabel(text: label, help: help)
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
            HStack(spacing: 6) {
                Picker("", selection: $model.sourceKind) {
                    ForEach(SourceKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Cámara: cualquier dispositivo del sistema, incluida la Continuity Camera del iPhone. Archivo: un video, con player propio y scrub cuadro a cuadro. Ojo: sin entrada, la imagen la genera el pipeline. Los tres terminan en el mismo lugar, así que todos los parámetros de abajo aplican igual.",
                         title: "Fuente")
            }

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

            case .chat:
                Text("Sin entrada: los mensajes se escriben directo en la grilla. El texto y los tiempos están en la sección Chat.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.sourceKind == .camera || model.sourceKind == .file {
                ParamReadout(label: "Entrada", value: model.format?.pretty ?? "—")
            }
        }
    }

    // MARK: Estela

    private var trailContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            ParamSlider(label: "Cantidad", value: $model.trailMacro, range: 0...1,
                        help: model.sourceKind == .eye
                            ? "El control rápido: escribe de una vez el arrastre, la disgregación y la histéresis. 0 apaga la estela. Después podés retocar cualquiera a mano; no los vuelve a pisar hasta que lo muevas de nuevo. No toca la inercia del ojo: eso es del recorrido y vive en los presets de movimiento."
                            : "El control rápido: escribe el arrastre y la disgregación de una vez, y baja la histéresis para acompañar. 0 apaga la estela.")

            PanelGroupLabel(text: "Rastro", help: "Cuánto sobrevive la imagen del frame anterior, y cómo se deshace. La estela es de caracteres: el disco, el aro y el núcleo del ojo no dejan rastro.")
            ParamSlider(label: "Arrastre", value: $model.trailSeconds, range: 0...3, decimals: 2,
                        help: "Cuánto tarda la cola en apagarse del todo, en segundos. Es el mismo mecanismo que el fósforo de un tubo. Antes este slider mostraba el factor de decaimiento, que es exponencial: de 0 a 0,55 había 138 ms de cola —nada visible— y todo el efecto estaba amontonado en el último 3% del recorrido. En segundos el paso es parejo y el número dice algo. Sirve para cualquier fuente, no sólo el ojo. La duración es real: no cambia con los fps ni al renderizar a otra velocidad.")
            ParamSlider(label: "Densidad", value: $model.trailDensity, range: 0...1,
                        help: "Con cuánta fuerza entra cada celda a la cola, respecto de lo que vale en la imagen. En 1 la cola arranca igual de densa que la fuente — que es lo que hacía siempre, y por eso el rastro se veía con el mismo peso pasara lo que pasara. Bajándolo, la celda cae de golpe a un glifo más ralo apenas el frente la deja atrás. Medido con Arrastre en 1 s, pasar de 1 a 0,35 baja las celdas encendidas cerca del ojo de 4,1% a 2,1%. Ojo: el ritmo de apagado no cambia, pero al arrancar más abajo la cola toca el piso antes, así que también llega algo menos lejos — con esos valores, unos 0,3 s menos. No lo toca el macro Cantidad.")
            ParamSlider(label: "Disgregación", value: $model.trailDisperse, range: 0...1,
                        help: "Cuánto varía el desvanecido celda por celda. En 0 la cola baja pareja y se apaga entera; subiéndolo, unas celdas llegan a cero antes que otras y la cola se agujerea a medida que envejece. No la acorta: el alcance máximo lo fija el Arrastre. Es la diferencia entre apagarse y deshacerse.")

            if model.sourceKind == .eye {
                ParamSlider(label: "Color", value: $model.trailTint, range: 0...1,
                            help: "De qué color queda la cola. En 0 lo que queda atrás toma el color del código: la estela se lee como caracteres. En 1 conserva el color del ojo, y como el cuerpo del ojo es una masa roja llena, la cola se lee como esa masa corriéndose por la pantalla — que es un efecto muy distinto y bastante más pesado. El valor se aplica por frame, así que en los intermedios el color del ojo sobrevive cerca del frente y se va perdiendo a lo largo del rastro.")
            }

            ParamSlider(label: "Histéresis", value: $model.hysteresisThreshold, range: 0...3, decimals: 2,
                        help: "Cuánto tiene que cambiar la luminancia de una celda para que cambie su carácter, medido en escalones de rampa. Con la cola larga conviene tenerla baja: retener glifos confunde el residuo de la histéresis con el rastro de verdad, y se ve como suciedad que no termina de apagarse. En 0 la salida hierve; por encima de 2 los cambios lentos se atrasan y el movimiento se ve pegajoso. «Cantidad» también la escribe.")


        }
    }

    // MARK: Ojo · forma

    private var eyeShapeContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            if model.colorMode != .original {
                Label("El iris rojo se ve con Color → Original.", systemImage: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelGroupLabel(text: "Forma", help: "Geometría del ojo: núcleo caliente, cuerpo del iris y su caída.")
            ParamSlider(label: "Radio", value: $model.eyeRadius, range: 0.02...0.45,
                        decimals: 3, help: "Tamaño del ojo, medido contra el lado corto de la pantalla para que no cambie al pasar de 16:9 a otro formato. Ojo con achicarlo: por debajo de unas 25 celdas de diámetro el círculo se lee como polígono, porque no hay caracteres suficientes para describir la curva. Si lo querés chico, bajá también el tamaño de celda en Grid.")
            ParamSlider(label: "Núcleo", value: $model.eyeCoreRadius, range: 0.02...0.8,
                        help: "Tamaño del punto blanco del centro, como fracción del radio. Es lo único de la imagen que llega a los glifos más densos de la rampa, así que si lo ponés en cero el centro se apaga y el ojo pierde el foco. Subirlo agranda el blanco y el color del iris queda relegado a un aro.")
            ParamSlider(label: "Dureza", value: $model.eyeFalloff, range: 0.3...8,
                        help: "Qué tan rápido se apaga el iris desde el centro hacia el borde. Valores bajos dan una mancha difusa que se funde con el fondo; valores altos dan un disco de borde marcado. Si querés que el ojo se lea como objeto y no como resplandor, subilo por encima de 3.")

            PanelGroupLabel(text: "Anillo de lente", help: "Aro fino en el borde del iris. Existe para que el detector de bordes trace el contorno con - / | \\ en vez de dejar una mancha.")
            ParamSlider(label: "Ancho", value: $model.eyeRingWidth, range: 0.005...0.4, decimals: 3,
                        help: "Grosor del anillo de lente. Fino se lee como el borde de una óptica; ancho se funde con el iris y el ojo pierde el contorno. Es el parámetro que más define si la cosa parece un objeto construido o una mancha luminosa.")
            ParamSlider(label: "Intensidad", value: $model.eyeRingIntensity, range: 0...2,
                        help: "Brillo del anillo. Además de verse, tiene una función técnica: el detector de bordes lo encuentra y dibuja el contorno del ojo con glifos direccionales, así que subirlo hace que el círculo salga trazado con caracteres en vez de aproximado por densidad. En cero desaparece esa lectura.")

            PanelGroupLabel(text: "Halo", help: "El campo tenue que rodea al ojo. Es de donde sale el código de alrededor.")
            ParamSlider(label: "Radio", value: $model.eyeHaloRadius, range: 0.02...1.2,
                        help: "Alcance del campo de código que rodea al ojo. Grande lo desparrama por toda la pantalla y el ojo deja de ser el centro de atención; chico lo deja pegado al ojo como un aura. Es el control principal de cuánta pantalla ocupa el efecto.")
            ParamSlider(label: "Intensidad", value: $model.eyeHaloIntensity, range: 0...1,
                        help: "Densidad del campo de alrededor. Como pasa por la rampa calibrada, subirlo hace que el código se vuelva más denso cerca del ojo y se ralee hacia afuera; ese degradado es lo que hace que el ojo parezca la fuente del código y no algo apoyado encima.")

            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Interior", help: "Qué pasa adentro del anillo: si hay código y de qué color es el iris.")

            ParamToggle(label: "Sin código adentro", isOn: $model.eyeHollow,
                        help: "Vacía de caracteres el área de adentro del anillo. El pleno y el aro se siguen dibujando: lo único que desaparece es el ASCII. Sirve cuando el ojo compite con el código y querés que sea una forma limpia con el código solo alrededor.")

            HStack(spacing: 6) {
                Picker("", selection: $model.eyeGradientMode) {
                    Text("Unicolor").tag(UInt32(0))
                    Text("Radial").tag(UInt32(1))
                    Text("Angular").tag(UInt32(2))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Unicolor: el iris es de un solo color. Radial: la transición corre del centro hacia el borde y las bandas viajan hacia afuera. Angular: la transición da la vuelta al ojo y los sectores giran. El angular es el que más vida le da al aro exterior, porque el movimiento se lee como algo circulando y no como un cambio de color.",
                         title: "Gradiente del iris")
            }

            HStack(spacing: 8) {
                ParamLabel(text: "Iris", help: "Color del iris. Si el gradiente está en Unicolor, es el color de todo el cuerpo; si no, es el extremo cercano de la transición. El núcleo quema a blanco por encima de este color, así que un rojo bien saturado igual te va a dar el centro blanco.")
                ColorPicker("", selection: $model.eyeIrisColor, supportsOpacity: false)
                    .labelsHidden()
                if model.eyeGradientMode != 0 {
                    ColorPicker("", selection: $model.eyeIrisOuterColor, supportsOpacity: false)
                        .labelsHidden()
                    HelpMark("Extremo lejano del gradiente. Es el color al que llega la transición; el otro extremo es el color de iris de al lado.", title: "Color exterior")
                }
                Spacer()
            }

            HStack(spacing: 8) {
                ParamLabel(text: "Núcleo", help: "Color del punto del centro. Era blanco fijo y con el gradiente animado ese blanco se comía el centro justo donde más se mira. Ponelo del color del iris para que el gradiente llegue hasta el medio, o de un color distinto para que el centro sea otro acento.")
                ColorPicker("", selection: $model.eyeCoreColor, supportsOpacity: false)
                    .labelsHidden()
                Spacer()
            }
            ParamSlider(label: "Fuerza núcleo", value: $model.eyeCoreBlend, range: 0...1,
                        help: "Cuánto pisa el núcleo al color del iris. En 1 el centro es del color de arriba; en 0 no pisa nada y el centro toma el color del gradiente, aportando solo luminancia. Bajalo si el gradiente animado se apaga en el medio.")

            if model.eyeGradientMode != 0 {
                ParamSlider(label: "Ciclos", value: $model.eyeGradientCycles, range: 0.5...12, decimals: 1,
                            help: "Cuántas veces se repite la transición de color a lo largo de su eje. En modo angular son los sectores que ves girar alrededor del aro; en radial son anillos concéntricos viajando. Con 1 hay una sola transición; con 6 o más aparece un patrón que se lee como energía circulando.")
                ParamSlider(label: "Animación", value: $model.eyeGradientSpeed, range: -2...2,
                            help: "Velocidad de la animación del gradiente. En 0 queda quieto y es solo un degradado; valores bajos dan un movimiento apenas perceptible que hace que el aro respire; negativo invierte el sentido de giro. Es el control que más vida le da al círculo exterior sin cambiar su forma.")
            }

            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Pleno", help: "Saca al ojo del ASCII y lo pinta como forma llena, para que pegue más fuerte que el código.")
            ParamSlider(label: "Mezcla", value: $model.eyeSolidAmount, range: 0...1,
                        help: "Cuánto reemplaza la forma llena al ASCII dentro del ojo. En 0 el ojo es puro código, con la textura del charset; en 1 es un disco limpio dibujado por encima. Los valores del medio dejan el glifo asomando por debajo, que suele ser el punto más interesante.")
            ParamSlider(label: "Intensidad", value: $model.eyeSolidGain, range: 0...3,
                        help: "Ganancia del pleno. Por encima de 1 el ojo brilla más fuerte que el código que lo rodea, que es exactamente para lo que existe: darle una jerarquía que el ASCII solo no puede. Muy alto satura a blanco y perdés el color del iris.")
            ParamSlider(label: "Borde", value: $model.eyeSolidEdge, range: 0...1,
                        help: "Dureza del borde del pleno. En 0 el relleno se desvanece siguiendo la caída natural del iris y se funde con el código; en 1 corta en disco de borde limpio. Subilo si querés que se lea como una forma geométrica y no como un resplandor.")
        }
    }

    // MARK: Ojo · vida

    private var eyeLifeContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            PanelGroupLabel(text: "Respiración", help: "Oscilación lenta del radio. Es lo que hace que el ojo parezca vivo aunque no se mueva de lugar.")
            ParamSlider(label: "Amplitud", value: $model.eyeBreathAmount, range: 0...0.3, decimals: 3,
                        help: "Cuánto crece y se achica el ojo al respirar, en fracción del radio. 0,03 es casi imperceptible y sirve para que no parezca una imagen congelada; 0,2 late fuerte y se lee como signo vital. Es lo más barato que podés hacer para que la pantalla no parezca trabada.")
            ParamSlider(label: "Velocidad", value: $model.eyeBreathSpeed, range: 0.01...2,
                        help: "Velocidad de la respiración. Por debajo de 0,2 respira como algo dormido; entre 0,3 y 0,6 se lee como atención; por encima de 0,8 palpita y empieza a parecer alarma. Es un parámetro emocional más que técnico.")

            PanelGroupLabel(text: "Parpadeo del núcleo", help: "El punto del centro cambia cada tanto de color y vuelve. Toca sólo el núcleo: el iris, el aro y el halo siguen con su color.")
            ParamToggle(label: "Activo", isOn: $model.eyeBlinkEnabled,
                        help: "Hace que el núcleo cambie cada tanto al color de abajo y vuelva. Toca solo el punto del centro: el iris, el aro y el halo siguen con su color. Sirve para dar señal de vida sin mover nada — un testigo que late — y para marcar momentos de la presentación cambiando el ritmo. Mientras dura el destello la fuerza del núcleo se fuerza al máximo, así que el color se ve aunque tengas Fuerza núcleo en 0.")
            if model.eyeBlinkEnabled {
                HStack(spacing: 8) {
                    ParamLabel(text: "Color", help: "El color que toma el núcleo durante el destello. Un ámbar o un blanco sobre iris rojo se lee como aviso; un color cercano al del iris da un latido apenas perceptible en vez de un parpadeo.")
                    ColorPicker("", selection: $model.eyeBlinkColor, supportsOpacity: false)
                        .labelsHidden()
                    Spacer()
                }
                ParamSlider(label: "Ritmo", value: $model.eyeBlinkRate, range: 0.1...8, decimals: 2,
                            help: "Parpadeos por segundo. Cerca de 1 late como un pulso en reposo; arriba de 4 se lee como alarma o como procesamiento. Valores muy bajos (0,1 a 0,3) dan un destello aislado cada varios segundos, que llama más la atención justamente porque no se espera.")
                ParamSlider(label: "Duración", value: $model.eyeBlinkDuty, range: 0.02...0.98,
                            help: "Qué parte de cada ciclo pasa con el color puesto. Bajo es un destello corto sobre el color normal; en 0,5 pasa la mitad del tiempo en cada uno y se lee como alternancia; alto invierte la lectura — el color del parpadeo pasa a ser el estado normal y lo que destella es el color de núcleo.")
                ParamSlider(label: "Dureza", value: $model.eyeBlinkSoftness, range: 0...1,
                            help: "Cómo entra y sale el color. En 0 el corte es seco, tipo testigo de alarma o cursor de terminal. Subiéndolo el cambio se suaviza hasta volverse una respiración, sin bordes: ahí deja de leerse como parpadeo y pasa a ser un latido. Nunca es un corte perfectamente instantáneo, porque eso titila de forma irregular cuando el ritmo no cae justo en los fps.")
            }

            PanelGroupLabel(text: "Pulsos de energía", help: "Ondas que salen del centro. Como todo pasa por la rampa, no se ven como resplandor sino como una ola de caracteres cambiando de densidad.")
            ParamSlider(label: "Amplitud", value: $model.eyePulseAmount, range: 0...0.6,
                        help: "Fuerza de los pulsos que salen del centro. Como todo pasa por la rampa, la onda no se ve como un brillo sino como caracteres cambiando de densidad al pasar. Muy alto satura el campo y tapa el degradado del halo, con lo que se pierde la sensación de profundidad.")
            ParamSlider(label: "Velocidad", value: $model.eyePulseSpeed, range: 0...1,
                        help: "Velocidad con la que la onda se aleja del centro. En 0 queda congelada como anillos fijos, que es un look en sí mismo. Velocidades bajas se leen como energía que emana; altas, como una alarma.")
            ParamSlider(label: "Frecuencia", value: $model.eyePulseFrequency, range: 0.5...20, decimals: 1,
                        help: "Cuántas ondas conviven en pantalla. Alto da anillos finos y juntos, con aspecto de interferencia; bajo da una sola onda ancha que se lee como una exhalación. Combinado con velocidad baja y frecuencia baja se consigue el pulso más orgánico.")
            ParamSlider(label: "Caída", value: $model.eyePulseDecay, range: 0...8, decimals: 1,
                        help: "Cuánto se debilita la onda al alejarse. Alto la mantiene pegada al ojo y el borde de la pantalla queda quieto; bajo la deja llegar lejos y toda la imagen late. El alcance máximo igual lo pone el radio del halo: los pulsos viven dentro del campo de código y no aparecen anillos en el vacío.")
            ParamSlider(label: "Forma", value: $model.eyePulseShape, range: 0...1,
                        help: "Cuánto se abolla el frente de la onda. En 0 son circunferencias concéntricas perfectas, que se leen como un patrón de test más que como energía. Subiéndolo la onda se corre según el ángulo, con tres armónicos lentos que van a velocidades distintas, así que el frente se deforma y la deformación nunca se repite igual. No cambia ni el ritmo ni el alcance: sólo la forma.")

            PanelGroupLabel(text: "Campo de código", help: "El grano que convierte el degradado del halo en textura de caracteres.")
            ParamSlider(label: "Grano", value: $model.eyeFieldNoise, range: 0...1.5,
                        help: "Ruido que se suma al campo, celda por celda. Sin él, un degradado suave cuantizado por la rampa sale en anillos concéntricos y se lee como un gradiente mal hecho; con él, el mismo degradado se convierte en textura de caracteres. Es la diferencia entre parecer un render y parecer código.")
            ParamSlider(label: "Refresco", value: $model.eyeFieldChurn, range: 0...30, decimals: 1,
                        help: "Cada cuánto cambia el grano. En 0 el campo queda quieto y estable; valores altos hacen que el código se refresque solo, como si el sistema estuviera procesando. Ojo que la histéresis puede frenar los cambios más chicos.")
        }
    }

    // MARK: Ojo · movimiento

    private var eyeMotionContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            PanelGroupLabel(text: "Mirada", help: "Cómo recorre la pantalla. Genera el objetivo; el resorte se encarga de llegar.")
            HStack(spacing: 6) {
                Picker("", selection: $model.gazeMode) {
                    ForEach(GazeMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Quieto: se queda donde lo dejaste. Deriva: vagabundea sin rumbo. Barrido: recorrido continuo de ida y vuelta. Saltos: se clava en un punto, espera y salta a otro. Escaneo: recorre posiciones en zigzag, como quien pasa la vista por una fila. Órbita: da la vuelta. Todos generan un objetivo; el resorte se encarga de llegar, y ahí es donde el movimiento se vuelve creíble.",
                         title: "Modo de mirada")
            }

            ParamSlider(label: "Ritmo", value: $model.gazeRate, range: 0.02...3,
                        help: "Ritmo del recorrido. En los modos continuos son barridos por segundo; en los de pasos, cuántos saltos da. Valores muy bajos, del orden de 0,05, hacen que el movimiento sea tan lento que casi no se percibe pero la pantalla nunca se siente muerta.")
            ParamSlider(label: "Alcance X", value: $model.gazeExtentX, range: 0...0.5, decimals: 3,
                        help: "Cuánto se aleja del centro en horizontal. Es el que hace que parezca que recorre butacas: un público es ancho y bajo, así que este valor tiene que ser bastante mayor que el vertical. Alrededor de 0,25 barre casi toda la pantalla.")
            ParamSlider(label: "Alcance Y", value: $model.gazeExtentY, range: 0...0.3, decimals: 3,
                        help: "Cuánto se aleja del centro en vertical. Conviene mucho menor que el horizontal — si son parecidos el ojo flota en círculos en vez de recorrer una sala. Con valores muy chicos, cerca de 0,02, el recorrido se lee como una sola fila de asientos.")
            if model.gazeMode == .scan {
                ParamSlider(label: "Paradas", value: $model.gazeStops, range: 2...16, decimals: 0,
                            help: "Cuántas paradas hace antes de volver, en el modo Escaneo. Pocas dan saltos largos y evidentes; muchas dan un barrido casi continuo pero con micro-pausas, que es lo que hace un ojo real al recorrer una fila.")
            }

            ParamToggle(label: "No salir de cuadro", isOn: $model.eyeClampToScreen,
                        help: "El ojo no puede cruzar el borde, y el margen que respeta es el radio del halo: se frena justo cuando el campo tocaría el borde de la pantalla. Vale para el arrastre y para todos los modos de mirada. Si el halo es más grande que media pantalla, ese eje queda clavado al centro — con un campo así el ojo no se puede mover sin que se salga de cuadro.")

            PanelGroupLabel(text: "Físico", help: "Cómo viaja hasta el objetivo. Es lo que separa un movimiento vivo de un cursor.")
            ParamSlider(label: "Rigidez", value: $model.eyeStiffness, range: 1...80, decimals: 1,
                        help: "Fuerza con la que el ojo va hacia donde tiene que ir. Alto llega rápido y directo, con aspecto mecánico; bajo llega lento y pesado, como si le costara. Junto con el rozamiento define todo el carácter del movimiento.")
            ParamSlider(label: "Rozamiento", value: $model.eyeDamping, range: 0.5...30, decimals: 1,
                        help: "Cuánto frena el movimiento. Por debajo del valor crítico el ojo se pasa del objetivo y vuelve, y ese rebote es la mayor parte de la sensación de que algo está vivo; por encima llega lento y sin pasarse. El texto de abajo te dice de qué lado estás.")
            Text(dampingNote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            PanelGroupLabel(text: "Temblor", help: "Micro-movimiento permanente, encima de cualquier mirada.")
            ParamSlider(label: "Amplitud", value: $model.eyeDriftAmount, range: 0...0.08, decimals: 4,
                        help: "Micro-temblor permanente, que se suma a cualquier modo de mirada. Existe porque un ojo real nunca está perfectamente quieto: sin él, los modos con pausa se ven congelados durante la pausa y la ilusión se cae. Con 0,002 alcanza.")
            ParamSlider(label: "Velocidad", value: $model.eyeDriftSpeed, range: 0.01...2,
                        help: "Velocidad del temblor. Alto se lee como vibración nerviosa o falla eléctrica; bajo, como la respiración de la posición. Combinado con amplitud baja da un movimiento que se percibe sin poder señalarlo.")

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
            HStack(spacing: 6) {
                Picker("", selection: $model.tileWidth) {
                    ForEach(model.tileSizes, id: \.self) { size in Text("\(size)").tag(size) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Ancho de celda en píxeles; el alto sale del aspecto de la fuente. 8 da la imagen más detallada y es el piso útil: por debajo el glifo no tiene píxeles suficientes para distinguirse de su vecino en la rampa. 24 y 32 dan un ASCII grueso, de cartel, donde cada carácter se lee de lejos.",
                         title: "Ancho de celda")
            }

            ParamToggle(label: "Aspecto de la fuente", isOn: $model.aspectFollowsFont,
                        help: "Deriva el alto de celda de las métricas de la fuente, para que el glifo no salga deformado. Apagalo solo si querés estirar los caracteres a propósito: con el aspecto en 1 la celda es cuadrada y las letras salen anchas, que es un look pero se nota.")

            ParamSlider(label: "Aspecto", value: $model.cellAspect, range: 0.5...3.0,
                        help: "Proporción de la celda. En 1 es cuadrada y el glifo sale estirado a lo ancho; alrededor de 2 es el aspecto natural de una monoespaciada y las letras se leen como letras. Solo se puede tocar con el aspecto automático apagado.")
                .disabled(model.aspectFollowsFont)

            ParamReadout(label: "Celda", value: "\(model.config.tileSize.x)×\(model.config.tileSize.y) px",
                         help: "Tamaño en píxeles de cada carácter. Cuanto más chico, más caracteres entran y más detalle tiene la imagen, pero menos se distingue cada glifo. Es el compromiso central de todo el efecto: legibilidad del carácter contra resolución de la imagen.")
            if model.sourceKind != .eye {
                HStack(spacing: 6) {
                    Picker("", selection: $model.sourceFill) {
                        Text("Ajustar").tag(false)
                        Text("Llenar").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HelpMark("Qué hacer cuando la fuente y la salida no tienen la misma proporción. Ajustar: la imagen entra completa y lo que sobra queda negro. Llenar: la imagen se agranda hasta cubrir la salida y se recorta lo que se pasa. Con una cámara 16:9 y una salida de 2,11:1 la diferencia es entre dos franjas negras arriba y abajo, o perder los costados. Ajustar es el default porque recortar es perder imagen y eso no debería pasar sin que lo pidas.",
                             title: "Encuadre de la fuente")
                }
            }

            ParamReadout(label: "Salida", value: "\(model.config.outputSize.x)×\(model.config.outputSize.y)",
                         help: "Resolución a la que se genera todo. Se fija en Export; el grid se deriva de ella, nunca al revés. Si no divide entero por el tamaño de celda aparece una advertencia con el valor válido más cercano.")
            ParamReadout(label: "Grid", value: "\(model.config.gridSize.x) × \(model.config.gridSize.y)",
                         help: "Cuántos caracteres hay a lo ancho y a lo alto. Es la resolución real de la imagen ASCII: todo el detalle que ves está limitado por este número, no por la resolución de salida.")

            if let warning = model.gridWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            ParamToggle(label: "ASCII", isOn: $model.asciiEnabled,
                        help: "Apagado muestra la imagen sin convertir. Sirve para comparar y para diagnosticar: si algo se ve raro, apagarlo te dice si el problema está en la fuente o en el pipeline.")
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
                HelpMark("La fuente es la textura real de la pieza. Cambiarla vuelve a medir la tinta de cada glifo y reordena la rampa, así que la salida cambia de forma visible aunque no toques nada más. Las monoespaciadas de bloque funcionan mejor para estética de terminal que las tipográficas finas.",
                         title: "Fuente tipográfica")
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
                HelpMark("El campo de arriba no se aplica mientras tipeás: recalibrar en cada tecla rearmaría el atlas de la fuente carácter por carácter. Recalibrar lee el campo, rasteriza cada glifo, mide su tinta y arma la rampa de nuevo. Default vuelve al charset original y limpia las exclusiones.",
                         title: "Recalibrar")
                Spacer()
            }
            .controlSize(.small)

            ParamReadout(label: "Rampa", value: "\(model.ramp.count) / \(model.coverage.count)",
                         help: "Glifos que están en la rampa sobre el total del charset. La rampa se arma rasterizando cada glifo, midiendo cuánta tinta ocupa y ordenándolos de más claro a más denso — por eso cambiar de fuente cambia el orden. Menos glifos dan escalones más visibles y se lee más como pantalla.")

            DisclosureGroup(isExpanded: $showCoverage) {
                CoverageTable(model: model)
            } label: {
                HStack(spacing: 4) {
                    Text("Cobertura calibrada")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HelpMark("La rampa leída de arriba a abajo, con la tinta medida de cada glifo. Sirve para entender por qué un carácter cayó donde cayó, y para sacar los que molestan: si ves un salto grande entre dos valores, ahí la rampa tiene un hueco y el degradado va a mostrar una banda. Destildar un glifo lo saca sin borrarlo del charset.",
                             title: "Cobertura calibrada")
                }
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
                HelpMark("Mono: tinta sobre negro. Dos colores: tinta y fondo a elección. Original: cada carácter toma el color promedio de su celda en la imagen.", title: "Modo de color")
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
                        help: "Intercambia tinta y fondo: donde había carácter queda vacío y viceversa. No es el negativo fotográfico, es el negativo tipográfico. Suele funcionar bien cuando la salida va a papel o a un fondo claro.")
            ParamToggle(label: "Fondo transparente", isOn: $model.transparentBackground,
                        help: "Deja el fondo transparente en vez de negro. Solo lo conservan ProRes 4444 y la secuencia PNG; los demás formatos lo aplastan contra negro. Úsalo si vas a componer el ASCII sobre otra cosa en post.")

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
            PanelGroupLabel(text: "Formato", help: "Formato de salida, tanto para REC como para el render offline. ProRes para llevar a post, H.264 para mandar por ahí, secuencia PNG para máxima calidad con alpha. El ASCII es el peor caso posible para un codec de transformada, así que si podés evitá H.264.")
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

            // El render offline recorre un archivo de entrada. Con camara o con
            // el ojo no hay cuadros que recorrer: lo que se graba es el REC.
            if model.sourceKind == .file {
            Divider().padding(.vertical, 2)
            PanelGroupLabel(text: "Render offline", help: "Procesa un archivo cuadro a cuadro sin reloj: cada frame de entrada da exactamente uno de salida, tarde lo que tarde. A diferencia del REC, acá no se pierde ningún frame y el resultado es reproducible — dos renders del mismo material dan lo mismo.")
            Text("Desacoplado del reloj: cada frame de entrada produce uno de salida.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button("Renderizar archivo…") { model.startOfflineRender() }
                    .controlSize(.small)
                    .disabled(model.fileURL == nil || model.isRendering)
                HelpMark("Solo se habilita con un archivo abierto en la fuente Archivo. A diferencia del REC, acá no hay reloj que respetar: cada frame de entrada produce exactamente uno de salida, tarde lo que tarde, y el resultado es reproducible entre corridas. El audio del archivo pasa sin recodificar.",
                         title: "Renderizar archivo")
                Spacer()
            }

            if let summary = model.lastRenderSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }
            }
        }
    }

    // MARK: Bordes

    private var edgesContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            ParamToggle(label: "Glifos de borde", isOn: $model.edgesEnabled,
                        help: "Apagado deja solo la rampa de luminancia, sin glifos direccionales. Es la comparación que muestra qué aporta la detección de bordes: con esto encendido los contornos se leen como contornos, apagado son manchas de densidad.")

            VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
                ParamSlider(label: "Umbral", value: $model.edgeThreshold, range: 0...1,
                            help: "A partir de qué fuerza de borde el carácter se reemplaza por uno direccional. Bajo lo llena de barras y diagonales, incluso sobre ruido; alto solo marca los contornos más fuertes. Si ves rayitas sueltas donde no hay bordes, subilo.")
                PanelGroupLabel(text: "Diferencia de gaussianas", help: "Dos desenfoques restados. Lo que queda son los bordes: la diferencia entre un desenfoque fino y uno grueso es justamente el detalle.")
                ParamSlider(label: "Sigma 1", value: $model.dogSigma1, range: 0.2...4,
                            help: "Radio del desenfoque fino de la diferencia de gaussianas. Chico detecta bordes finos y detalle; grande los engorda y solo quedan los contornos grandes. Tiene que ser menor que Sigma 2.")
                ParamSlider(label: "Sigma 2", value: $model.dogSigma2, range: 0.5...10,
                            help: "Radio del desenfoque grueso. Cuanto más lejos esté de Sigma 1, más ancho es el borde que detecta. La distancia entre los dos sigmas es, en la práctica, el grosor del contorno.")
                ParamSlider(label: "Tau", value: $model.dogTau, range: 0...1.2,
                            help: "Cuánto se resta el desenfoque grueso. Cerca de 1 queda casi solo el borde y la imagen desaparece; por debajo sobrevive algo de la imagen y el contorno sale más blando y mezclado con el tono.")
            }
            .disabled(!model.edgesEnabled)
            .opacity(model.edgesEnabled ? 1 : 0.45)
        }
    }

    // MARK: Temporal

    private var temporalContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            // Arrastre y disgregación se mudaron a la sección Estela, junto con
            // la inercia del ojo: tener el rastro partido en dos secciones
            // obligaba a saltar de una a otra para ajustar una sola cosa.
            ParamReadout(label: "Histéresis", value: String(format: "%.2f", model.hysteresisThreshold),
                         help: "Cuánto tiene que cambiar la luminancia de una celda para que cambie su carácter, medido en escalones de rampa. El slider vive en Estela, porque es ahí donde se lo toca: con la cola larga, retener glifos confunde el residuo con el rastro de verdad.")

            // Todo este grupo existe para pelear contra una exposicion que se
            // mueve sola. La fuente generativa produce la misma luminancia todos
            // los frames, asi que aca no hay nada que corregir.
            if model.sourceKind != .eye {
            PanelGroupLabel(text: "Exposición", help: "El AGC de la cámara mueve la luminancia media constantemente y la rampa hierve aunque la escena esté quieta. Esto lo corrige.")
            if model.sourceKind == .camera {
                ParamToggle(label: "Lock de cámara", isOn: $model.exposureLocked,
                            help: model.supportsExposureLock
                                ? "Congela exposición y balance de blancos en el hardware."
                                : "Esta cámara no soporta lock de exposición.")
                    .disabled(!model.supportsExposureLock)
            }

            ParamSlider(label: "Auto nivel", value: $model.autoLevelStrength, range: 0...1,
                        help: "Cuánta corrección de exposición se aplica. En 0 la imagen pasa tal cual; en 1 se remapea para que la luminancia media caiga en el punto medio, lo que estabiliza la rampa cuando la cámara mueve el AGC. Con fuente generativa no hace falta.")
            ParamSlider(label: "Suavizado", value: $model.lumaSmoothAlpha, range: 0.01...0.5,
                        help: "Qué tan rápido reacciona la corrección de exposición. Chico reacciona lento pero no persigue cada parpadeo del automático de la cámara, que es el objetivo; grande se adapta rápido pero puede oscilar junto con el AGC y empeorar el problema.")
            ParamSlider(label: "Punto medio", value: $model.lumaTarget, range: 0.2...0.8,
                        help: "A qué luminancia se lleva el promedio de la imagen. 0,5 lo centra en la rampa y usa todo el rango de glifos; más alto aclara y empuja la imagen hacia los caracteres densos; más bajo la oscurece.")
                .disabled(model.autoLevelStrength <= 0)
            }
        }
    }

    // MARK: Chat

    private var chatContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            PanelGroupLabel(text: "Mensajes", help: "Un mensaje por renglón, en orden. Se edita como texto porque escribir una conversación es escribir, no llenar un formulario.")
            TextEditor(text: $model.chatScript)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4)))

            PanelGroupLabel(text: "Entrada", help: "Cómo llega cada mensaje y cada cuánto.")
            HStack(spacing: 6) {
                Picker("", selection: $model.chatMode) {
                    ForEach(ChatMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Pila: los mensajes se acumulan, el que llega entra al pie y empuja a los viejos hacia arriba, como en cualquier chat. Uno por vez: entra, se queda, se va, y el siguiente ocupa exactamente el mismo lugar — anclado abajo, así que el lugar es el mismo aunque el mensaje siguiente tenga otra cantidad de renglones. En «uno por vez» la salida no es la entrada al revés: el globo sigue subiendo. Uno que entra desde abajo y después vuelve a bajar se lee como que alguien lo borró; uno que sigue de largo se lee como que pasó.",
                         title: "Modo")
            }
            HStack(spacing: 6) {
                Picker("", selection: $model.chatEntrance) {
                    ForEach(ChatEntrance.allCases) { e in Text(e.label).tag(e) }
                }
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Fundido aparece en el lugar. Sube entra desde abajo hasta su posición final. Sube y funde hace las dos, que es lo que más se parece a un mensaje que llega. Se escribe revela el texto letra por letra, como si lo estuvieran tipeando del otro lado — para eso conviene subir la duración, porque ahí la duración es cuánto tarda en terminar de escribirse.",
                         title: "Animación de entrada")
            }
            ParamSlider(label: model.chatMode == .single ? "Ciclo" : "Intervalo",
                        value: $model.chatInterval, range: 0.3...12, decimals: 2,
                        help: model.chatMode == .single
                            ? "Cuánto dura cada mensaje de punta a punta: entrada, permanencia y salida. Se mide así y no como tiempo entre mensajes porque si no, subir la duración de la animación acortaría el tiempo de lectura sin avisar. La animación tiene un techo de un tercio del ciclo, para que el mensaje siempre llegue a quedarse quieto."
                            : "Segundos entre la llegada de un mensaje y la del siguiente. Es el ritmo de la conversación: valores altos dan pausas de lectura, valores bajos hacen que se amontonen como cuando alguien escribe rápido.")
            if model.chatMode == .single {
                ParamSlider(label: "Pausa", value: $model.chatPause, range: 0...10, decimals: 2,
                            help: "Cuánto queda la pantalla vacía entre un mensaje y el siguiente. En 0 el próximo entra apenas se fue el anterior, sin respiro. Es aparte del Ciclo: el Ciclo es cuánto dura el mensaje en pantalla —entrada, permanencia y salida— y la Pausa es el hueco después. Sumados dan el tiempo de mensaje a mensaje. En modo Pila no aparece porque ahí nada se va: el Intervalo ya es el tiempo entre una llegada y la siguiente.")
            }
            ParamSlider(label: "Duración", value: $model.chatDuration, range: 0.05...3, decimals: 2,
                        help: "Cuánto tarda el MOVIMIENTO de entrada. Con Rebote es el tiempo de respuesta del resorte —cuánto tarda en llegar— y el resorte se sigue asentando un poco después, como corresponde. No toca la opacidad: eso es Fundido. Con «Se escribe» es cuánto tarda en terminar de tipearse el mensaje entero.")
            ParamSlider(label: "Fundido entrada", value: $model.chatFadeIn, range: 0.0...2, decimals: 2,
                        help: "Cuánto tarda en aparecer la opacidad, aparte del movimiento. Antes iban juntos y el globo se veía lavado durante todo el viaje; casi siempre conviene que el fundido sea bastante más corto que el desplazamiento. En 0 aparece opaco de entrada y sólo se mueve.")
            if model.chatEntrance == .bounce {
                ParamSlider(label: "Rebote", value: $model.chatBounce, range: 0...1,
                            help: "Cuánto se pasa el globo antes de asentarse. Es un resorte: en 0 llega derecho, sin pasarse. El sobrepaso se mide sobre la SUBIDA, así que con una subida corta el rebote es corto por más que subas esto — con subida 3,5 y escala 2 el globo viaja 106 px y se pasa 42; con subida 8 viaja 240 y se pasa 96. Si no lo ves, el control es la Subida, no éste. En modo Pila el movimiento se sigue haciendo de a celdas enteras y el rebote se pierde en el redondeo: para verlo hay que estar en «uno por vez».")
            }
            ParamSlider(label: "Subida", value: $model.chatRise, range: 0...20, decimals: 0,
                        help: "Cuánto viaja el globo al entrar, en casillas de la Escala. Es lo que fija el tamaño del rebote: el sobrepaso es un porcentaje de esto, así que con una subida corta no hay rebote posible por más que subas el control de Rebote. En «uno por vez» el movimiento es por píxeles y sale liso; en Pila se hace de a celdas enteras, porque ahí hay varios globos animando a la vez y el corrimiento fino del shader es uno solo para toda la capa.")
            if model.chatMode == .single {
                PanelGroupLabel(text: "Salida", help: "Cómo se va cada mensaje. Sólo aplica en «uno por vez»: en pila nada se va.")
                HStack(spacing: 6) {
                    Picker("", selection: $model.chatExit) {
                        ForEach(ChatExit.allCases) { e in Text(e.label).tag(e) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HelpMark("Fundido se apaga en el lugar. Se va arriba sigue subiendo mientras se apaga — es lo que más se lee como «el mensaje pasó» en vez de «alguien lo borró». Se va abajo cae, que se lee como descartado. Corte lo saca de un cuadro al otro, sin transición, y ahí la duración no hace nada.",
                             title: "Salida")
                }
                ParamSlider(label: "Fundido salida", value: $model.chatFadeOut, range: 0.0...3, decimals: 2,
                            help: "Cuánto tarda en apagarse, aparte del movimiento de salida. En 0 desaparece de golpe al final del ciclo.")
                ParamSlider(label: "Duración salida", value: $model.chatExitDuration, range: 0...3, decimals: 2,
                            help: "Cuánto tarda en irse. Va aparte de la duración de entrada porque casi nunca se quieren iguales: entrar tiene que llamar la atención, irse no. En 0 desaparece de golpe. Entre la entrada y la salida no pueden pasarse del 90% del ciclo; si las dos suman más, se achican en proporción para que el mensaje siempre llegue a quedarse quieto.")
            }

            ParamToggle(label: "Repetir", isOn: $model.chatLoops,
                        help: "Al terminar el último mensaje vuelve a empezar la conversación. Para un loop de sala conviene encendido; para un pase único, apagado.")

            PanelGroupLabel(text: "Forma", help: "Tamaño del texto y del globo, todo medido en celdas.")
            HStack(spacing: 6) {
                Picker("", selection: $model.chatShape) {
                    ForEach(ChatBubbleShape.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HelpMark("Recto es un rectángulo lleno. Redondeado saca la casilla de cada esquina: en una grilla de caracteres no hay curva posible, así que el redondeo es un recorte en escalera — y a escala 2 o más ya se lee como globo. El recorte es de una casilla, o sea que crece con la Escala.",
                         title: "Forma del globo")
            }
            if model.chatShape == .rounded {
                ParamSlider(label: "Redondeo", value: $model.chatCorner, range: 0...1,
                            help: "Radio de las esquinas, como fracción del lado corto del globo. En 1 los extremos quedan semicirculares, tipo pastilla. El borde se resuelve por PÍXEL y no por celda —el shader mide la distancia a un rectángulo redondeado— así que la curva sale lisa de verdad, sin escalones, por más grande que sea la celda. El texto sigue cayendo en la grilla: lo único que se sale de ella es el fondo.")
            }
            ParamToggle(label: "Piquito", isOn: $model.chatTail,
                        help: "Agrega la puntita del globo de diálogo, abajo a la izquierda — del mismo lado por el que se alinean los globos. También en escalera: dos casillas y después una, que es lo que en una grilla se lee como la punta que apunta a quien habla.")
            ParamSlider(label: "Escala", value: $model.chatScale, range: 1...6, decimals: 0,
                        help: "Cuántas celdas ocupa cada letra por lado. En 1 el texto es del tamaño de un carácter del ASCII y se mezcla con el fondo; subiéndolo el mensaje se despega y se lee de lejos, que es lo que hace falta proyectando. Todo el maquetado vive en una grilla de este tamaño, así que los globos siempre caen alineados entre sí.")
            ParamSlider(label: "Ancho", value: $model.chatColumns, range: 8...80, decimals: 0,
                        help: "Ancho máximo del globo en caracteres, antes de cortar el renglón. El corte respeta las palabras salvo que una sola palabra no entre.")
            ParamSlider(label: "Margen horiz.", value: $model.chatPadX, range: 0...6, decimals: 0,
                        help: "Cuántos caracteres de aire quedan entre el texto y el borde del globo, a izquierda y derecha.")
            ParamSlider(label: "Margen vert.", value: $model.chatPadY, range: 0...6, decimals: 0,
                        help: "Cuántos renglones de aire quedan arriba y abajo del texto, dentro del globo. Con 0 el texto toca el borde, que con el globo redondeado se ve apretado; 1 ya le da respiro y hace que el redondeo tenga dónde curvarse.")
            ParamSlider(label: "Separación", value: $model.chatGap, range: 0...6, decimals: 0,
                        help: "Cuánto espacio queda entre un globo y el siguiente, en casillas. Con el piquito encendido el mínimo pasa a 3, porque la punta baja dos casillas por debajo del globo y si no se le monta al mensaje de abajo.")
            ParamSlider(label: "Margen izq.", value: $model.chatMarginLeft, range: 0...30, decimals: 0,
                        help: "Distancia de los globos al borde izquierdo, en caracteres.")
            ParamSlider(label: "Margen abajo", value: $model.chatMarginBottom, range: 0...20, decimals: 0,
                        help: "Distancia del globo más nuevo al borde inferior. La pila se ancla abajo: el mensaje que llega entra al pie y empuja a los viejos hacia arriba, como cualquier chat.")

            PanelGroupLabel(text: "Color", help: "Del texto y del fondo del globo.")
            HStack(spacing: 8) {
                ParamLabel(text: "Texto", help: "Color de las letras. Se dibuja por encima de todo lo demás, incluido el glitch y el pleno del ojo: un mensaje que algo puede tapar deja de cumplir su única función.")
                ColorPicker("", selection: $model.chatTextColor, supportsOpacity: false)
                    .labelsHidden()
                Spacer()
                ParamLabel(text: "Globo", help: "Color del fondo del globo.")
                ColorPicker("", selection: $model.chatBubbleColor, supportsOpacity: false)
                    .labelsHidden()
            }
            ParamSlider(label: "Opacidad", value: $model.chatBubbleAlpha, range: 0...1,
                        help: "Cuánto tapa el fondo del globo. En 0 el texto flota sin caja, que sobre negro se lee perfecto y es más limpio; subiéndolo aparece la caja, que hace falta cuando abajo hay imagen o código y el texto se pierde.")
        }
    }

    // MARK: Glitch

    private var glitchContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            ParamToggle(label: "Activo", isOn: $model.glitchEnabled,
                        help: "Enciende la corrupción. Todo lo de abajo sólo actúa durante las ráfagas; entre una y otra la imagen sale limpia.")

            VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
                PanelGroupLabel(text: "Disparo", help: "Cuándo pasa. Es lo que decide si se lee como falla o como textura.")
                ParamSlider(label: "Ritmo", value: $model.glitchRate, range: 0.05...8, decimals: 2,
                            help: "Cada cuánto puede dispararse una ráfaga, en veces por segundo. Bajo deja largos tramos limpios y cada falla pega; alto se vuelve un estado permanente y deja de sorprender. Entre 0,5 y 2 es donde se lee como un sistema que falla cada tanto.")
                ParamSlider(label: "Duración", value: $model.glitchDuty, range: 0.01...1, decimals: 2,
                            help: "Qué parte de cada intervalo dura la ráfaga. Valores bajos dan chispazos de un par de cuadros — lo más parecido a un error real. Arriba de 0,5 la corrupción pasa a ser el estado normal y lo que se nota son los momentos limpios.")
                ParamSlider(label: "Probabilidad", value: $model.glitchChance, range: 0...1,
                            help: "Qué chance tiene cada intervalo de disparar. En 1 dispara siempre y el ritmo se vuelve de metrónomo, que es lo que más delata que hay un generador atrás. Bajándolo aparecen huecos irregulares y el patrón deja de ser previsible.")
                ParamSlider(label: "Intensidad", value: $model.glitchAmount, range: 0...1,
                            help: "Escala general del desplazamiento de las bandas. No afecta a los bloques ni al congelado, que tienen su propia cantidad.")

                PanelGroupLabel(text: "Bandas", help: "Filas de celdas corridas en horizontal. El desgarro clásico de señal.")
                ParamSlider(label: "Alto", value: $model.glitchBandHeight, range: 1...20, decimals: 0,
                            help: "Alto de cada banda en celdas. Bandas de una celda dan un rasgado fino tipo interferencia; bandas gruesas parten la imagen en pocos bloques grandes y se lee más como un corte de edición que como ruido.")
                ParamSlider(label: "Corrimiento", value: $model.glitchBandShift, range: 0...40, decimals: 0,
                            help: "Cuántas celdas como máximo se puede correr una banda. Siempre es un número entero de celdas: por eso el desgarro sale a escuadra y no queda medio carácter cortado.")
                ParamSlider(label: "Cantidad", value: $model.glitchBandAmount, range: 0...1,
                            help: "Qué fracción de las bandas se corre en cada ráfaga. Bajo deja la imagen casi entera con un par de rasgaduras; en 1 se corren todas y la imagen se desarma completa.")

                PanelGroupLabel(text: "Bloques", help: "Regiones rectangulares corrompidas. Es la parte geométrica dura.")
                ParamSlider(label: "Cantidad", value: $model.glitchBlockCount, range: 0...16, decimals: 0,
                            help: "Cuántos rectángulos aparecen por ráfaga. Cada uno se sortea de nuevo en cada ráfaga, así que no se repiten posiciones.")
                ParamSlider(label: "Módulo", value: $model.glitchModule, range: 1...12, decimals: 0,
                            help: "Lado del módulo base, en filas de celda. Todos los bloques miden un múltiplo entero de esto y arrancan pegados a la grilla de módulos, así que se alinean entre sí aunque no se toquen — de ahí sale la lectura de grilla. El ancho del módulo se deriva solo del aspecto de la celda para que salga cuadrado en pantalla: una celda tipográfica es más alta que ancha, así que un módulo de n×n celdas saldría un rectángulo parado y la grilla entera se vería estirada.")
                ParamSlider(label: "Escala", value: $model.glitchBlockScale, range: 1...4, decimals: 1,
                            help: "El lado LARGO del bloque, medido en módulos. En 1 todos salen de un módulo exacto y queda un mosaico parejo — la proporción se aplasta ahí, y vuelve a aparecer sola al subir. Los valores con decimal mezclan: en 1,4 la mayoría queda en un módulo y de a ratos aparece uno de dos, que es donde se arma jerarquía sin perder la lectura de grilla. Las proporciones salen de una tabla corta —1:1, 2:1, 1:2, 3:1, 1:3, 2:2, 4:1, 1:4— y no de un sorteo continuo, que es lo que hace que el conjunto se lea como sistema y no como accidente. Para bloques más chicos que un módulo, lo que hay que bajar es el Módulo.")
                HStack(spacing: 6) {
                    Picker("", selection: $model.glitchBlockFill) {
                        Text("Sólido").tag(UInt32(0))
                        Text("Trama").tag(UInt32(1))
                        Text("Invertido").tag(UInt32(2))
                        Text("Vacío").tag(UInt32(3))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HelpMark("Con qué se rellena el rectángulo. Sólido lo pinta lleno. Trama usa un damero de dos píxeles, que a distancia lee como medio tono. Invertido cambia tinta por fondo dentro del bloque, así que el código sigue estando pero en negativo. Vacío lo apaga y deja un agujero. El relleno se dibuja directo y no usa ningún carácter: meter glifos de bloque en el charset desbalancearía la rampa calibrada, porque un sólido pesa más que cualquier glifo y se quedaría con el extremo denso.",
                             title: "Relleno del bloque")
                }

                PanelGroupLabel(text: "Celda", help: "Corrupción carácter por carácter, sin geometría.")
                ParamSlider(label: "Congelado", value: $model.glitchFreeze, range: 0...1,
                            help: "Qué fracción de las celdas retiene el carácter que tenía, como un codec que perdió el keyframe. Se resuelve en la etapa que elige el glifo y no en la composición: ahí el valor retenido se propaga solo de cuadro a cuadro, así que la celda queda clavada toda la ráfaga en vez de quedar un cuadro atrasada. Es lo que más se parece a un video roto de verdad.")
                ParamSlider(label: "Revoltijo", value: $model.glitchScramble, range: 0...1,
                            help: "Qué fracción de las celdas recibe un carácter equivocado. La densidad de la imagen sobrevive porque sólo cambia cuál glifo se dibuja, no cuánta tinta hay en promedio: por eso se lee como texto corrompido y no como ruido encima. No toca los glifos de borde, que si se mezclaran romperían el contorno.")
            }
            .disabled(!model.glitchEnabled)
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
                            help: "Cuántas gotas caen a la vez en cada columna. Cada una tiene su fase y velocidad propias, así que subirlo no sincroniza nada, solo llena. Densidad alta con rastro largo llena la columna entera y el efecto pasa de lluvia a cortina.")
                ParamSlider(label: "Rastro", value: $model.matrixTrail, range: 3...60, decimals: 0)
                ParamSlider(label: "Mutación", value: $model.matrixChurn, range: 0...40, decimals: 0,
                            help: "Cada cuánto muta el carácter dentro del rastro de una gota. En 0 la gota arrastra siempre el mismo glifo y se lee como una raya; alto hace que los caracteres cambien mientras caen, que es lo que da la sensación de datos corriendo.")

                PanelGroupLabel(text: "Imagen", help: "Cómo la imagen de fondo compuerta la lluvia.")
                ParamSlider(label: "Peso", value: $model.matrixImageMix, range: -1...1,
                            help: "Cómo la imagen decide dónde llueve. Positivo: la lluvia vive en las zonas claras y el negro queda vacío. Cero: llueve parejo y la imagen solo afecta el recorrido. Negativo: se invierte y la lluvia se mete en las sombras.")
                ParamSlider(label: "Fondo", value: $model.matrixBaseLevel, range: 0...1,
                            help: "Brillo del ASCII de la imagen donde no hay gota. Es la perilla de cuánto se lee lo que hay debajo del efecto: en 0 solo se ve la lluvia sobre negro, en 1 la imagen se lee completa y la lluvia la recorre.")

                PanelGroupLabel(text: "Origen", help: "De dónde nace cada gota. Sirve para que el brillo emita en vez de solo iluminarse al pasar.")
                ParamSlider(label: "Nacer brillo", value: $model.matrixSpawnBias, range: 0...1,
                            help: "Desde dónde nace cada gota. En 0 caen desde arriba de la pantalla como lluvia normal; en 1 nacen en la celda más brillante de su columna, con lo que el brillo pasa de ser algo que la lluvia ilumina al pasar a ser lo que la emite.")
                ParamSlider(label: "Fuerza", value: $model.matrixSpawnStrength, range: 0...1,
                            help: "Cuánto influye el brillo del punto de origen en la fuerza de la gota. En 0 todas las gotas son iguales; subiéndolo, una columna cuyo punto más brillante es apenas gris emite una gota débil, y se arma una jerarquía que sigue a la imagen.")

                PanelGroupLabel(text: "Volumen", help: "La luminancia funciona como campo de altura y curva el frente de la lluvia sobre la forma.")
                ParamSlider(label: "Relieve", value: $model.matrixRelief, range: -24...24, decimals: 0,
                            help: "Cuánto se adelanta o atrasa el frente de la lluvia según la altura de cada celda. Es lo que hace que la lluvia se curve sobre la forma en vez de bajar plana: la luz corre adelante y la sombra queda atrás. Negativo invierte qué es lo que sobresale.")
                ParamSlider(label: "Suavizado", value: $model.reliefRadius, range: 0...16, decimals: 0,
                            help: "Difumina el campo de altura antes de usarlo. Sin esto el relieve sigue la textura y no la forma — una remera estampada mete volumen donde no hay. Subilo hasta que el relieve responda a la silueta y no al dibujo.")
                if model.sourceKind != .eye {
                    ParamToggle(label: "Detectar sujeto", isOn: $model.subjectMatteEnabled,
                                help: "Usa Vision para separar a la persona del fondo y alimentar con eso el campo de altura. No es profundidad real, es figura contra fondo, pero para que la lluvia encuentre volumen eso hace más que cualquier gradiente. Corre en la Neural Engine y cuesta pocos milisegundos.")
                    ParamSlider(label: "Peso sujeto", value: $model.matteWeight, range: 0...1)
                        .disabled(!model.subjectMatteEnabled)
                }

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
