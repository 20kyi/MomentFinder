import Foundation
import Observation
import Photos
#if canImport(UIKit)
import UIKit
#endif

struct ResultItem: Identifiable, Hashable {
    let hit: SearchHit
    let asset: PHAsset

    var id: String { hit.assetID }

    /// 검색어로 찾은 장면이 있는지. 보관함에서 바로 고르거나 이름만으로 고른 동영상은 처음부터 보여줍니다.
    var hasMoment: Bool { hit.score != nil }

    /// PHAsset 은 가져온 시점의 값이라, 즐겨찾기가 바뀌면 새로 가져온 에셋과 다르게 비교되어야 화면이 갱신됩니다.
    static func == (lhs: ResultItem, rhs: ResultItem) -> Bool {
        lhs.hit == rhs.hit && lhs.asset.isFavorite == rhs.asset.isFavorite
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hit)
    }

    /// 보관함에서 에셋을 다시 가져옵니다. 삭제된 항목은 빠집니다.
    static func refetched(_ items: [ResultItem]) -> [ResultItem] {
        guard !items.isEmpty else { return items }
        let assets = PhotoLibrary.assets(withIDs: items.map(\.id))
        return items.compactMap { item in assets[item.id].map { ResultItem(hit: item.hit, asset: $0) } }
    }
}

extension ResultItem {
    /// 검색 없이 보관함에서 바로 고른 항목. 순위와 장면이 없습니다.
    init(asset: PHAsset) {
        let kind: MediaKind = asset.mediaType == .video ? .video : .photo
        self.init(hit: SearchHit(assetID: asset.localIdentifier, kind: kind, score: nil, time: 0), asset: asset)
    }
}

/// 홈 갤러리에서 같은 날 찍은 사진·동영상 묶음.
struct LibraryDay: Identifiable {
    /// 그날 0시. 촬영일이 없는 항목끼리 묶으면 nil 입니다.
    let date: Date?
    var items: [ResultItem]

    var id: String { items[0].id }

    /// 최신순 목록을 순서를 지키며 촬영일별로 묶습니다.
    static func grouping(_ items: [ResultItem], calendar: Calendar = .current) -> [LibraryDay] {
        var days: [LibraryDay] = []
        for item in items {
            let date = item.asset.creationDate.map(calendar.startOfDay(for:))
            if let last = days.last, last.date == date {
                days[days.count - 1].items.append(item)
            } else {
                days.append(LibraryDay(date: date, items: [item]))
            }
        }
        return days
    }
}

enum MediaScope: String, CaseIterable, Identifiable {
    case all, photos, videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "전체"
        case .photos: "사진"
        case .videos: "동영상"
        }
    }

    var kind: MediaKind? {
        switch self {
        case .all: nil
        case .photos: .photo
        case .videos: .video
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var authorization = PhotoLibrary.authorizationStatus
    private(set) var isEngineReady = false
    private(set) var isIndexing = false
    private(set) var progress = IndexProgress()
    private(set) var indexedAssetCount = 0

    /// 홈 화면 갤러리에 보여줄 보관함 전체. 검색어·필터와 상관없이 최신순입니다.
    private(set) var libraryItems: [ResultItem] = []
    /// libraryItems 를 촬영일별로 나눈 것. 갤러리를 날짜 구분으로 그릴 때 씁니다.
    private(set) var libraryDays: [LibraryDay] = []
    private(set) var results: [ResultItem] = []
    /// 사용자가 결과를 스크롤해 보는 중에 분석으로 새로 생긴 결과. 화면이 갑자기 바뀌지 않도록 따로 보관합니다.
    private(set) var pendingResults: [ResultItem]?
    private(set) var isSearching = false
    /// 최소 점수에 못 미치는 결과까지 보여주는 중인지. 새 검색을 하면 다시 꺼집니다.
    private(set) var showsWeakMatches = false
    /// 결과 화면이 맨 위가 아니면 true. 이때는 새 결과를 바로 반영하지 않고 pendingResults 에 모읍니다.
    var holdsResults = false {
        didSet { if !holdsResults { applyPendingResults() } }
    }
    /// 실제로 모델에 들어간 영어 검색어. 검색 품질을 확인하는 용도로 화면에 보여줍니다.
    private(set) var interpretedQuery: String?
    /// 결과가 유사도 순인지. 이름만으로 검색하면 최신순이라 일치도와 "관련도 낮은 사진" 버튼을 숨깁니다.
    private(set) var isRankedSearch = true
    var scope: MediaScope = .all
    var errorMessage: String?

    /// 인물 화면에 보여줄 그룹. 분석이 진행되면 주기적으로 갱신됩니다.
    private(set) var groups: [SubjectGroup] = []
    /// 사용자가 붙인 이름 목록. 검색 칩과 검색어 속 이름 인식에 씁니다.
    private(set) var subjectNames: [String] = []
    /// 검색 칩에서 고른 이름. 검색어와 함께 적용됩니다.
    var selectedNames: Set<String> = []
    private(set) var recognizesFaces = false
    /// 보관함이 바뀔 때마다(삭제, 즐겨찾기, 다른 앱에서의 편집) 늘어납니다. 결과를 따로 들고 있는 화면이 다시 불러오는 신호입니다.
    private(set) var libraryRevision = 0

    let settings = IndexSettings()
    let translator = QueryTranslator()

    @ObservationIgnored private var encoder: CLIPEncoder?
    @ObservationIgnored private var store: IndexStore?
    @ObservationIgnored private var indexer: Indexer?
    @ObservationIgnored private var clusterer: SubjectClusterer?
    @ObservationIgnored private let searchIndex = SearchIndex()
    @ObservationIgnored private let network = NetworkMonitor()
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var libraryLoad: Task<Void, Never>?
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var queryVectors: [String: [Float]] = [:]
    @ObservationIgnored private var activeSearch: (vector: [Float]?, kind: MediaKind?, names: [String])?
    @ObservationIgnored private var lastLiveRefresh = ContinuousClock.now
    @ObservationIgnored private var lastGroupRefresh = ContinuousClock.now
    @ObservationIgnored private let liveRefreshInterval: Duration = .seconds(1)
    /// 이 값보다 유사도가 낮은 결과는 기본으로 숨깁니다. MobileCLIP S2 에서 맞는 결과는 대체로 0.17 이상,
    /// 엉뚱한 결과는 0.14 이하였습니다 (시뮬레이터 샘플 보관함 기준).
    @ObservationIgnored private let minimumScore: Float = 0.15
    @ObservationIgnored private var started = false

    var hasLibraryAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    func start() async {
        guard !started else { return }
        started = true
        Task { await translator.prepare() }
        await loadEngine()
        if hasLibraryAccess {
            libraryAccessGranted()
        }
    }

    func requestAuthorization() async {
        authorization = await PhotoLibrary.requestAuthorization()
        if hasLibraryAccess {
            libraryAccessGranted()
        }
    }

    /// 설정 앱에서 권한을 바꾸고 돌아온 경우를 반영합니다.
    func refreshAuthorization() {
        let current = PhotoLibrary.authorizationStatus
        guard current != authorization else { return }
        authorization = current
        if started, hasLibraryAccess {
            libraryAccessGranted()
        }
    }

    // MARK: - Indexing

    func startIndexing() {
        guard let indexer, hasLibraryAccess, indexTask == nil else { return }
        let options = Indexer.Options(
            allowNetwork: settings.useICloud && (settings.allowCellular || !network.isExpensive),
            includeVideos: settings.includeVideos,
            analyzeSubjects: settings.analyzeSubjects
        )
        isIndexing = true
        setIdleTimerDisabled(true)

        indexTask = Task { [weak self] in
            await indexer.run(options: options) { progress in
                await self?.update(progress: progress)
            }
            await self?.indexingFinished()
        }
    }

    func pauseIndexing() {
        indexTask?.cancel()
    }

    /// 엔진을 준비하고 분석이 끝나거나 취소될 때까지 기다립니다. 백그라운드 작업에서 씁니다.
    func indexUntilDone() async -> Bool {
        await start()
        startIndexing()
        await indexTask?.value
        return progress.isQuickPassComplete && progress.remainingSubjects == 0 && progress.remainingVideoScenes == 0
    }

    /// 남은 분석이 있으면 충전 중 백그라운드 작업을 예약합니다.
    func scheduleBackgroundIndexingIfNeeded() {
        #if os(iOS)
        guard hasLibraryAccess,
              isIndexing || !progress.isQuickPassComplete || progress.remainingSubjects > 0 || progress.remainingVideoScenes > 0 else { return }
        BackgroundIndexing.schedule()
        #endif
    }

    func resetIndex() async {
        indexTask?.cancel()
        await indexTask?.value
        try? store?.deleteAll()
        await searchIndex.replaceAll(with: [])
        await clusterer?.reset()
        groups = []
        subjectNames = []
        selectedNames = []
        results = []
        progress = IndexProgress()
        indexedAssetCount = 0
        startIndexing()
    }

    // MARK: - Search

    func search(_ rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        activeSearch = nil
        pendingResults = nil
        showsWeakMatches = false

        let chipNames = subjectNames.filter(selectedNames.contains)
        guard !query.isEmpty || !chipNames.isEmpty else {
            results = []
            holdsResults = false
            interpretedQuery = nil
            isRankedSearch = true
            return
        }
        guard let encoder else {
            errorMessage = "검색 모델을 아직 불러오는 중입니다."
            return
        }

        isSearching = true
        defer { if generation == searchGeneration { isSearching = false } }

        let parsed = QueryParser.parse(query, names: subjectNames)
        var names = chipNames
        for name in parsed.names where !names.contains(name) { names.append(name) }

        var english = parsed.text
        if QueryParser.containsHangul(english) {
            do {
                english = try await translator.translate(english)
            } catch {
                errorMessage = "한국어 검색어 번역에 실패했습니다. 영어로 검색하거나 설정 > 일반 > 언어 및 지역 > 번역 언어에서 한국어·영어를 내려받아 주세요."
                return
            }
        }
        guard generation == searchGeneration else { return }
        interpretedQuery = [names.joined(separator: ", "), english].filter { !$0.isEmpty }.joined(separator: " · ")

        var queryVector: [Float]?
        if english.isEmpty {
            queryVector = nil
        } else if let cached = queryVectors[english] {
            queryVector = cached
        } else {
            let prompts = QueryParser.prompts(for: english)
            do {
                queryVector = try await Task.detached(priority: .userInitiated) { try encoder.embed(texts: prompts) }.value
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if queryVectors.count >= 200 { queryVectors.removeAll() }
            queryVectors[english] = queryVector
        }

        let kind = scope.kind ?? parsed.kind
        let items = await resultItems(for: queryVector, kind: kind, names: names)
        guard generation == searchGeneration else { return }
        results = items
        isRankedSearch = queryVector != nil
        if items.isEmpty { holdsResults = false }
        activeSearch = (queryVector, kind, names)
        lastLiveRefresh = .now
    }

    func showWeakMatches() async {
        guard let activeSearch, !showsWeakMatches else { return }
        showsWeakMatches = true
        let generation = searchGeneration
        let items = await resultItems(for: activeSearch.vector, kind: activeSearch.kind, names: activeSearch.names)
        guard generation == searchGeneration else { return }
        results = items
        pendingResults = nil
    }

    func applyPendingResults() {
        guard let pendingResults else { return }
        results = pendingResults
        self.pendingResults = nil
    }

    /// pendingResults 중 지금 화면에 없는 결과 수. "새 결과 N개" 버튼에 씁니다.
    var newPendingResultCount: Int {
        guard let pendingResults else { return 0 }
        let shown = Set(results.map(\.id))
        return pendingResults.filter { !shown.contains($0.id) }.count
    }

    /// 분석으로 인덱스가 늘어난 만큼 현재 검색어의 결과를 다시 계산합니다. 쿼리 벡터는 그대로 쓰므로 번역·인코딩 비용이 없습니다.
    private func refreshLiveResults() async {
        guard let activeSearch else { return }
        let generation = searchGeneration
        let items = await resultItems(for: activeSearch.vector, kind: activeSearch.kind, names: activeSearch.names)
        guard generation == searchGeneration else { return }

        let current = pendingResults ?? results
        guard items.map(\.id) != current.map(\.id) else { return }
        if holdsResults && !results.isEmpty {
            pendingResults = items
        } else {
            results = items
            pendingResults = nil
        }
    }

    /// names 가 있으면 그 인물이 모두 나오는 에셋 안에서 찾습니다. vector 가 없으면(이름만 검색) 최신순으로 보여줍니다.
    private func resultItems(for vector: [Float]?, kind: MediaKind?, names: [String]) async -> [ResultItem] {
        var allowed: Set<String>?
        if !names.isEmpty {
            let assets = await clusterer?.assetIDs(named: names) ?? []
            guard !assets.isEmpty else { return [] }
            allowed = assets
        }

        guard let vector else {
            guard let allowed else { return [] }
            let items = PhotoLibrary.assets(withIDs: Array(allowed)).values
                .map(ResultItem.init(asset:))
                .filter { kind == nil || $0.hit.kind == kind }
                .sorted { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
            return Array(items.prefix(500))
        }

        let minScore = showsWeakMatches ? -Float.infinity : minimumScore
        let hits = await searchIndex.search(vector, kind: kind, assets: allowed, minScore: minScore, limit: 120)
        let assets = PhotoLibrary.assets(withIDs: hits.map(\.assetID))
        return hits.compactMap { hit in assets[hit.assetID].map { ResultItem(hit: hit, asset: $0) } }
    }

    /// 지금 검색어와 동영상 각 장면의 유사도. 이름만으로 검색해 검색어 벡터가 없으면 빈 배열입니다.
    func frameScores(for assetID: String) async -> [FrameScore] {
        guard let vector = activeSearch?.vector else { return [] }
        return await searchIndex.frameScores(vector, assetID: assetID)
    }

    // MARK: - Editing

    func setFavorite(_ isFavorite: Bool, for item: ResultItem) async {
        do {
            try await PhotoLibrary.setFavorite(isFavorite, for: item.asset)
            libraryDidChange()
        } catch {
            errorMessage = "즐겨찾기를 바꾸지 못했어요. \(error.localizedDescription)"
        }
    }

    /// 지웠으면 true. 확인 창에서 취소하거나 실패하면 false 입니다.
    @discardableResult
    func delete(_ items: [ResultItem]) async -> Bool {
        do {
            guard try await PhotoLibrary.delete(items.map(\.asset)) else { return false }
            libraryDidChange()
            return true
        } catch {
            errorMessage = "삭제하지 못했어요. \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - People

    func group(id: Int64) -> SubjectGroup? {
        groups.first { $0.id == id }
    }

    func members(of clusterID: Int64) async -> [StoredSubject] {
        await clusterer?.members(of: clusterID) ?? []
    }

    /// 같은 이름의 그룹이 있으면 합쳐지므로, 화면이 따라갈 수 있게 남은 그룹 ID 를 돌려줍니다.
    @discardableResult
    func renameGroup(_ clusterID: Int64, to name: String) async -> Int64 {
        guard let clusterer else { return clusterID }
        do {
            let id = try await clusterer.rename(clusterID, to: name)
            await peopleDidChange()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return clusterID
        }
    }

    func reject(subjects subjectIDs: [Int64], from clusterID: Int64) async {
        guard let clusterer else { return }
        do {
            try await clusterer.reject(subjectIDs, from: clusterID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await peopleDidChange()
    }

    func refreshGroups() async {
        guard let clusterer else { return }
        groups = await clusterer.groups()
        subjectNames = await clusterer.names()
        selectedNames.formIntersection(subjectNames)
        lastGroupRefresh = .now
    }

    private func peopleDidChange() async {
        await refreshGroups()
        if activeSearch?.names.isEmpty == false {
            await refreshLiveResults()
        }
    }

    // MARK: - Private

    private func loadEngine() async {
        do {
            let (encoder, faceEncoder, store, vectors) = try await Task.detached(priority: .userInitiated) {
                let encoder = try CLIPEncoder()
                // 얼굴 모델이 없으면(make face-model 을 안 한 경우) 반려동물만 구분합니다.
                let faceEncoder = try? FaceEncoder()
                let store = try IndexStore.openDefault()
                let vectors = try store.loadVectors(model: CLIPEncoder.modelName, dimension: CLIPEncoder.dimension)
                return (encoder, faceEncoder, store, vectors)
            }.value
            await searchIndex.replaceAll(with: vectors)
            let clusterer = SubjectClusterer(store: store)
            do {
                try await clusterer.load()
            } catch {
                errorMessage = error.localizedDescription
            }
            self.encoder = encoder
            self.store = store
            self.clusterer = clusterer
            recognizesFaces = faceEncoder != nil
            indexer = Indexer(
                store: store,
                searchIndex: searchIndex,
                encoder: encoder,
                subjectDetector: SubjectDetector(faceEncoder: faceEncoder, clipEncoder: encoder),
                clusterer: clusterer
            )
            indexedAssetCount = await searchIndex.assetCount
            await refreshGroups()
            isEngineReady = true
            // Core ML 은 첫 추론에서 모델을 연산 장치에 올리느라 수 초가 걸리므로 첫 검색 전에 미리 한 번 돌려 둡니다.
            Task.detached(priority: .userInitiated) { _ = try? encoder.embed(text: "a photo") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func libraryAccessGranted() {
        if observer == nil {
            observer = LibraryObserver { [weak self] in
                Task { @MainActor in self?.libraryDidChange() }
            }
        }
        reloadLibrary()
        startIndexing()
    }

    private func reloadLibrary() {
        libraryLoad?.cancel()
        libraryLoad = Task { [weak self] in
            let (items, days) = await Task.detached(priority: .userInitiated) {
                let items = PhotoLibrary.fetchAllAssets().map(ResultItem.init(asset:))
                return (items, LibraryDay.grouping(items))
            }.value
            guard !Task.isCancelled else { return }
            self?.libraryItems = items
            self?.libraryDays = days
        }
    }

    private func libraryDidChange() {
        libraryRevision += 1
        reloadLibrary()
        results = ResultItem.refetched(results)
        pendingResults = pendingResults.map(ResultItem.refetched)
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.startIndexing()
        }
    }

    private func update(progress: IndexProgress) async {
        self.progress = progress
        if isIndexing { setIdleTimerDisabled(!progress.isQuickPassComplete) }
        indexedAssetCount = await searchIndex.assetCount
        if progress.subjectsDone > 0, ContinuousClock.now - lastGroupRefresh >= liveRefreshInterval {
            await refreshGroups()
        }
        if activeSearch != nil, ContinuousClock.now - lastLiveRefresh >= liveRefreshInterval {
            lastLiveRefresh = .now
            await refreshLiveResults()
        }
    }

    private func indexingFinished() async {
        indexTask = nil
        isIndexing = false
        setIdleTimerDisabled(false)
        await refreshGroups()
        await refreshLiveResults()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
