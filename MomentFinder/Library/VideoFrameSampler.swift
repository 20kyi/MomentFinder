import AVFoundation
import CoreGraphics

/// 동영상에서 일정 간격으로 키프레임을 뽑습니다. "하품"처럼 몇 초짜리 동작도 놓치지 않도록 기본 1초 간격입니다.
enum VideoFrameSampler {
    static let preferredInterval: Double = 1.0
    static let maxFrames = 60

    static func sampleTimes(duration: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        guard duration > preferredInterval else { return [duration / 2] }
        let interval = max(preferredInterval, duration / Double(maxFrames))
        return Array(stride(from: min(0.5, duration / 2), to: duration, by: interval))
    }

    /// 프레임을 모아 두지 않고 디코딩되는 대로 넘겨서, 여러 동영상을 동시에 처리해도 메모리가 늘지 않게 합니다.
    static func forEachFrame(from asset: AVAsset, duration: Double, _ body: (Double, CGImage) async -> Void) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: PhotoLibrary.analysisSide, height: PhotoLibrary.analysisSide)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = sampleTimes(duration: duration).map { CMTime(seconds: $0, preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            if Task.isCancelled { break }
            guard let image = try? result.image else { continue }
            let actual = (try? result.actualTime) ?? result.requestedTime
            await body(actual.seconds, image)
        }
    }
}
