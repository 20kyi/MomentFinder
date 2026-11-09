import SwiftUI

@main
struct MomentFinderApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        #if os(iOS)
        BackgroundIndexing.register(model: model)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
