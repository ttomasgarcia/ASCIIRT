import AppKit
import SwiftUI

extension Notification.Name {
    /// Archivo que llega desde Finder (doble click, «Abrir con», drop en el Dock).
    static let asciirtOpenFile = Notification.Name("asciirt.openFile")
}

/// SwiftUI puro no expone `application(_:open:)`; hace falta el delegate de AppKit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .asciirtOpenFile, object: url)
    }
}

@main
struct ASCIIRTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// El modelo puede fallar al construirse (sin Metal, shaders rotos). En ese
    /// caso no hay nada que renderizar, asi que la ventana muestra el error en
    /// vez de arrancar a medias.
    private let result: Result<AppModel, AppError>

    init() {
        do {
            result = .success(try AppModel())
        } catch let error as AppError {
            result = .failure(error)
        } catch {
            result = .failure(AppError(.metal, "Fallo la inicializacion.", underlying: error))
        }
    }

    var body: some Scene {
        Window("ASCIIRT", id: "main") {
            switch result {
            case .success(let model):
                ContentView(model: model)
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
        .defaultSize(width: 1180, height: 700)
    }
}

private struct StartupFailureView: View {
    let error: AppError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("[\(error.stage.rawValue)] \(error.message)")
                .font(.system(.body, design: .monospaced))
            if let detail = error.detail {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 240)
    }
}
