import SwiftUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: ResultItem?
    @State private var showsIndexStatus = false
    @State private var showsPeople = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private static let examples = ["고양이 하품", "고양이가 하품하는 동영상", "바닷가 일몰", "생일 케이크 촛불", "눈 오는 거리"]

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !model.subjectNames.isEmpty {
                        SubjectChipsBar()
                    }
                }
                .navigationTitle("Moment Finder")
                .searchable(text: $query, prompt: "예: 고양이 하품")
                .searchScopes($model.scope) {
                    ForEach(MediaScope.allCases) { Text($0.title).tag($0) }
                }
                .onSubmit(of: .search) { runSearch() }
                .onChange(of: model.scope) { if !query.isEmpty || !model.selectedNames.isEmpty { runSearch() } }
                .onChange(of: model.selectedNames) { runSearch() }
                .onChange(of: query) { if query.isEmpty { runSearch() } }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { showsPeople = true } label: {
                            Label("인물·반려동물", systemImage: "person.2")
                        }
                        .accessibilityIdentifier("people-button")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsIndexStatus = true } label: { IndexStatusBadge() }
                    }
                }
                .sheet(isPresented: $showsIndexStatus) { IndexStatusView() }
                .navigationDestination(item: $selection) { AssetDetailView(item: $0, in: model.results) }
                .navigationDestination(isPresented: $showsPeople) { PeopleView() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isSearching && model.results.isEmpty {
            ProgressView("검색 중…")
        } else if model.results.isEmpty {
            if let interpreted = model.interpretedQuery {
                noMatchView(interpreted)
            } else {
                examplesView
            }
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let interpreted = model.interpretedQuery {
                    Text("“\(interpreted)” 로 검색한 결과")
                }
                if model.isIndexing && !model.progress.isQuickPassComplete {
                    Label("분석하는 대로 결과가 추가돼요 · \(model.progress.indexed) / \(model.progress.total)", systemImage: "sparkles")
                } else if model.isIndexing && model.progress.remainingVideoScenes > 0 {
                    Label("동영상 장면을 분석하는 대로 결과가 정확해져요 · \(model.progress.videoScenesDone) / \(model.progress.videoTotal)", systemImage: "film")
                }
                if model.showsWeakMatches {
                    Label("관련도가 낮은 사진도 함께 보여주고 있어요", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(model.results) { item in
                    Button { selection = item } label: { AssetThumbnail(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(item.hit.kind == .video ? "result-video" : "result-photo")
                }
            }
            .animation(.default, value: model.results.map(\.id))

            if model.isRankedSearch && !model.showsWeakMatches {
                Button("관련도가 낮은 사진도 보기") {
                    Task { await model.showWeakMatches() }
                }
                .font(.footnote)
                .padding(.vertical, 20)
            }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 24
        } action: { _, scrolledAway in
            model.holdsResults = scrolledAway
        }
        .overlay(alignment: .top) {
            if model.pendingResults != nil {
                newResultsButton
            }
        }
        .animation(.default, value: model.pendingResults == nil)
    }

    private func noMatchView(_ interpreted: String) -> some View {
        ContentUnavailableView {
            Label("딱 맞는 사진이 없어요", systemImage: "magnifyingglass")
        } description: {
            if !model.isRankedSearch {
                Text("“\(interpreted)” 가 함께 나온 사진이 없어요.")
            } else if model.isIndexing {
                Text("“\(interpreted)” 와 충분히 비슷한 사진을 아직 찾지 못했어요. 분석이 진행되면 결과가 나타날 수 있어요.")
            } else {
                Text("“\(interpreted)” 와 충분히 비슷한 사진을 찾지 못했어요.")
            }
        } actions: {
            if model.isRankedSearch && !model.showsWeakMatches {
                Button("비슷한 사진 보기") {
                    Task { await model.showWeakMatches() }
                }
            }
        }
    }

    private var newResultsButton: some View {
        let count = model.newPendingResultCount
        return Button {
            model.applyPendingResults()
            withAnimation { scrollPosition.scrollTo(edge: .top) }
        } label: {
            Label(count > 0 ? "새 결과 \(count)개 보기" : "결과 순서 업데이트", systemImage: "arrow.up")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .shadow(radius: 4, y: 2)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("new-results-button")
    }

    private var examplesView: some View {
        List {
            Section {
                IndexSummaryRow()
            }
            Section {
                NavigationLink {
                    PeopleView()
                } label: {
                    LabeledContent {
                        if !model.groups.isEmpty { Text("\(model.groups.count)") }
                    } label: {
                        Label("인물·반려동물", systemImage: "person.2")
                    }
                }
            } footer: {
                Text(model.subjectNames.isEmpty
                     ? "이름을 붙이면 \"초코 산책하는 동영상\"처럼 이름으로 검색할 수 있어요."
                     : "\"\(model.subjectNames[0]) 웃는 사진\"처럼 이름을 넣어 검색해 보세요.")
            }
            Section("이렇게 검색해 보세요") {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        query = example
                        runSearch()
                    } label: {
                        Label(example, systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }

    private func runSearch() {
        let text = query
        scrollPosition.scrollTo(edge: .top)
        Task { await model.search(text) }
    }
}

/// 이름 붙은 인물·반려동물 칩. 여러 개를 고르면 모두 나오는 사진만 보여줍니다.
private struct SubjectChipsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.subjectNames, id: \.self) { name in
                    let selected = model.selectedNames.contains(name)
                    Button {
                        if selected { model.selectedNames.remove(name) } else { model.selectedNames.insert(name) }
                    } label: {
                        HStack(spacing: 6) {
                            SubjectThumbnail(subject: model.groups.first { $0.name == name }?.cover, size: 24)
                            Text(name).font(.subheadline.weight(.medium))
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("subject-filter-chip")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct VideoSceneProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "동영상 장면 분석\(model.isIndexing ? " 중" : "") \(model.progress.videoScenesDone) / \(model.progress.videoTotal)",
                systemImage: "film"
            )
            ProgressView(value: model.progress.sceneFraction)
            Text(Self.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    #if os(iOS)
    private static let footnote = "동영상은 지금도 검색되고, 장면 분석이 끝나면 \"하품\" 같은 순간까지 찾아요. 충전 중이고 네트워크에 연결되어 있으면 백그라운드에서 이어서 분석해요."
    #else
    private static let footnote = "동영상은 지금도 검색되고, 장면 분석이 끝나면 \"하품\" 같은 순간까지 찾아요."
    #endif
}

private struct IndexSummaryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isEngineReady {
                Label("검색 모델을 불러오는 중…", systemImage: "cpu")
            } else if model.isIndexing && !model.progress.isQuickPassComplete {
                Label("사진 분석 중 \(model.progress.indexed) / \(model.progress.total)", systemImage: "sparkles")
                ProgressView(value: model.progress.fraction)
                Text("분석이 끝난 사진부터 바로 검색할 수 있어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("사진·동영상 \(model.indexedAssetCount)개 검색 가능", systemImage: "checkmark.circle")
                if model.progress.remainingSubjects > 0 {
                    Label(
                        "인물·반려동물 분석\(model.isIndexing ? " 중" : "") \(model.progress.subjectsDone) / \(model.progress.subjectTotal)",
                        systemImage: "person.crop.rectangle.stack"
                    )
                    ProgressView(value: model.progress.subjectFraction)
                }
                if model.progress.remainingVideoScenes > 0 {
                    VideoSceneProgressView()
                }
            }
        }
    }
}
