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
    static func videoFrame(for asset: PHAsset, at seconds: Double, side: CGFloat) async -> PlatformImage? {
        guard seconds > 0, let video = await videoAsset(for: asset, allowNetwork: false) else { return nil }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
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
