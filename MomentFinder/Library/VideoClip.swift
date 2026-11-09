import AVFoundation
import Photos

/// 동영상에서 찾은 장면 부분만 잘라 새 동영상으로 보관함에 저장합니다. 원본은 건드리지 않습니다.
enum VideoClip {
    /// 고를 수 있는 클립 길이(초).
    static let lengths: [Double] = [3, 5, 10, 15]
    /// 편집 앱의 사진 고르기 화면에서 바로 찾을 수 있도록 클립을 모아 두는 앨범.
    static let albumTitle = "Moment Finder"

    /// moment 를 가운데에 두고 length 초를 고릅니다. 동영상 앞뒤에 걸리면 안쪽으로 밀어 길이를 지킵니다.
    static func range(around moment: Double, length: Double, duration: Double) -> ClosedRange<Double> {
        guard duration > length else { return 0...max(duration, 0) }
        let start = min(max(moment - length / 2, 0), duration - length)
        return start...(start + length)
    }

    static func save(from asset: PHAsset, range: ClosedRange<Double>) async throws {
        guard let video = await PhotoLibrary.videoAsset(for: asset, allowNetwork: true, deliveryMode: .highQualityFormat) else {
            throw CocoaError(.fileReadUnknown)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clips", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("Clip.mov")
        try await export(video, range: range, to: url)
        try await addToLibrary(url, original: asset)
    }

    /// 화질을 지키려고 HEVC 최고 화질로 다시 인코딩합니다. 키프레임에 맞춰 잘리지 않아 찾은 장면 그대로 시작합니다.
    static func export(_ video: AVAsset, range: ClosedRange<Double>, to url: URL) async throws {
        var preset: String?
        for candidate in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            if await AVAssetExportSession.compatibility(ofExportPreset: candidate, with: video, outputFileType: .mov) {
                preset = candidate
                break
            }
        }
        guard let preset, let session = AVAssetExportSession(asset: video, presetName: preset) else {
            throw CocoaError(.featureUnsupported)
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
        )
        try await session.export(to: url, as: .mov)
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
