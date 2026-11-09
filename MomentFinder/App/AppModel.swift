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
    var scope: MediaScope = .all
    var errorMessage: String?

    let settings = IndexSettings()
    let translator = QueryTranslator()

    @ObservationIgnored private var encoder: CLIPEncoder?
    @ObservationIgnored private var store: IndexStore?
    @ObservationIgnored private var indexer: Indexer?
    @ObservationIgnored private let searchIndex = SearchIndex()
    @ObservationIgnored private let network = NetworkMonitor()
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var queryVectors: [String: [Float]] = [:]
    @ObservationIgnored private var activeSearch: (vector: [Float], kind: MediaKind?)?
    @ObservationIgnored private var lastLiveRefresh = ContinuousClock.now
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
            includeVideos: settings.includeVideos
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
        return progress.isQuickPassComplete && progress.remainingVideoScenes == 0
    }

    /// 남은 분석이 있으면 충전 중 백그라운드 작업을 예약합니다.
    func scheduleBackgroundIndexingIfNeeded() {
        #if os(iOS)
        guard hasLibraryAccess, isIndexing || !progress.isQuickPassComplete || progress.remainingVideoScenes > 0 else { return }
        BackgroundIndexing.schedule()
        #endif
    }

    func resetIndex() async {
        indexTask?.cancel()
        await indexTask?.value
        try? store?.deleteAll()
        await searchIndex.replaceAll(with: [])
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

        guard !query.isEmpty else {
            results = []
            holdsResults = false
            interpretedQuery = nil
            return
        }
        guard let encoder else {
            errorMessage = "검색 모델을 아직 불러오는 중입니다."
            return
        }

        isSearching = true
        defer { if generation == searchGeneration { isSearching = false } }

        let parsed = QueryParser.parse(query)
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
        interpretedQuery = english

        let queryVector: [Float]
        if let cached = queryVectors[english] {
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
        let items = await resultItems(for: queryVector, kind: kind)
        guard generation == searchGeneration else { return }
        results = items
        if items.isEmpty { holdsResults = false }
        activeSearch = (queryVector, kind)
        lastLiveRefresh = .now
    }

    func showWeakMatches() async {
        guard let activeSearch, !showsWeakMatches else { return }
        showsWeakMatches = true
        let generation = searchGeneration
        let items = await resultItems(for: activeSearch.vector, kind: activeSearch.kind)
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
        let items = await resultItems(for: activeSearch.vector, kind: activeSearch.kind)
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

    private func resultItems(for vector: [Float], kind: MediaKind?) async -> [ResultItem] {
        let minScore = showsWeakMatches ? -Float.infinity : minimumScore
        let hits = await searchIndex.search(vector, kind: kind, minScore: minScore, limit: 120)
        let assets = PhotoLibrary.assets(withIDs: hits.map(\.assetID))
        return hits.compactMap { hit in assets[hit.assetID].map { ResultItem(hit: hit, asset: $0) } }
    }

    // MARK: - Private

    private func loadEngine() async {
        do {
            let (encoder, store, vectors) = try await Task.detached(priority: .userInitiated) {
                let encoder = try CLIPEncoder()
                let store = try IndexStore.openDefault()
                let vectors = try store.loadVectors(model: CLIPEncoder.modelName, dimension: CLIPEncoder.dimension)
                return (encoder, store, vectors)
            }.value
            await searchIndex.replaceAll(with: vectors)
            self.encoder = encoder
            self.store = store
            indexer = Indexer(store: store, searchIndex: searchIndex, encoder: encoder)
            indexedAssetCount = await searchIndex.assetCount
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
        startIndexing()
    }

    private func libraryDidChange() {
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
        if activeSearch != nil, ContinuousClock.now - lastLiveRefresh >= liveRefreshInterval {
            lastLiveRefresh = .now
            await refreshLiveResults()
        }
    }

    private func indexingFinished() async {
        indexTask = nil
        isIndexing = false
        setIdleTimerDisabled(false)
        await refreshLiveResults()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
