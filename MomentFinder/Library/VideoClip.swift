import AVFoundation
import Photos

/// 동영상에서 찾은 장면 부분만 잘라 새 동영상으로 보관함에 저장합니다. 원본은 건드리지 않습니다.
enum VideoClip {
    /// 고를 수 있는 클립 길이(초).
    static let lengths: [Double] = [3, 5, 10, 15]
    /// 장면 구간을 자동으로 잡을 때 너무 짧거나 길지 않게 이 범위 안으로 맞춥니다.
    static let sceneLengthLimits: ClosedRange<Double> = 3...30
    /// 손으로 줄일 수 있는 가장 짧은 길이.
    static let minimumLength: Double = 1
    /// 편집 앱의 사진 고르기 화면에서 바로 찾을 수 있도록 클립을 모아 두는 앨범.
    static let albumTitle = "Moment Finder"

    struct Options: Sendable {
        var range: ClosedRange<Double>
        /// 있으면 9:16 세로로 잘라 1080×1920 SDR 로 내보냅니다. 없으면 원본 화면비와 색 그대로입니다.
        var verticalCrop: [ReelCrop.Keyframe]?
        var includesAudio = true
    }

    /// moment 를 가운데에 두고 length 초를 고릅니다. 동영상 앞뒤에 걸리면 안쪽으로 밀어 길이를 지킵니다.
    static func range(around moment: Double, length: Double, duration: Double) -> ClosedRange<Double> {
        guard duration > length else { return 0...max(duration, 0) }
        let start = min(max(moment - length / 2, 0), duration - length)
        return start...(start + length)
    }

    enum TrimEdge {
        case start, end, whole
    }

    /// 한쪽 끝(또는 구간 전체)을 delta 초만큼 옮깁니다. 동영상 밖으로 나가거나 minimumLength 보다 짧아지지 않습니다.
    static func trimmed(_ origin: ClosedRange<Double>, edge: TrimEdge, by delta: Double, duration: Double) -> ClosedRange<Double> {
        let shortest = min(minimumLength, duration)
        switch edge {
        case .start:
            let start = min(max(origin.lowerBound + delta, 0), origin.upperBound - shortest)
            return start...origin.upperBound
        case .end:
            let end = max(min(origin.upperBound + delta, duration), origin.lowerBound + shortest)
            return origin.lowerBound...end
        case .whole:
            let length = origin.upperBound - origin.lowerBound
            let start = min(max(origin.lowerBound + delta, 0), max(0, duration - length))
            return start...(start + length)
        }
    }

    /// 찾은 장면 점수와 이 차이 안의 프레임은 같은 장면으로 봅니다. 동영상 전체가 비슷하게 맞을 때 작은 흔들림에 구간이 끊기지 않게 합니다.
    static let sceneScoreTolerance: Float = 0.02

    /// 찾은 장면에서 시작해 검색어와 계속 잘 맞는 앞뒤 프레임까지 넓혀 장면 하나를 통째로 고릅니다.
    /// 기준은 동영상에서 가장 안 맞는 축(하위 10%)과 찾은 장면 점수의 가운데라, 점수 크기가 검색어마다 달라도 같은 방식으로 동작하고
    /// 맞는 장면이 동영상 대부분을 차지해도 잘리지 않습니다. 장면 분석 전이라 프레임이 너무 적으면 nil 입니다.
    static func sceneRange(scores: [FrameScore], moment: Double, duration: Double) -> ClosedRange<Double>? {
        guard scores.count >= 3, duration > 0 else { return nil }
        let peak = scores.indices.min { abs(scores[$0].time - moment) < abs(scores[$1].time - moment) }!
        let sorted = scores.map(\.score).sorted()
        let low = sorted[(sorted.count - 1) / 10]
        let peakScore = scores[peak].score
        let threshold = min(low + (peakScore - low) / 2, peakScore - sceneScoreTolerance)

        var first = peak, last = peak
        while first > 0, scores[first - 1].score >= threshold { first -= 1 }
        while last < scores.count - 1, scores[last + 1].score >= threshold { last += 1 }

        let gaps = zip(scores, scores.dropFirst()).map { $1.time - $0.time }.sorted()
        let step = gaps[gaps.count / 2]
        let start = max(0, scores[first].time - step / 2)
        let end = min(duration, scores[last].time + step / 2)
        let length = end - start

        if length < sceneLengthLimits.lowerBound {
            return range(around: (start + end) / 2, length: sceneLengthLimits.lowerBound, duration: duration)
        }
        if length > sceneLengthLimits.upperBound {
            return range(around: scores[peak].time, length: sceneLengthLimits.upperBound, duration: duration)
        }
        return start...end
    }

    static func save(from asset: PHAsset, options: Options) async throws {
        guard let video = await PhotoLibrary.videoAsset(for: asset, allowNetwork: true, deliveryMode: .highQualityFormat) else {
            throw CocoaError(.fileReadUnknown)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clips", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("Clip.mov")
        try await export(video, options: options, to: url)
        try await addToLibrary(url, original: asset)
    }

    /// 화질을 지키려고 HEVC 최고 화질로 다시 인코딩합니다. 키프레임에 맞춰 잘리지 않아 찾은 장면 그대로 시작합니다.
    static func export(_ video: AVAsset, options: Options, to url: URL) async throws {
        let (composition, videoTrack) = try await clipComposition(of: video, options: options)

        var preset: String?
        for candidate in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            if await AVAssetExportSession.compatibility(ofExportPreset: candidate, with: composition, outputFileType: .mov) {
                preset = candidate
                break
            }
        }
        guard let preset, let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw CocoaError(.featureUnsupported)
        }
        if let keyframes = options.verticalCrop {
            session.videoComposition = try await verticalComposition(for: composition, track: videoTrack, keyframes: keyframes)
        }
        try await session.export(to: url, as: .mov)
    }

    /// 고른 구간만 0초부터 담은 컴포지션. 소리를 빼면 오디오 트랙을 넣지 않습니다.
    private static func clipComposition(of video: AVAsset, options: Options) async throws -> (AVMutableComposition, AVMutableCompositionTrack) {
        let range = CMTimeRange(
            start: CMTime(seconds: options.range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: options.range.upperBound, preferredTimescale: 600)
        )
        let composition = AVMutableComposition()
        guard let source = try await video.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported)
        }
        try await insert(range, of: source, into: videoTrack)
        videoTrack.preferredTransform = try await source.load(.preferredTransform)

        if options.includesAudio {
            for source in try await video.loadTracks(withMediaType: .audio) {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try await insert(range, of: source, into: track)
            }
        }
        return (composition, videoTrack)
    }

    /// 트랙 길이가 조금씩 달라도 실패하지 않도록 겹치는 부분만, 구간 시작에서 떨어진 만큼 띄워 넣습니다.
    private static func insert(_ range: CMTimeRange, of source: AVAssetTrack, into track: AVMutableCompositionTrack) async throws {
        let available = range.intersection(try await source.load(.timeRange))
        guard !available.isEmpty else { return }
        try track.insertTimeRange(available, of: source, at: available.start - range.start)
    }

    /// 키프레임 사이를 변환 램프로 이어 자르는 창이 부드럽게 움직이게 합니다.
    /// 릴스는 HDR 을 제대로 보여주지 못하는 경우가 많아 SDR(Rec.709)로 바꿔 내보냅니다.
    private static func verticalComposition(
        for composition: AVMutableComposition,
        track: AVMutableCompositionTrack,
        keyframes: [ReelCrop.Keyframe]
    ) async throws -> AVVideoComposition {
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        videoComposition.renderSize = ReelCrop.renderSize
        let fastest = CMTime(value: 1, timescale: 60)
        if videoComposition.frameDuration < fastest { videoComposition.frameDuration = fastest }
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let frames = keyframes.isEmpty ? [ReelCrop.Keyframe(time: 0, center: 0.5)] : keyframes
        func transform(_ frame: ReelCrop.Keyframe) -> CGAffineTransform {
            ReelCrop.transform(natural: natural, preferred: preferred, center: frame.center)
        }
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        layer.setTransform(transform(frames[0]), at: .zero)
        for (a, b) in zip(frames, frames.dropFirst()) where b.time > a.time {
            layer.setTransformRamp(fromStart: transform(a), toEnd: transform(b),
                                   timeRange: CMTimeRange(start: time(a.time), end: time(b.time)))
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    private static func addToLibrary(_ url: URL, original: PHAsset) async throws {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject

        try await PHPhotoLibrary.shared().performChanges {
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.shouldMoveFile = true
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: resourceOptions)
            request.location = original.location
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            let albumRequest: PHAssetCollectionChangeRequest? = if let album {
                PHAssetCollectionChangeRequest(for: album)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            }
            albumRequest?.addAssets([placeholder] as NSArray)
        }
    }
}
