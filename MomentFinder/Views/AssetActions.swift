import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 공유 시트에 넘기는 사진·동영상. 받는 쪽이 요청할 때 원본을 내려받아 파일로 건넵니다.
struct SharedAsset: Transferable {
    let asset: PHAsset

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { try await SentTransferredFile(PhotoLibrary.exportOriginal(of: $0.asset)) }
            .exportingCondition { $0.asset.mediaType == .video }
        FileRepresentation(exportedContentType: .image) { try await SentTransferredFile(PhotoLibrary.exportOriginal(of: $0.asset)) }
            .exportingCondition { $0.asset.mediaType == .image }
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
    @Environment(AppModel.self) private var model

    var body: some View {
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
