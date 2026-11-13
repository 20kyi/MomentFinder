import SwiftUI

/// 검색어가 없을 때 보이는 첫 화면. 분석 중일 때만 진행 상태를 한 줄로 보여주고, 인물과 예시 검색어 아래에 보관함 전체를 사진 앱처럼 늘어놓습니다.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let onShowStatus: () -> Void
    let onSearch: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let stage = IndexStage(model: model) {
                    IndexStatusBanner(stage: stage, action: onShowStatus)
                        .padding(.horizontal)
                }
                if !model.groups.isEmpty {
                    PeopleStrip()
                }
                SuggestionSection(onSearch: onSearch)
                    .padding(.horizontal)
                if model.isEngineReady, !model.isIndexing || model.progress.isQuickPassComplete {
                    Text("사진·동영상 \(model.indexedAssetCount)개 검색 가능")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                if !model.libraryItems.isEmpty {
                    LibraryGrid()
                }
            }
            .padding(.vertical)
        }
        .animation(.default, value: IndexStage(model: model) == nil)
        .animation(.default, value: model.groups.isEmpty)
    }
}

/// 검색이나 필터 없이 보관함 전체를 최신순으로 보여주는 갤러리.
/// 분석 진행률이 바뀔 때마다 홈 화면이 다시 그려지므로, 수만 개의 썸네일을 다시 계산하지 않도록 인자 없는 뷰로 둡니다.
private struct LibraryGrid: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ResultItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("모든 사진")
                    .font(.headline)
                Spacer()
                Text("\(model.libraryItems.count)개")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(model.libraryDays) { day in
                    Section {
                        ForEach(day.items) { item in
                            Button { selection = item } label: {
                                AssetThumbnail(item: item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { AssetContextMenu(item: item) }
                            .accessibilityIdentifier("library-item")
                        }
                    } header: {
                        Text(Self.title(for: day.date))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("library-day-header")
                    }
                }
            }
        }
        .navigationDestination(item: $selection) { AssetDetailView(item: $0, in: neighbors(of: $0)) }
    }

    /// 사진 앱처럼 최근 이틀은 오늘·어제로, 올해는 요일까지, 그 전은 연도까지 적습니다.
    private static func title(for date: Date?) -> String {
        guard let date else { return "날짜 없음" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "오늘" }
        if calendar.isDateInYesterday(date) { return "어제" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month().day().weekday(.wide))
        }
        return date.formatted(.dateTime.year().month().day())
    }

    /// 상세 화면은 넘겨받은 목록 전체를 보관함이 바뀔 때마다 다시 가져오므로, 누른 항목 주변만 넘깁니다.
    private func neighbors(of item: ResultItem) -> [ResultItem] {
        let items = model.libraryItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return [item] }
        return Array(items[max(0, index - 300)..<min(items.count, index + 301)])
    }
}

/// 홈에 보여줄 분석 단계. 분석 중이 아니면 nil 이라 배너를 숨깁니다.
private enum IndexStage: Equatable {
    case loadingEngine
    case photos(done: Int, total: Int)
    case subjects(done: Int, total: Int)
    case videoScenes(done: Int, total: Int)
    case checkingLibrary

    @MainActor
    init?(model: AppModel) {
        let progress = model.progress
        if !model.isEngineReady {
            self = .loadingEngine
        } else if !model.isIndexing {
            return nil
        } else if !progress.isQuickPassComplete {
            self = .photos(done: progress.indexed, total: progress.total)
        } else if progress.remainingSubjects > 0 {
            self = .subjects(done: progress.subjectsDone, total: progress.subjectTotal)
        } else if progress.remainingVideoScenes > 0 {
            self = .videoScenes(done: progress.videoScenesDone, total: progress.videoTotal)
        } else {
            self = .checkingLibrary
        }
    }

    var title: String {
        switch self {
        case .loadingEngine: "검색 모델을 불러오는 중…"
        case let .photos(done, total): "사진 분석 중 \(done) / \(total)"
        case let .subjects(done, total): "인물·반려동물 분석 중 \(done) / \(total)"
        case let .videoScenes(done, total): "동영상 장면 분석 중 \(done) / \(total)"
        case .checkingLibrary: "보관함 확인 중…"
        }
    }

    var caption: String? {
        switch self {
        case .photos: "분석이 끝난 사진부터 바로 검색할 수 있어요."
        case .videoScenes: "끝나면 \"하품\" 같은 순간까지 찾아요."
        default: nil
        }
    }

    var systemImage: String {
        switch self {
        case .loadingEngine: "cpu"
        case .photos, .checkingLibrary: "sparkles"
        case .subjects: "person.crop.rectangle.stack"
        case .videoScenes: "film"
        }
    }

    var fraction: Double? {
        switch self {
        case let .photos(done, total), let .subjects(done, total), let .videoScenes(done, total):
            total == 0 ? nil : Double(done) / Double(total)
        case .loadingEngine, .checkingLibrary:
            nil
        }
    }
}

private struct IndexStatusBanner: View {
    let stage: IndexStage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(stage.title, systemImage: stage.systemImage)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let fraction = stage.fraction {
                    ProgressView(value: fraction)
                }
                if let caption = stage.caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("index-status-banner")
    }
}

/// 이름 붙은 그룹부터 원형 아바타로 늘어놓습니다. 전체 목록은 "모두 보기"로 엽니다.
private struct PeopleStrip: View {
    @Environment(AppModel.self) private var model

    private var groups: [SubjectGroup] {
        model.groups.filter { $0.name != nil } + model.groups.filter { $0.name == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("인물·반려동물")
                    .font(.headline)
                Spacer()
                NavigationLink("모두 보기") { PeopleView() }
                    .font(.subheadline)
                    .accessibilityIdentifier("people-button")
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(groups) { group in
                        NavigationLink {
                            PersonDetailView(clusterID: group.id)
                        } label: {
                            VStack(spacing: 6) {
                                SubjectThumbnail(subject: group.cover, size: 60)
                                Text(group.name ?? "이름 없음")
                                    .font(.caption.weight(group.name == nil ? .regular : .medium))
                                    .foregroundStyle(group.name == nil ? .secondary : .primary)
                                    .lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-subject")
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct SuggestionSection: View {
    @Environment(AppModel.self) private var model
    let onSearch: (String) -> Void

    private static let examples = ["고양이 하품", "고양이가 하품하는 동영상", "바닷가 일몰", "생일 케이크 촛불", "눈 오는 거리"]

    private var suggestions: [String] {
        guard let name = model.subjectNames.first else { return Self.examples }
        return ["\(name) 웃는 사진"] + Self.examples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이렇게 검색해 보세요")
                .font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { onSearch(suggestion) } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("suggestion-chip")
                }
            }
        }
    }
}

/// 자리가 모자라면 다음 줄로 넘기며 왼쪽부터 채웁니다.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
