import Foundation

/// Error de dominio con mensaje presentable. Spec §12: los errores se muestran
/// en la UI, no se tragan con `try?`.
struct AppError: Error, Identifiable, Equatable {
    let id = UUID()
    let stage: Stage
    let message: String
    let detail: String?

    enum Stage: String {
        case metal = "Metal"
        case shaders = "Shaders"
        case capture = "Captura"
        case permissions = "Permisos"
    }

    init(_ stage: Stage, _ message: String, detail: String? = nil) {
        self.stage = stage
        self.message = message
        self.detail = detail
    }

    init(_ stage: Stage, _ message: String, underlying: Error) {
        self.init(stage, message, detail: (underlying as NSError).localizedDescription)
    }

    var displayText: String {
        detail.map { "\(message)\n\($0)" } ?? message
    }
}
