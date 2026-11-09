#if os(iOS)
import BackgroundTasks

/// 충전 중이고 네트워크에 연결돼 있을 때 iOS 가 앱을 깨워 남은 분석(주로 iCloud 동영상 장면)을 이어가게 합니다.
@MainActor
enum BackgroundIndexing {
    static let taskID = "com.youngim.momentfinder.indexing"

    /// 앱 실행이 끝나기 전에 등록해야 iOS 가 작업을 넘겨줍니다.
    static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            MainActor.assumeIsolated { run(task, model: model) }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func run(_ task: BGTask, model: AppModel) {
        let completion = Completion(task: task, model: model)
        task.expirationHandler = {
            Task { @MainActor in
                model.pauseIndexing()
                completion.finish(success: false)
            }
        }
        Task {
            let finished = await model.indexUntilDone()
            completion.finish(success: finished)
        }
    }

    /// 만료와 정상 종료가 겹쳐도 setTaskCompleted 는 한 번만 부릅니다.
    @MainActor
    private final class Completion {
        private let task: BGTask
        private let model: AppModel
        private var isDone = false

        init(task: BGTask, model: AppModel) {
            self.task = task
            self.model = model
        }

        func finish(success: Bool) {
            guard !isDone else { return }
            isDone = true
            model.scheduleBackgroundIndexingIfNeeded()
            task.setTaskCompleted(success: success)
        }
    }
}
#endif
