import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import MomentFinder

struct VideoClipTests {
    @Test func centersClipOnMoment() {
        #expect(VideoClip.range(around: 20, length: 6, duration: 60) == 17...23)
    }

    @Test func shiftsClipInsideVideoKeepingLength() {
        #expect(VideoClip.range(around: 1, length: 6, duration: 60) == 0...6)
        #expect(VideoClip.range(around: 59, length: 6, duration: 60) == 54...60)
    }

    @Test func usesWholeVideoWhenShorterThanClip() {
        #expect(VideoClip.range(around: 2, length: 10, duration: 4) == 0...4)
    }

    // MARK: - Scene range

    /// 0.5초부터 1초 간격 프레임. high 에 든 시각만 점수가 높습니다.
    private func scores(count: Int, high: Set<Double>, highScore: Float = 0.28) -> [FrameScore] {
        (0..<count).map { index in
            let time = Double(index) + 0.5
            return FrameScore(time: time, score: high.contains(time) ? highScore : 0.15)
        }
    }

    @Test func sceneRangeCoversContinuousMatchingFrames() {
        let range = VideoClip.sceneRange(scores: scores(count: 20, high: [6.5, 7.5, 8.5, 9.5]), moment: 7.5, duration: 20)
        #expect(range == 6...10)
    }

    @Test func sceneRangeStopsAtGapInMatches() {
        let range = VideoClip.sceneRange(scores: scores(count: 20, high: [4.5, 5.5, 6.5, 7.5, 12.5, 13.5]), moment: 5.5, duration: 20)
        #expect(range == 4...8)
    }

    @Test func sceneRangeCoversMatchesFillingMostOfVideo() {
        let range = VideoClip.sceneRange(scores: scores(count: 10, high: [4.5, 5.5, 6.5, 7.5, 8.5, 9.5]), moment: 6.5, duration: 10)
        #expect(range == 4...10)
    }

    @Test func sceneRangeIgnoresSmallWobbleWhenWholeVideoMatches() {
        let wobble: [Float] = [0.25, 0.26, 0.245, 0.26, 0.25, 0.255, 0.26, 0.25]
        let scores = wobble.enumerated().map { FrameScore(time: Double($0.offset) + 0.5, score: $0.element) }
        #expect(VideoClip.sceneRange(scores: scores, moment: 3.5, duration: 8) == 0...8)
    }

    @Test func sceneRangeKeepsMinimumLength() {
        let range = VideoClip.sceneRange(scores: scores(count: 20, high: [10.5]), moment: 10.5, duration: 20)
        #expect(range == 9...12)
    }

    @Test func sceneRangeCapsLongScenesAroundMoment() {
        let all = Set((0..<60).map { Double($0) + 0.5 })
        let range = VideoClip.sceneRange(scores: scores(count: 60, high: all), moment: 40.5, duration: 60)
        #expect(range == 25.5...55.5)
    }

    @Test func sceneRangeNeedsAnalyzedScenes() {
        #expect(VideoClip.sceneRange(scores: [FrameScore(time: 0, score: 0.3)], moment: 0, duration: 10) == nil)
    }

    @Test func frameScoresListOnlyThatVideoInTimeOrder() async {
        let index = SearchIndex(dimension: 2)
        await index.add(assetID: "a", kind: .video, frames: [
            FrameEmbedding(time: 2, vector: [0, 1]),
            FrameEmbedding(time: 1, vector: [1, 0]),
        ])
        await index.add(assetID: "b", kind: .video, frames: [FrameEmbedding(time: 0, vector: [1, 0])])

        let scores = await index.frameScores([1, 0], assetID: "a")
        #expect(scores == [FrameScore(time: 1, score: 1), FrameScore(time: 2, score: 0)])
        #expect(await index.frameScores([1, 0], assetID: "missing").isEmpty)
    }

    // MARK: - Trimming

    @Test func trimmingKeepsMinimumLengthAndStaysInsideVideo() {
        #expect(VideoClip.trimmed(2...6, edge: .start, by: 10, duration: 20) == 5...6)
        #expect(VideoClip.trimmed(2...6, edge: .start, by: -5, duration: 20) == 0...6)
        #expect(VideoClip.trimmed(2...6, edge: .end, by: -10, duration: 20) == 2...3)
        #expect(VideoClip.trimmed(2...6, edge: .end, by: 30, duration: 20) == 2...20)
    }

    @Test func movingWholeRangeKeepsLength() {
        #expect(VideoClip.trimmed(2...6, edge: .whole, by: 3, duration: 20) == 5...9)
        #expect(VideoClip.trimmed(2...6, edge: .whole, by: 30, duration: 20) == 16...20)
        #expect(VideoClip.trimmed(2...6, edge: .whole, by: -30, duration: 20) == 0...4)
    }

    // MARK: - Vertical crop

    @Test func landscapeCropMovesHorizontallyInsideFrame() {
        let size = CGSize(width: 1920, height: 1080)
        #expect(ReelCrop.movesHorizontally(size))
        #expect(ReelCrop.cropRect(displaySize: size, center: 0.5) == CGRect(x: 656.25, y: 0, width: 607.5, height: 1080))
        #expect(ReelCrop.cropRect(displaySize: size, center: 0).minX == 0)
        #expect(ReelCrop.cropRect(displaySize: size, center: 1).maxX == 1920)
    }

    @Test func tallVideoCropMovesVertically() {
        let size = CGSize(width: 1080, height: 2400)
        #expect(!ReelCrop.movesHorizontally(size))
        let crop = ReelCrop.cropRect(displaySize: size, center: 0)
        #expect(crop == CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }

    @Test func clampsCenterToReachablePosition() {
        let size = CGSize(width: 1920, height: 1080)
        let center = ReelCrop.clampedCenter(0, displaySize: size)
        #expect(abs(center - 303.75 / 1920) < 0.0001)
    }

    @Test func transformMovesCropToRenderOrigin() {
        let natural = CGSize(width: 1920, height: 1080)
        let transform = ReelCrop.transform(natural: natural, preferred: .identity, center: 0.5)
        let crop = ReelCrop.cropRect(displaySize: natural, center: 0.5)
        let mapped = crop.applying(transform)
        #expect(abs(mapped.minX) < 0.001 && abs(mapped.minY) < 0.001)
        #expect(abs(mapped.width - 1080) < 0.001 && abs(mapped.height - 1920) < 0.001)
    }

    @Test func transformHandlesRotatedPortraitVideo() {
        // 세로로 찍은 아이폰 동영상: 1920×1080 으로 저장되고 90도 돌려 보여줍니다.
        let natural = CGSize(width: 1920, height: 1080)
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let transform = ReelCrop.transform(natural: natural, preferred: rotate, center: 0.5)
        let mapped = CGRect(origin: .zero, size: natural).applying(transform)
        #expect(abs(mapped.minX) < 0.001 && abs(mapped.minY) < 0.001)
        #expect(abs(mapped.width - 1080) < 0.001 && abs(mapped.height - 1920) < 0.001)
    }

    @Test func keyframesFillMissingAndSmoothJitter() {
        let times = (0..<9).map { Double($0) * 0.5 }
        let centers: [CGFloat?] = [nil, 0.3, 0.7, 0.3, 0.7, 0.3, 0.7, 0.3, nil]
        let frames = ReelCrop.keyframes(times: times, centers: centers)
        #expect(frames.map(\.time) == times)
        #expect(frames.allSatisfy { abs($0.center - 0.5) < 0.12 })
    }

    @Test func focusFramesOneSubjectInsteadOfTheGapBetweenThem() {
        let left = ReelCrop.Subject(lower: 0.04, upper: 0.46, weight: 0.2)
        let right = ReelCrop.Subject(lower: 0.55, upper: 0.85, weight: 0.3)
        #expect(ReelCrop.focus([left, right], window: 0.42, previous: nil) == right.center)
        #expect(ReelCrop.focus([left, right], window: 0.42, previous: 0.3) == left.center)
    }

    @Test func focusKeepsGroupThatFitsTheWindow() {
        let a = ReelCrop.Subject(lower: 0.3, upper: 0.4, weight: 0.1)
        let b = ReelCrop.Subject(lower: 0.5, upper: 0.6, weight: 0.1)
        #expect(abs((ReelCrop.focus([a, b], window: 0.42, previous: nil) ?? 0) - 0.45) < 0.0001)
    }

    @Test func focusIgnoresSmallSubjectsNearPrevious() {
        let big = ReelCrop.Subject(lower: 0.6, upper: 0.9, weight: 0.3)
        let tiny = ReelCrop.Subject(lower: 0.05, upper: 0.1, weight: 0.01)
        #expect(ReelCrop.focus([big, tiny], window: 0.42, previous: 0.1) == big.center)
        #expect(ReelCrop.focus([], window: 0.42, previous: 0.1) == nil)
    }

    @Test func keyframesDefaultToCenterWithoutSubjects() {
        let frames = ReelCrop.keyframes(times: [0, 0.5], centers: [nil, nil])
        #expect(frames == [ReelCrop.Keyframe(time: 0, center: 0.5)])
    }

    @Test func interpolatesCenterBetweenKeyframes() {
        let frames = [ReelCrop.Keyframe(time: 0, center: 0.2), ReelCrop.Keyframe(time: 2, center: 0.6)]
        #expect(abs(ReelCrop.center(at: 1, in: frames) - 0.4) < 0.0001)
        #expect(ReelCrop.center(at: -1, in: frames) == 0.2)
        #expect(ReelCrop.center(at: 5, in: frames) == 0.6)
    }

    // MARK: - Export

    @Test func exportsOnlyRequestedRange() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await writeTestVideo(to: source, seconds: 4)

        let clip = folder.appendingPathComponent("clip.mov")
        try await VideoClip.export(AVURLAsset(url: source), options: VideoClip.Options(range: 1...3), to: clip)

        let duration = try await AVURLAsset(url: clip).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    @Test func exportsVerticalCropAtReelSize() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        // 왼쪽 절반은 검정, 오른쪽 절반은 흰색.
        try await writeTestVideo(to: source, seconds: 2, side: 128) { _, x in x < 64 ? 0 : 255 }

        let right = folder.appendingPathComponent("right.mov")
        let left = folder.appendingPathComponent("left.mov")
        try await VideoClip.export(AVURLAsset(url: source), options: VideoClip.Options(
            range: 0...2, verticalCrop: [ReelCrop.Keyframe(time: 0, center: 1)]), to: right)
        try await VideoClip.export(AVURLAsset(url: source), options: VideoClip.Options(
            range: 0...2, verticalCrop: [ReelCrop.Keyframe(time: 0, center: 0)]), to: left)

        let track = try #require(try await AVURLAsset(url: right).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == ReelCrop.renderSize)
        #expect(try await centerBrightness(of: right) > 200)
        #expect(try await centerBrightness(of: left) < 50)
    }

    @Test func exportCanDropAudio() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoURL = folder.appendingPathComponent("video.mov")
        let audioURL = folder.appendingPathComponent("audio.caf")
        try await writeTestVideo(to: videoURL, seconds: 2)
        try writeSilence(to: audioURL, seconds: 2)
        let source = try await combine(video: AVURLAsset(url: videoURL), audio: AVURLAsset(url: audioURL))

        let withAudio = folder.appendingPathComponent("with.mov")
        let withoutAudio = folder.appendingPathComponent("without.mov")
        try await VideoClip.export(source, options: VideoClip.Options(range: 0...2), to: withAudio)
        try await VideoClip.export(source, options: VideoClip.Options(range: 0...2, includesAudio: false), to: withoutAudio)

        #expect(try await AVURLAsset(url: withAudio).loadTracks(withMediaType: .audio).count == 1)
        #expect(try await AVURLAsset(url: withoutAudio).loadTracks(withMediaType: .audio).isEmpty)
    }

    // MARK: - Helpers

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 30fps 작은 동영상을 만듭니다. 기본은 매 프레임 밝기가 바뀌고, pixel 로 프레임·가로 위치별 밝기를 정할 수 있습니다.
    private func writeTestVideo(
        to url: URL,
        seconds: Int,
        side: Int = 64,
        pixel: (_ frame: Int, _ x: Int) -> UInt8 = { frame, _ in UInt8(frame * 2 % 256) }
    ) async throws {
        let fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<side {
                for x in 0..<side {
                    let value = pixel(frame, x)
                    let offset = y * bytesPerRow + x * 4
                    base[offset] = value
                    base[offset + 1] = value
                    base[offset + 2] = value
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func writeSilence(to url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func combine(video: AVAsset, audio: AVAsset) async throws -> AVAsset {
        let composition = AVMutableComposition()
        for (asset, type) in [(video, AVMediaType.video), (audio, .audio)] {
            let source = try #require(try await asset.loadTracks(withMediaType: type).first)
            let track = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(try await source.load(.timeRange), of: source, at: .zero)
        }
        return composition
    }

    private func centerBrightness(of url: URL) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return Int(pixel[0])
    }
}
