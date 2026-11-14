import AVFoundation
import CoreGraphics
import Vision

/// 동영상을 릴스·쇼츠용 9:16 세로 화면으로 자르는 계산. 자르는 창은 긴 쪽으로만 움직이고, 위치는 창 가운데를 0~1 로 나타냅니다.
enum ReelCrop {
    static let renderSize = CGSize(width: 1080, height: 1920)
    static var aspect: CGFloat { renderSize.width / renderSize.height }

    /// 클립 시작부터 잰 시각(초)에 자르는 창 가운데가 있을 위치.
    struct Keyframe: Sendable, Hashable {
        var time: Double
        var center: CGFloat
    }

    /// 화면보다 가로로 넓은 동영상은 좌우로, 세로로 더 긴 동영상은 위아래로 창을 움직입니다.
    static func movesHorizontally(_ displaySize: CGSize) -> Bool {
        displaySize.height > 0 && displaySize.width / displaySize.height > aspect
    }

    /// 화면 방향으로 돌린 동영상 크기 안에서 자를 영역. 창이 동영상 밖으로 나가지 않게 가운데를 안쪽으로 밉니다.
    static func cropRect(displaySize: CGSize, center: CGFloat) -> CGRect {
        if movesHorizontally(displaySize) {
            let width = displaySize.height * aspect
            let x = min(max(center * displaySize.width - width / 2, 0), displaySize.width - width)
            return CGRect(x: x, y: 0, width: width, height: displaySize.height)
        } else {
            let height = min(displaySize.width / aspect, displaySize.height)
            let y = min(max(center * displaySize.height - height / 2, 0), displaySize.height - height)
            return CGRect(x: 0, y: y, width: displaySize.width, height: height)
        }
    }

    /// 창이 실제로 놓일 수 있는 위치로 맞춘 가운데. 끝까지 민 뒤 되돌릴 때 바로 움직이게 합니다.
    static func clampedCenter(_ center: CGFloat, displaySize: CGSize) -> CGFloat {
        let crop = cropRect(displaySize: displaySize, center: center)
        if movesHorizontally(displaySize) {
            return displaySize.width > 0 ? crop.midX / displaySize.width : 0.5
        }
        return displaySize.height > 0 ? crop.midY / displaySize.height : 0.5
    }

    /// 원본 프레임을 바로 세운 뒤 자를 영역을 renderSize 에 꽉 차게 옮기는 변환.
    static func transform(natural: CGSize, preferred: CGAffineTransform, center: CGFloat) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let crop = cropRect(displaySize: CGSize(width: abs(oriented.width), height: abs(oriented.height)), center: center)
        let scale = renderSize.width / crop.width
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX - crop.minX, y: -oriented.minY - crop.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// 키프레임 사이를 직선으로 이어 time 에서의 창 위치를 구합니다. 내보낼 때의 변환 램프와 같은 방식입니다.
    static func center(at time: Double, in keyframes: [Keyframe]) -> CGFloat {
        guard let first = keyframes.first else { return 0.5 }
        guard time > first.time else { return first.center }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where time <= b.time {
            let t = b.time > a.time ? (time - a.time) / (b.time - a.time) : 1
            return a.center + (b.center - a.center) * CGFloat(t)
        }
        return keyframes[keyframes.count - 1].center
    }

    /// 한 프레임에서 찾은 대상. 창이 움직이는 방향으로만 잰 범위(0~1)와, 크기·확신도로 정한 무게를 가집니다.
    struct Subject: Sendable, Hashable {
        var lower: CGFloat
        var upper: CGFloat
        var weight: CGFloat
        var center: CGFloat { (lower + upper) / 2 }
    }

    /// 창 하나에 담을 위치. 대상이 모두 창에 들어가면 함께 담고, 아니면 한 대상만 담습니다.
    /// 여러 대상의 가운데를 잡으면 아무도 제대로 담기지 않으므로, 직전에 따라가던 대상과 가장 가까운 대상을 계속 따라갑니다.
    /// 무게가 가장 큰 대상의 절반에 못 미치는 대상은 고르지 않습니다.
    static func focus(_ subjects: [Subject], window: CGFloat, previous: CGFloat?) -> CGFloat? {
        guard let lower = subjects.map(\.lower).min(), let upper = subjects.map(\.upper).max(),
              let heaviest = subjects.max(by: { $0.weight < $1.weight }) else { return nil }
        if upper - lower <= window { return (lower + upper) / 2 }
        guard let previous else { return heaviest.center }
        return subjects
            .filter { $0.weight >= heaviest.weight / 2 }
            .min { abs($0.center - previous) < abs($1.center - previous) }?
            .center ?? heaviest.center
    }

    /// 창이 움직이는 방향으로 잰 창 크기(0~1).
    static func windowFraction(_ displaySize: CGSize) -> CGFloat {
        let crop = cropRect(displaySize: displaySize, center: 0.5)
        if movesHorizontally(displaySize) {
            return displaySize.width > 0 ? crop.width / displaySize.width : 1
        }
        return displaySize.height > 0 ? crop.height / displaySize.height : 1
    }

    /// 일정 간격으로 찾은 피사체 위치를 부드러운 카메라 움직임으로 바꿉니다.
    /// 못 찾은 시점은 가까운 시점의 위치로 채우고, 이동 평균을 두 번 걸어 프레임마다 흔들리지 않게 합니다.
    static func keyframes(times: [Double], centers: [CGFloat?], radius: Int = 2) -> [Keyframe] {
        guard !times.isEmpty, times.count == centers.count else { return [Keyframe(time: 0, center: 0.5)] }
        guard centers.contains(where: { $0 != nil }) else { return [Keyframe(time: times[0], center: 0.5)] }

        var filled = centers
        var last: CGFloat?
        for i in filled.indices {
            if let value = filled[i] { last = value } else { filled[i] = last }
        }
        last = nil
        for i in filled.indices.reversed() {
            if let value = filled[i] { last = value } else { filled[i] = last }
        }

        var values = filled.map { $0 ?? 0.5 }
        for _ in 0..<2 {
            values = values.indices.map { i in
                let window = values[max(0, i - radius)...min(values.count - 1, i + radius)]
                return window.reduce(0, +) / CGFloat(window.count)
            }
        }
        return zip(times, values).map { Keyframe(time: $0, center: $1) }
    }
}

/// 9:16 로 자를 때 따라갈 대상(얼굴 → 개·고양이 → 눈에 띄는 부분 순)의 위치를 동영상에서 찾습니다.
/// 같은 시각을 다시 분석하지 않도록 결과를 모아 두어, 구간을 조금씩 바꿔도 새로 생긴 부분만 분석합니다.
actor SubjectTracker {
    static let interval: Double = 0.5
    private static let analysisSide: CGFloat = 512

    private let video: AVAsset
    private let horizontal: Bool
    private let window: CGFloat
    /// 샘플 번호(시각 / interval)마다 찾은 대상들. 아무것도 못 찾았으면 빈 배열을 저장합니다.
    private var cache: [Int: [ReelCrop.Subject]] = [:]

    init(video: AVAsset, displaySize: CGSize) {
        self.video = video
        self.horizontal = ReelCrop.movesHorizontally(displaySize)
        self.window = ReelCrop.windowFraction(displaySize)
    }

    /// range 안의 키프레임을 클립 시작 기준 시각으로 돌려줍니다.
    func keyframes(for range: ClosedRange<Double>) async -> [ReelCrop.Keyframe] {
        let first = Int((range.lowerBound / Self.interval).rounded(.up))
        let last = max(first, Int((range.upperBound / Self.interval).rounded(.down)))
        let indices = Array(first...last)

        let missing = indices.filter { cache[$0] == nil }
        if !missing.isEmpty {
            let generator = AVAssetImageGenerator(asset: video)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: Self.analysisSide, height: Self.analysisSide)
            let tolerance = CMTime(seconds: Self.interval / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            let times = missing.map { CMTime(seconds: Double($0) * Self.interval, preferredTimescale: 600) }
            for await result in generator.images(for: times) {
                if Task.isCancelled { return [] }
                let index = Int((result.requestedTime.seconds / Self.interval).rounded())
                cache[index] = (try? result.image).map { Self.subjects(in: $0, horizontal: horizontal) } ?? []
            }
        }

        let times = indices.map { max(0, Double($0) * Self.interval - range.lowerBound) }
        var previous: CGFloat?
        let centers = indices.map { index -> CGFloat? in
            let center = ReelCrop.focus(cache[index] ?? [], window: window, previous: previous)
            if let center { previous = center }
            return center
        }
        return ReelCrop.keyframes(times: times, centers: centers)
    }

    private static func subjects(in image: CGImage, horizontal: Bool) -> [ReelCrop.Subject] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        SubjectDetector.prepare(faces)
        SubjectDetector.prepare(animals)
        try? handler.perform([faces, animals])

        var found: [VNDetectedObjectObservation] = faces.results ?? []
        if found.isEmpty {
            found = animals.results ?? []
        }
        if found.isEmpty {
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            SubjectDetector.prepare(saliency)
            try? handler.perform([saliency])
            found = saliency.results?.first?.salientObjects ?? []
        }
        return found.map { observation in
            let box = observation.boundingBox
            let weight = box.width * box.height * CGFloat(observation.confidence)
            if horizontal {
                return ReelCrop.Subject(lower: box.minX, upper: box.maxX, weight: weight)
            }
            // Vision 은 왼쪽 아래가 원점이라 위아래를 뒤집습니다.
            return ReelCrop.Subject(lower: 1 - box.maxY, upper: 1 - box.minY, weight: weight)
        }
    }
}
