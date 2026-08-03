import SwiftUI

/// Piezas del panel. Existen para que todos los controles compartan la misma
/// grilla: etiqueta de ancho fijo, control elastico, valor alineado a la
/// derecha. Sin eso cada fila alinea distinto y el panel se lee como una lista
/// de cosas sueltas en vez de una tabla.
enum PanelMetrics {
    static let labelWidth: CGFloat = 78
    static let valueWidth: CGFloat = 46
    static let rowSpacing: CGFloat = 7
}

/// Seccion plegable con encabezado. El estado de plegado lo guarda quien la usa,
/// no la seccion, para que sobreviva a los redibujos de SwiftUI.
struct PanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 13)
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(0.6)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)

            if isExpanded {
                VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
                    content()
                }
                .padding(.bottom, 10)
            }
        }
    }
}

/// Subtitulo dentro de una seccion. Agrupa sin agregar otro nivel de plegado.
struct PanelGroupLabel: View {
    let text: String
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 9, weight: .medium))
            HelpMark(help, title: text)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

/// Signo de pregunta diminuto que abre una explicacion al hacer click.
///
/// Click y no tooltip: un tooltip obliga a mantener el mouse quieto y desaparece
/// al moverlo, asi que solo sirve para textos de una linea. Con popover el texto
/// se queda mientras se lee y se puede explicar para que sirve el parametro, no
/// solo que es.
struct HelpMark: View {
    let title: String
    let text: String?
    @State private var isShowing = false

    init(_ text: String?, title: String = "") {
        self.text = text
        self.title = title
    }

    var body: some View {
        if let text, !text.isEmpty {
            Button { isShowing.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(isShowing ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 7) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(13)
                .frame(width: 280, alignment: .leading)
            }
        }
    }
}

/// Etiqueta con su signo de pregunta, en el ancho fijo de la grilla del panel.
struct ParamLabel: View {
    let text: String
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HelpMark(help, title: text)
            Spacer(minLength: 0)
        }
        .frame(width: PanelMetrics.labelWidth, alignment: .leading)
    }
}

/// Slider con valor numerico editable al lado (spec §8: nada de sliders ciegos).
struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var decimals: Int = 2
    var help: String?

    var body: some View {
        HStack(spacing: 8) {
            ParamLabel(text: label, help: help)

            Slider(value: $value, in: range)
                .controlSize(.mini)

            TextField("", value: $value, format: .number.precision(.fractionLength(decimals)))
                .textFieldStyle(.plain)
                // monospacedDigit: sin esto el numero cambia de ancho mientras
                // arrastras y el slider tiembla.
                .font(.system(size: 10, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: PanelMetrics.valueWidth)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// Fila de solo lectura, con la misma grilla que los sliders.
struct ParamReadout: View {
    let label: String
    let value: String
    var help: String?

    var body: some View {
        HStack(spacing: 8) {
            ParamLabel(text: label, help: help)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

/// Toggle compacto y alineado a la grilla del panel.
struct ParamToggle: View {
    let label: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 11))
                HelpMark(help, title: label)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
