import SwiftUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: ResultItem?
    @State private var showsIndexStatus = false
    @State private var isSearchPresented = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// 종류 탭과 이름 칩은 검색 결과를 거르는 필터라서 검색 중일 때만 보여줍니다.
    /// 시스템 searchScopes 는 검색창이 활성일 때만 보여서, 추천 검색어로 검색하거나 상세 화면에서 돌아오면 사라집니다.
    private var showsFilters: Bool {
        isSearchPresented || !query.isEmpty || !model.selectedNames.isEmpty
    }

    var body: some View {
        NavigationStack {
            content
                .topBar {
                    if showsFilters {
                        SearchFilterBar()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.default, value: showsFilters)
                .navigationTitle("Moment Finder")
                #if os(iOS)
                .toolbarTitleDisplayMode(showsFilters ? .inline : .inlineLarge)
                #endif
                .searchable(text: $query, isPresented: $isSearchPresented, prompt: "예: 고양이 하품")
                .onSubmit(of: .search) { runSearch() }
                .onChange(of: model.scope) { if !query.isEmpty || !model.selectedNames.isEmpty { runSearch() } }
                .onChange(of: model.selectedNames) { runSearch() }
                .onChange(of: query) { if query.isEmpty { runSearch() } }
                .toolbar {
                    if showsFilters {
                        ToolbarItem(placement: .navigation) {
                            Button(action: returnHome) {
                                Label("홈으로", systemImage: "chevron.backward")
                            }
                            .accessibilityIdentifier("search-back-button")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsIndexStatus = true } label: { IndexStatusBadge() }
                    }
                }
                .sheet(isPresented: $showsIndexStatus) { IndexStatusView() }
                .navigationDestination(item: $selection) { AssetDetailView(item: $0, in: model.results) }
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
                HomeView(onShowStatus: { showsIndexStatus = true }) { example in
                    query = example
                    runSearch()
                }
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

    /// 검색어와 필터를 모두 지워 홈 화면으로 돌아갑니다.
    private func returnHome() {
        withAnimation {
            isSearchPresented = false
            query = ""
            model.selectedNames = []
            model.scope = .all
        }
    }

    private func runSearch() {
        let text = query
        scrollPosition.scrollTo(edge: .top)
        Task { await model.search(text) }
    }
}

/// 검색 결과 위에 붙는 필터 바. 전체/사진/동영상 탭과 이름 칩을 함께 보여줍니다.
private struct SearchFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Picker("종류", selection: $model.scope) {
                ForEach(MediaScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 6)
            .accessibilityIdentifier("scope-picker")

            if !model.subjectNames.isEmpty {
                SubjectChipsBar()
            }
        }
    }
}

private extension View {
    /// iOS 26 부터는 스크롤 가장자리 흐림 효과와 어울리도록 배경 없는 safeAreaBar 를 씁니다.
    @ViewBuilder
    func topBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { content().background(.bar) }
        }
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
    }
}
