import AVKit
import Photos
import SwiftUI

/// 결과 하나를 크게 보여주고, 좌우로 넘기거나 아래 썸네일을 눌러 같은 결과 목록의 다른 항목으로 이동합니다.
struct AssetDetailView: View {
    /// 화면을 연 시점의 결과 목록. 보는 도중 분석으로 결과가 바뀌어도 순서가 흔들리지 않도록 고정합니다.
    @State private var items: [ResultItem]
    @State private var currentID: String?
    @State private var width: CGFloat = 0
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(item: ResultItem, in items: [ResultItem] = []) {
        _items = State(initialValue: items.contains { $0.id == item.id } ? items : [item])
        _currentID = State(initialValue: item.id)
    }

    private var item: ResultItem {
        items.first { $0.id == currentID } ?? items[0]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        page(item)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .scrollDisabled(items.count < 2)
            // scrollPosition 의 처음 값만으로는 첫 페이지에 머물러서, 너비가 정해지거나 바뀔 때마다 선택된 결과로 맞춥니다.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: width) {
                if let currentID { proxy.scrollTo(currentID) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SubjectsInAssetRow(assetID: item.id)
                if items.count > 1 {
                    ResultStrip(items: items, currentID: $currentID)
                }
            }
            .background(.bar)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let score = item.hit.score {
                ToolbarItem(placement: .primaryAction) {
                    Text("일치도 \(score, format: .number.precision(.fractionLength(3)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: Self.actionsPlacement) {
                AssetShareLink(item: item)
                #if os(iOS)
                Spacer()
                #endif
                FavoriteButton(item: item)
                #if os(iOS)
                Spacer()
                #endif
                Button("삭제", systemImage: "trash", role: .destructive) {
                    Task { await model.delete([item]) }
                }
                .accessibilityIdentifier("delete-button")
            }
        }
        .onChange(of: model.libraryRevision) { refetchItems() }
    }

    #if os(iOS)
    private static let actionsPlacement = ToolbarItemPlacement.bottomBar
    #else
    private static let actionsPlacement = ToolbarItemPlacement.primaryAction
    #endif

    /// 즐겨찾기 변경을 반영하고, 지워진 항목은 빼고 바로 다음(마지막이었다면 이전) 결과로 넘어갑니다. 남은 게 없으면 닫습니다.
    private func refetchItems() {
        let refetched = ResultItem.refetched(items)
        guard refetched != items else { return }
        guard !refetched.isEmpty else {
            dismiss()
            return
        }
        let remaining = Set(refetched.map(\.id))
        if let currentID, !remaining.contains(currentID), let index = items.firstIndex(where: { $0.id == currentID }) {
            self.currentID = items[index...].first { remaining.contains($0.id) }?.id
                ?? items[..<index].last { remaining.contains($0.id) }?.id
        }
        items = refetched
    }

    @ViewBuilder
    private func page(_ item: ResultItem) -> some View {
        let isActive = item.id == currentID
        Group {
            if item.hit.kind == .video {
                VideoMomentView(asset: item.asset, momentTime: item.hit.time, isActive: isActive)
            } else {
                PhotoDetailView(asset: item.asset)
            }
        }
        .accessibilityHidden(!isActive)
    }

    private var title: String {
        guard let date = item.asset.creationDate else { return "" }
        let day = Self.dayFormatter.string(from: date)
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) \(time)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

/// 같은 검색 결과를 작은 썸네일로 늘어놓은 줄. 선택된 결과는 항상 가운데에 고정되고,
/// 직접 넘기면 가운데에 닿은 결과로 한 칸씩 넘어갑니다.
private struct ResultStrip: View {
    let items: [ResultItem]
    @Binding var currentID: String?
    @State private var width: CGFloat = 0
    @State private var isUserScrolling = false
    /// 줄 가운데가 첫 칸 가운데에서 얼마나 떨어져 있는지. 스크롤한 만큼 썸네일을 되돌려 선택 항목을 가운데에 묶어 둡니다.
    @State private var scrollX: CGFloat = 0

    /// 가운데 항목을 위치로 계산하므로 모든 칸의 너비가 같아야 합니다.
    /// 선택된 썸네일은 칸보다 넓게 그리고, 양옆은 offset 으로만 밀어내 배치는 그대로 둡니다.
    private static let cellWidth: CGFloat = 36
    private static let spacing: CGFloat = 2
    private static let step = cellWidth + spacing
    private static let height: CGFloat = 52

    var body: some View {
        let selectedIndex = items.firstIndex { $0.id == currentID }
        let push = selectedIndex.map { (selectedWidth(items[$0]) - Self.cellWidth) / 2 + 3 } ?? 0
        let pin = selectedIndex.map { scrollX - CGFloat($0) * Self.step } ?? 0

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        cell(item)
                            .offset(x: pin + (selectedIndex.map { index < $0 ? -push : index > $0 ? push : 0 } ?? 0))
                    }
                }
                .animation(.snappy(duration: 0.2), value: currentID)
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentMargins(.horizontal, max(0, (width - Self.cellWidth) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.midX - Self.cellWidth / 2
            } action: { _, x in
                scrollX = x
                guard isUserScrolling, !items.isEmpty else { return }
                let index = min(max(Int((x / Self.step).rounded()), 0), items.count - 1)
                if items[index].id != currentID { currentID = items[index].id }
            }
            .onChange(of: width) { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) {
                guard !isUserScrolling else { return }
                withAnimation { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: currentID) { _, _ in isUserScrolling }
    }

    private func cell(_ item: ResultItem) -> some View {
        let selected = item.id == currentID
        return Button {
            withAnimation { currentID = item.id }
        } label: {
            AssetThumbnail(item: item, compact: true)
                .frame(width: selected ? selectedWidth(item) : Self.cellWidth, height: selected ? Self.height : Self.height - 6)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .opacity(selected ? 1 : 0.7)
                .frame(width: Self.cellWidth, height: Self.height)
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityIdentifier("detail-strip-item")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 선택된 썸네일은 잘리지 않도록 원본 비율대로 넓힙니다. 아주 긴 파노라마는 적당히 자릅니다.
    private func selectedWidth(_ item: ResultItem) -> CGFloat {
        let asset = item.asset
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return Self.cellWidth }
        let ratio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        return min(max(Self.height * ratio, Self.cellWidth), Self.height * 2)
    }
}

/// 사진 속에서 찾은 인물·반려동물. 이름 있는 그룹은 눌러서 모아 보고, 이름이 없거나 잘못된 경우 이름을 붙입니다.
private struct SubjectsInAssetRow: View {
    let assetID: String
    @Environment(AppModel.self) private var model
    @State private var entries: [(subject: StoredSubject, name: String?)] = []
    @State private var naming: StoredSubject?
    @State private var openedGroup: Int64?

    var body: some View {
        Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("이 사진 속 인물")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(entries, id: \.subject.id) { entry in
                                chip(entry.subject, name: entry.name)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .task(id: assetID) { await reload() }
        .onChange(of: model.groups) { Task { await reload() } }
        .sheet(item: $naming) { subject in
            NameSubjectSheet(subject: subject, currentName: entries.first { $0.subject.id == subject.id }?.name)
        }
        .navigationDestination(item: $openedGroup) { PersonDetailView(clusterID: $0) }
    }

    private func reload() async {
        let found = await model.subjects(inAsset: assetID)
        guard !Task.isCancelled else { return }
        entries = found
    }

    private func chip(_ subject: StoredSubject, name: String?) -> some View {
        Button {
            if name != nil, let clusterID = subject.clusterID {
                openedGroup = clusterID
            } else {
                naming = subject
            }
        } label: {
            VStack(spacing: 4) {
                SubjectThumbnail(subject: subject, size: 44)
                Text(name ?? "이름 없음")
                    .font(.caption2)
                    .foregroundStyle(name == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("이름 바꾸기", systemImage: "pencil") { naming = subject }
        }
        .accessibilityIdentifier("subject-chip")
    }
}

private struct NameSubjectSheet: View {
    let subject: StoredSubject
    let currentName: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var suggestions: [String] {
        Array(Set(model.groups.filter { $0.species == subject.species }.compactMap(\.name))).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        SubjectThumbnail(subject: subject, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("이름", text: $name)
                        .submitLabel(.done)
                        .onSubmit { save(name) }
                } footer: {
                    Text(currentName == nil
                         ? "이 그룹의 모든 사진에 이름이 붙어요. 이미 있는 이름이면 한 그룹으로 합쳐져요."
                         : "이 사진만 다른 이름의 그룹으로 옮겨요.")
                }
                if !suggestions.isEmpty {
                    Section("이미 있는 이름") {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { save(suggestion) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(subject.species == .person ? "누구예요?" : "이름이 뭐예요?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = currentName ?? "" }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else { dismiss(); return }
        Task {
            await model.nameSubject(subject.id, as: trimmed)
            dismiss()
        }
    }
}

private struct PhotoDetailView: View {
    let asset: PHAsset
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            image = await PhotoLibrary.image(for: asset, side: 2048, allowNetwork: true)
        }
    }
}

/// 검색어와 가장 잘 맞는 장면 1초 전부터 재생합니다.
private struct VideoMomentView: View {
    let asset: PHAsset
    let momentTime: Double
    /// 지금 화면에 보이는 페이지인지. 옆 페이지로 미리 불러온 동영상은 재생하지 않습니다.
    let isActive: Bool
    @State private var player: AVPlayer?
    @State private var playsWhenReady = false

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("동영상 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button {
                    seek(to: momentTime)
                } label: {
                    Label("찾은 장면 \(TimeFormatter.string(momentTime))", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("moment-button")
                Button {
                    seek(to: 0)
                } label: {
                    Label("처음부터", systemImage: "backward.end")
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom)
        }
        .task(id: asset.localIdentifier) {
            guard let item = await PhotoLibrary.playerItem(for: asset) else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            seek(to: momentTime, play: playsWhenReady)
        }
        .onChange(of: isActive, initial: true) {
            playsWhenReady = isActive
            if isActive { seek(to: momentTime) } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func seek(to time: Double, play: Bool = true) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, time - 1), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            if play { player.play() }
        }
    }
}
