import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 공유 시트에 넘기는 사진·동영상. 받는 쪽이 요청할 때 원본을 내려받아 파일로 건넵니다.
struct SharedAsset: Transferable {
    let asset: PHAsset
    /// 한 번에 함께 공유하는 항목끼리 같은 값을 씁니다.
    var session = UUID()

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { try await SentTransferredFile(PhotoLibrary.exportOriginal(of: $0.asset, session: $0.session)) }
            .exportingCondition { $0.asset.mediaType == .video }
        FileRepresentation(exportedContentType: .image) { try await SentTransferredFile(PhotoLibrary.exportOriginal(of: $0.asset, session: $0.session)) }
            .exportingCondition { $0.asset.mediaType == .image }
    }
}

/// 고른 사진·동영상을 고른 순서대로 한 번에 공유합니다.
struct MultiAssetShareLink: View {
    let items: [ResultItem]
    @State private var previews: [String: PlatformImage] = [:]

    var body: some View {
        let session = UUID()
        ShareLink(items: items.map { SharedAsset(asset: $0.asset, session: session) }) { shared in
            let image = previews[shared.asset.localIdentifier].map { Image(platformImage: $0) }
            return SharePreview(shared.asset.mediaType == .video ? "동영상" : "사진", image: image ?? Image(systemName: "photo"))
        } label: {
            Label("공유", systemImage: "square.and.arrow.up")
        }
        .disabled(items.isEmpty)
        .accessibilityIdentifier("share-selection-button")
        .task(id: items.map(\.id)) {
            for item in items where previews[item.id] == nil {
                previews[item.id] = await PhotoLibrary.image(for: item.asset, side: 200, allowNetwork: false)
            }
        }
    }
}

/// 공유 버튼. 썸네일을 불러오면 공유 시트 위쪽 미리보기에 함께 보여줍니다.
struct AssetShareLink: View {
    let item: ResultItem
    @State private var preview: PlatformImage?

    private var title: String { item.hit.kind == .video ? "동영상" : "사진" }

    var body: some View {
        Group {
            if let preview {
                ShareLink(item: SharedAsset(asset: item.asset), preview: SharePreview(title, image: Image(platformImage: preview)))
            } else {
                ShareLink(item: SharedAsset(asset: item.asset), preview: SharePreview(title))
            }
        }
        .accessibilityIdentifier("share-button")
        .task(id: item.id) {
            preview = await PhotoLibrary.image(for: item.asset, side: 200, allowNetwork: false)
        }
    }
}

/// 결과 썸네일을 길게 눌렀을 때 보이는 메뉴.
struct AssetContextMenu: View {
    let item: ResultItem
    /// 있으면 이 항목을 고른 채로 여러 개 선택을 시작하는 메뉴를 보여줍니다.
    var onSelect: (() -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let onSelect {
            Button("선택", systemImage: "checkmark.circle", action: onSelect)
        }
        AssetShareLink(item: item)
        FavoriteButton(item: item)
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive) {
            Task { await model.delete([item]) }
        }
    }
}

struct FavoriteButton: View {
    let item: ResultItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let isFavorite = item.asset.isFavorite
        Button {
            Task { await model.setFavorite(!isFavorite, for: item) }
        } label: {
            Label(isFavorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: isFavorite ? "heart.fill" : "heart")
        }
        .accessibilityIdentifier("favorite-button")
    }
}
