import Foundation
import Photos

/// 사진 보관함과 인덱스를 비교해 새 에셋은 임베딩하고, 사라진 에셋은 지웁니다.
/// 에셋마다 바로 저장하므로 중간에 멈춰도 다음 실행 때 이어서 진행됩니다.
///
/// 저장 공간 최적화를 켠 보관함에서도 빨리 검색할 수 있도록 세 단계로 나눠 진행합니다.
/// 1. 사진: 기기에 있는 작은 미리보기로 분석합니다.
/// 2. 동영상 대표 이미지: 내려받지 않고 한 장만 분석해 우선 검색되게 합니다.
/// 3. 동영상 장면: 원본에서 1초 간격으로 장면을 분석합니다. 기기에 있는 동영상부터, 그다음 iCloud 동영상을 내려받습니다.
actor Indexer {
    struct Options: Sendable {
        var allowNetwork: Bool
        var includeVideos: Bool
    }

    private let store: IndexStore
    private let searchIndex: SearchIndex
    private let encoder: CLIPEncoder
    /// 대부분의 시간은 PhotoKit 이 이미지를 디코딩하거나 iCloud 에서 내려받는 대기 시간이라 추론 장치 수보다 넉넉히 겹칩니다.
    private let quickConcurrency = 8
    /// 장면 분석은 한 건이 무겁고(원본 다운로드 + 최대 60장면) 다운로드끼리 대역폭을 나눠 쓰므로 적게 겹칩니다.
    private let sceneConcurrency = 3
    private let progressInterval: Duration = .milliseconds(250)
    private let clock = ContinuousClock()
    private var lastReport = ContinuousClock.now

    init(store: IndexStore, searchIndex: SearchIndex, encoder: CLIPEncoder) {
        self.store = store
        self.searchIndex = searchIndex
        self.encoder = encoder
    }

    func run(options: Options, onProgress: @escaping @Sendable (IndexProgress) async -> Void) async {
        let assets = PhotoLibrary.fetchAllAssets()
        let liveIDs = Set(assets.map(\.localIdentifier))

        let removed = ((try? store.allAssetIDs()) ?? []).subtracting(liveIDs)
        if !removed.isEmpty {
            try? store.delete(assetIDs: removed)
            await searchIndex.remove(removed)
        }

        let indexed = (try? store.indexedAssetIDs(model: CLIPEncoder.modelName)) ?? []
        let photos = assets.filter { $0.mediaType == .image }
        let videos = options.includeVideos ? assets.filter { $0.mediaType == .video } : []
        let pending = (photos + videos).filter { !indexed.contains($0.localIdentifier) }

        var progress = IndexProgress(total: photos.count + videos.count, indexed: photos.count + videos.count - pending.count)
        progress.videoTotal = videos.count
        let previews = (try? store.previewAssetIDs(model: CLIPEncoder.modelName)) ?? []
        progress.videoScenesDone = videos.filter { indexed.contains($0.localIdentifier) && !previews.contains($0.localIdentifier) }.count
        await onProgress(progress)

        await forEach(pending, concurrency: quickConcurrency) { asset in
            await self.indexQuick(asset, allowNetwork: options.allowNetwork)
        } completed: { succeeded in
            if succeeded { progress.indexed += 1 } else { progress.failed += 1 }
            await report(progress, onProgress)
        }
        await onProgress(progress)

        for allowNetwork in options.allowNetwork ? [false, true] : [false] {
            guard !Task.isCancelled else { break }
            let previewIDs = (try? store.previewAssetIDs(model: CLIPEncoder.modelName)) ?? []
            let remaining = videos.filter { previewIDs.contains($0.localIdentifier) }
            await forEach(remaining, concurrency: sceneConcurrency) { asset in
                await self.indexScenes(asset, allowNetwork: allowNetwork)
            } completed: { succeeded in
                if succeeded { progress.videoScenesDone += 1 }
                await report(progress, onProgress)
            }
        }
        await onProgress(progress)
    }

    private func forEach(
        _ assets: [PHAsset],
        concurrency: Int,
        work: @escaping @Sendable (PHAsset) async -> Bool,
        completed: (Bool) async -> Void
    ) async {
        await withTaskGroup(of: Bool.self) { group in
            var queue = assets.makeIterator()
            for _ in 0..<concurrency {
                guard let asset = queue.next() else { break }
                group.addTask { await work(asset) }
            }
            while let succeeded = await group.next() {
                await completed(succeeded)
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let asset = queue.next() {
                    group.addTask { await work(asset) }
                }
            }
        }
    }

    private func report(_ progress: IndexProgress, _ onProgress: @Sendable (IndexProgress) async -> Void) async {
        guard clock.now - lastReport >= progressInterval else { return }
        lastReport = clock.now
        await onProgress(progress)
    }

    /// 사진은 그대로 완료, 동영상은 대표 이미지 한 장만 넣어 preview 로 저장합니다.
    private nonisolated func indexQuick(_ asset: PHAsset, allowNetwork: Bool) async -> Bool {
        guard !Task.isCancelled,
              let image = await PhotoLibrary.analysisImage(for: asset, allowNetwork: allowNetwork),
              let vector = try? await encoder.embed(image: image.cgImage, orientation: image.orientation) else { return false }
        let kind: MediaKind = asset.mediaType == .video ? .video : .photo
        return await save(asset, kind: kind, detail: kind == .video ? .preview : .complete, frames: [FrameEmbedding(time: 0, vector: vector)])
    }

    /// 원본을 얻지 못하면(iCloud 에만 있고 네트워크를 못 쓰는 경우 등) preview 상태로 남겨 다음에 다시 시도합니다.
    private nonisolated func indexScenes(_ asset: PHAsset, allowNetwork: Bool) async -> Bool {
        guard !Task.isCancelled,
              let video = await PhotoLibrary.videoAsset(for: asset, allowNetwork: allowNetwork) else { return false }
        var frames: [FrameEmbedding] = []
        await VideoFrameSampler.forEachFrame(from: video, duration: asset.duration) { time, image in
            if let vector = try? await encoder.embed(image: image) {
                frames.append(FrameEmbedding(time: time, vector: vector))
            }
        }
        guard !frames.isEmpty, !Task.isCancelled else { return false }
        return await save(asset, kind: .video, detail: .complete, frames: frames)
    }

    private nonisolated func save(_ asset: PHAsset, kind: MediaKind, detail: IndexDetail, frames: [FrameEmbedding]) async -> Bool {
        do {
            try store.save(
                assetID: asset.localIdentifier,
                kind: kind,
                created: asset.creationDate,
                duration: asset.duration,
                model: CLIPEncoder.modelName,
                detail: detail,
                frames: frames
            )
        } catch {
            return false
        }
        await searchIndex.add(assetID: asset.localIdentifier, kind: kind, frames: frames)
        return true
    }
}
