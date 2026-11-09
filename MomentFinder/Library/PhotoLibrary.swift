import AVFoundation
import Foundation
import ImageIO
import Photos
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct AnalysisImage: @unchecked Sendable {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
}

/// PhotoKit 래퍼. iCloud 사진도 같은 API로 접근하며, allowNetwork 가 true 면 필요할 때 내려받습니다.
enum PhotoLibrary {
    /// CLIP 입력(256px)보다 약간 크게 요청해 센터 크롭 후에도 해상도가 충분하도록 합니다.
    static let analysisSide: CGFloat = 320
    /// 얼굴 인식은 단체 사진 속 작은 얼굴도 잡아야 해서 사진 전체를 이 크기 안에 맞춰 따로 요청합니다.
    static let subjectAnalysisSide: CGFloat = 1024

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func fetchAllAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    static func assets(withIDs ids: [String]) -> [String: PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in map[asset.localIdentifier] = asset }
        return map
    }

    static func analysisImage(
        for asset: PHAsset,
        side: CGFloat = analysisSide,
        contentMode: PHImageContentMode = .aspectFill,
        allowNetwork: Bool
    ) async -> AnalysisImage? {
        guard let image = await image(for: asset, side: side, contentMode: contentMode, allowNetwork: allowNetwork),
              let cgImage = image.cgImageValue else { return nil }
        return AnalysisImage(cgImage: cgImage, orientation: image.cgOrientation)
    }

    static func image(
        for asset: PHAsset,
        side: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        allowNetwork: Bool
    ) async -> PlatformImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: contentMode,
                options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard once.claim() else { return }
                continuation.resume(returning: image)
            }
        }
    }

    static func videoAsset(for asset: PHAsset, allowNetwork: Bool) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .fastFormat
        options.version = .current

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    /// 검색에 걸린 장면을 썸네일로 보여주기 위해 해당 시각의 프레임을 뽑습니다. 기기에 있는 동영상만 사용합니다.
    /// seconds 는 분석 때 실제로 디코딩된 프레임 시각이라, 허용 오차 없이 요청해야 근처 키프레임이 아닌 그 장면이 나옵니다.
    static func videoFrame(for asset: PHAsset, at seconds: Double, side: CGFloat) async -> PlatformImage? {
        guard seconds > 0, let video = await videoAsset(for: asset, allowNetwork: false) else { return nil }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }

    /// 사진 앱의 재생바처럼 동영상 전체에서 고르게 뽑은 작은 장면들.
    static func filmstrip(for asset: PHAsset, count: Int, side: CGFloat) async -> [PlatformImage] {
        guard count > 0, let video = await videoAsset(for: asset, allowNetwork: true),
              let duration = try? await video.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        var frames: [PlatformImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            guard !Task.isCancelled, let (cgImage, _) = try? await generator.image(at: time) else { continue }
            #if canImport(UIKit)
            frames.append(UIImage(cgImage: cgImage))
            #else
            frames.append(NSImage(cgImage: cgImage, size: .zero))
            #endif
        }
        return frames
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - Editing

    /// Photos 앱의 즐겨찾기와 같은 값을 바꿉니다.
    static func setFavorite(_ isFavorite: Bool, for asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = isFavorite
        }
    }

    /// 시스템이 삭제 확인 창을 띄우고, 지운 항목은 Photos 앱의 '최근 삭제된 항목'으로 갑니다.
    /// 사용자가 확인 창에서 취소하면 false 를 돌려줍니다.
    static func delete(_ assets: [PHAsset]) async throws -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
        }
    }

    private static var shareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
    }

    /// 공유용으로 원본(편집했다면 편집본)을 임시 폴더에 내려받습니다. iCloud 에만 있으면 내려받습니다.
    /// 공유 시트는 넘겨받은 파일을 자기 쪽으로 복사하므로, 다음 공유 때 이전에 내보낸 파일을 지워 원본이 쌓이지 않게 합니다.
    static func exportOriginal(of asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        removeSharedExports()
        let folder = shareFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(resource.originalFilename)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }

    static func removeSharedExports() {
        try? FileManager.default.removeItem(at: shareFolder)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
