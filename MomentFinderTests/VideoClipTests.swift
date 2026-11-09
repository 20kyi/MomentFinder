import AVFoundation
import CoreVideo
import Foundation
import Photos
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

    @Test func TEMP_savesClipIntoAlbum() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.mov")
        try await writeTestVideo(to: source, seconds: 10)
        #expect(await PhotoLibrary.requestAuthorization() == .authorized)
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: source, options: nil)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        let createdID = try #require(id)
        let original = try #require(PHAsset.fetchAssets(withLocalIdentifiers: [createdID], options: nil).firstObject)

        let clock = ContinuousClock()
        var mark = clock.now
        func lap(_ name: String) { print("TEMP \(name):", clock.now - mark); mark = clock.now }
        let video = await PhotoLibrary.videoAsset(for: original, allowNetwork: true, deliveryMode: .highQualityFormat)
        lap("request")
        try await VideoClip.export(try #require(video), range: 1...4, to: folder.appendingPathComponent("a.mov"))
        lap("export")
        try await VideoClip.save(from: original, range: VideoClip.range(around: 6, length: 3, duration: 10))
        lap("save1")
        try await VideoClip.save(from: original, range: VideoClip.range(around: 9, length: 5, duration: 10))
        lap("save2")

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", VideoClip.albumTitle)
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        #expect(albums.count == 1)
        let clips = PHAsset.fetchAssets(in: try #require(albums.firstObject), options: nil)
        var durations: [Double] = []
        clips.enumerateObjects { asset, _, _ in durations.append(asset.duration) }
        print("TEMP clips:", durations)
        #expect(durations.count == 2)
        #expect(durations.contains { abs($0 - 3) < 0.1 } && durations.contains { abs($0 - 5) < 0.1 })
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
