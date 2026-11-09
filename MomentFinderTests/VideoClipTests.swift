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

    @Test func exportsOnlyRequestedRange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await writeTestVideo(to: source, seconds: 4)

        let clip = folder.appendingPathComponent("clip.mov")
        try await VideoClip.export(AVURLAsset(url: source), range: 1...3, to: clip)

        let duration = try await AVURLAsset(url: clip).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    /// 30fps 로 매 프레임 밝기가 바뀌는 작은 동영상을 만듭니다.
    private func writeTestVideo(to url: URL, seconds: Int) async throws {
        let side = 64, fps: Int32 = 30
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
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 2 % 256), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
