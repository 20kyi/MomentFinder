import Photos
import SwiftUI

/// 한 그룹의 사진들. 이름을 붙이거나, 잘못 묶인 사진을 골라 그룹에서 뺄 수 있습니다.
struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var clusterID: Int64
    @State private var name = ""
    @State private var items: [ResultItem] = []
    @State private var subjectsByAsset: [String: [Int64]] = [:]
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var opened: ResultItem?
    @FocusState private var nameFocused: Bool

    init(clusterID: Int64) {
        _clusterID = State(initialValue: clusterID)
    }

    private var group: SubjectGroup? { model.group(id: clusterID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                    ForEach(items) { item in
                        Button { tap(item) } label: {
                            AssetThumbnail(item: item)
                                .overlay(alignment: .topTrailing) {
                                    if isSelecting {
                                        Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, selection.contains(item.id) ? Color.accentColor : .black.opacity(0.3))
                                            .padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !isSelecting { AssetContextMenu(item: item) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if group == nil {
                ContentUnavailableView("이 그룹이 더 이상 없어요", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .navigationTitle(group?.name ?? "이름 없음")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? "완료" : "선택") {
                    isSelecting.toggle()
                    selection = []
                }
                .disabled(items.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selection.isEmpty, let group {
                Button(role: .destructive) {
                    Task { await rejectSelection() }
                } label: {
                    Label("\(group.species.notThisOne) (\(selection.count))", systemImage: "person.crop.circle.badge.xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding()
                .background(.bar)
            }
        }
        .navigationDestination(item: $opened) { AssetDetailView(item: $0, in: items) }
        .task(id: group) { await reload() }
        .onChange(of: model.libraryRevision) { Task { await reload() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SubjectThumbnail(subject: group?.cover, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                TextField("이름 붙이기", text: $name)
                    .font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await saveName() } }
                    .accessibilityIdentifier("subject-name-field")
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var caption: String {
        guard let group else { return "" }
        let count = "사진 \(group.assetCount)장"
        return group.name == nil ? "\(count) · 같은 이름을 붙이면 한 그룹으로 합쳐져요" : count
    }

    private func tap(_ item: ResultItem) {
        if isSelecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            opened = item
        }
    }

    private func saveName() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (group?.name ?? "") else { return }
        clusterID = await model.renameGroup(clusterID, to: trimmed)
    }

    private func rejectSelection() async {
        let ids = selection.flatMap { subjectsByAsset[$0] ?? [] }
        selection = []
        isSelecting = false
        await model.reject(subjects: ids, from: clusterID)
    }

    private func reload() async {
        if !nameFocused { name = group?.name ?? "" }
        let members = await model.members(of: clusterID)
        subjectsByAsset = Dictionary(grouping: members, by: \.assetID).mapValues { $0.map(\.id) }
        let assets = PhotoLibrary.assets(withIDs: Array(subjectsByAsset.keys))
        items = assets.values
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .map { asset in
                let kind: MediaKind = asset.mediaType == .video ? .video : .photo
                return ResultItem(hit: SearchHit(assetID: asset.localIdentifier, kind: kind, score: nil, time: 0), asset: asset)
            }
    }
}
