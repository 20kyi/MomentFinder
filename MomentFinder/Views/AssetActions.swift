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
/// iOS 에서는 원본을 모두 파일로 내려받은 뒤 공유 시트를 엽니다. 받는 앱이 원본을 늦게 요청하게 두면
/// 편집 앱의 공유 확장이 여러 동영상을 기다리다 흰 화면에 멈춥니다.
struct MultiAssetShareLink: View {
    let items: [ResultItem]
    #if os(iOS)
    @Environment(AppModel.self) private var model
    @State private var preparation: Task<Void, Never>?
    @State private var preparedCount = 0
    @State private var sharedFiles: [URL]?

    var body: some View {
        Button(action: prepare) {
            if preparation != nil {
                Label("준비 중 \(preparedCount)/\(items.count)", systemImage: "arrow.down.circle")
            } else {
                Label("공유", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(items.isEmpty || preparation != nil)
        .accessibilityIdentifier("share-selection-button")
        .background(ActivitySheet(items: $sharedFiles))
        .onDisappear { preparation?.cancel() }
    }

    private func prepare() {
        let assets = items.map(\.asset)
        let session = UUID()
        preparedCount = 0
        preparation = Task {
            defer { preparation = nil }
            var files: [URL] = []
            do {
                for asset in assets {
                    try Task.checkCancellation()
                    files.append(try await PhotoLibrary.exportOriginal(of: asset, session: session))
                    preparedCount = files.count
                }
                try Task.checkCancellation()
                sharedFiles = files
            } catch is CancellationError {
            } catch {
                model.errorMessage = "공유할 원본을 준비하지 못했어요. \(error.localizedDescription)"
            }
        }
    }
    #else
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
    #endif
}

#if os(iOS)
/// items 가 채워지면 공유 시트를 띄우고, 닫히면 items 를 비웁니다. iPad 에서는 이 자리를 가리키는 팝오버로 뜹니다.
private struct ActivitySheet: UIViewControllerRepresentable {
    @Binding var items: [URL]?

    final class Coordinator {
        var presented: UIActivityViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard let items, context.coordinator.presented == nil else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPhone 에서 위치를 주면 닫기 버튼 없는 작은 카드로 떠서, 한 장 공유(ShareLink)와 모양을 맞추려고 iPad 에만 줍니다.
        if host.traitCollection.userInterfaceIdiom == .pad {
            controller.popoverPresentationController?.sourceView = host.view
        }
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.presented = nil
            self.items = nil
        }
        // 검색창이 열려 있으면 검색 화면이 이미 떠 있으므로 그 위에서 띄웁니다.
        var presenter = host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        context.coordinator.presented = controller
        presenter.present(controller, animated: true)
    }
}
#endif

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
