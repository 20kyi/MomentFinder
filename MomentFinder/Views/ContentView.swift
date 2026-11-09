import SwiftUI
import Translation

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.authorization {
            case .authorized, .limited:
                SearchScreen()
            case .notDetermined:
                PermissionView()
            default:
                PermissionDeniedView()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.refreshAuthorization() }
            if scenePhase == .background { model.scheduleBackgroundIndexingIfNeeded() }
        }
        .translationTask(model.translator.configuration) { session in
            await model.translator.process(session)
        }
        .alert("알림", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
