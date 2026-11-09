import Accelerate
import Foundation

/// 새 개체를 가장 비슷한 그룹에 붙이거나 새 그룹을 만드는 증분 군집화. DB 가 원본이고 메모리에는 그룹별 벡터 합과 구성원 정보만 둡니다.
/// 사용자가 확정하거나 거절한 배치는 자동 군집화가 되돌리지 않습니다.
actor SubjectClusterer {
    /// 얼굴(MobileFaceNet)은 같은 사람과 그룹 중심의 유사도가 대체로 0.5 이상, 다른 사람은 0.3 이하입니다.
    /// 같은 사람이 둘로 나뉘는 쪽이 다른 사람이 섞이는 쪽보다 고치기 쉬워서 보수적으로 둡니다.
    static let faceThreshold: Float = 0.45
    /// 반려동물(CLIP 이미지 임베딩)은 같은 종끼리도 0.7~0.8 이 나와서 훨씬 높게 잡습니다.
    static let petThreshold: Float = 0.85
    /// 이보다 구성원이 적고 이름도 없는 그룹은 인물 화면에 보여주지 않습니다(지나가던 사람 등).
    static let minimumVisibleMembers = 3

    private struct Cluster {
        let id: Int64
        let species: Species
        var name: String?
        var sum: [Float]
        var count: Int
        var centroid: [Float]
    }

    private let store: IndexStore
    private let dimension: Int
    private var clusters: [Int64: Cluster] = [:]
    private var subjects: [Int64: StoredSubject] = [:]
    private var subjectsByAsset: [String: [Int64]] = [:]
    private var rejected: [Int64: Set<Int64>] = [:]

    init(store: IndexStore, dimension: Int = CLIPEncoder.dimension) {
        self.store = store
        self.dimension = dimension
    }

    static func threshold(for species: Species) -> Float {
        species == .person ? faceThreshold : petThreshold
    }

    func load() throws {
        reset()
        for cluster in try store.loadClusters() {
            clusters[cluster.id] = Cluster(
                id: cluster.id, species: cluster.species, name: cluster.name,
                sum: [Float](repeating: 0, count: dimension), count: 0, centroid: []
            )
        }
        for (subjectID, clusterID) in try store.loadRejections() {
            rejected[subjectID, default: []].insert(clusterID)
        }
        var unplaced: [StoredSubject] = []
        try store.forEachSubject(dimension: dimension) { subject, vector in
            var subject = subject
            if let clusterID = subject.clusterID, var cluster = clusters[clusterID], cluster.species == subject.species {
                cluster.sum = vDSP.add(cluster.sum, vector)
                cluster.count += 1
                clusters[clusterID] = cluster
            } else {
                subject.clusterID = nil
                unplaced.append(subject)
            }
            track(subject)
        }
        for (id, cluster) in clusters {
            clusters[id]?.centroid = CLIPEncoder.normalized(cluster.sum)
        }
        try removeEmptyClusters()

        let vectors = try store.subjectVectors(ids: unplaced.map(\.id), dimension: dimension)
        for subject in unplaced {
            if let vector = vectors[subject.id] { try place(subject.id, vector: vector) }
        }
    }

    func reset() {
        clusters = [:]
        subjects = [:]
        subjectsByAsset = [:]
        rejected = [:]
    }

    /// 방금 저장한 개체들을 그룹에 넣습니다. vectors 는 subjects 와 같은 순서입니다.
    func add(_ newSubjects: [StoredSubject], vectors: [[Float]]) throws {
        for (subject, vector) in zip(newSubjects, vectors) where vector.count == dimension {
            track(subject)
            try place(subject.id, vector: vector)
        }
    }

    /// DB 에서 지우기 전에 불러야 합니다. 그룹 중심에서 빼려면 저장된 벡터가 필요합니다.
    func remove(assetIDs: Set<String>) throws {
        let ids = assetIDs.flatMap { subjectsByAsset[$0] ?? [] }
        guard !ids.isEmpty else { return }
        let vectors = try store.subjectVectors(ids: ids, dimension: dimension)
        for id in ids {
            if let vector = vectors[id] { detach(id, vector: vector) }
            if let subject = subjects.removeValue(forKey: id) {
                subjectsByAsset[subject.assetID]?.removeAll { $0 == id }
                if subjectsByAsset[subject.assetID]?.isEmpty == true { subjectsByAsset[subject.assetID] = nil }
            }
            rejected[id] = nil
        }
        try removeEmptyClusters()
    }

    /// 이름을 바꿉니다. 같은 종류에 같은 이름의 그룹이 이미 있으면 그 그룹으로 합치고, 합쳐진 그룹 ID 를 돌려줍니다.
    @discardableResult
    func rename(_ clusterID: Int64, to rawName: String?) throws -> Int64 {
        guard let cluster = clusters[clusterID] else { return clusterID }
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let name, let existing = clusters.values.first(where: { $0.id != clusterID && $0.species == cluster.species && $0.name == name }) {
            try merge(clusterID, into: existing.id)
            return existing.id
        }
        try store.renameCluster(id: clusterID, name: name)
        clusters[clusterID]?.name = name
        return clusterID
    }

    /// "이 사람이 아니에요": 그룹에서 빼고 다시는 그 그룹에 넣지 않으며, 나머지 그룹 중 가장 비슷한 곳(없으면 새 그룹)으로 보냅니다.
    func reject(_ subjectIDs: [Int64], from clusterID: Int64) throws {
        let ids = subjectIDs.filter { subjects[$0]?.clusterID == clusterID }
        let vectors = try store.subjectVectors(ids: ids, dimension: dimension)
        for id in ids {
            guard let vector = vectors[id] else { continue }
            try store.addRejection(subjectID: id, clusterID: clusterID)
            rejected[id, default: []].insert(clusterID)
            detach(id, vector: vector)
            try place(id, vector: vector)
        }
        try removeEmptyClusters()
    }

    /// 사진 속 개체 하나에 이름을 붙입니다. 이름 없는 그룹에 속해 있으면 그룹 전체에 이름을 붙이고,
    /// 다른 이름의 그룹에 잘못 들어가 있으면 이 개체만 해당 이름의 그룹으로 옮깁니다.
    @discardableResult
    func name(subject subjectID: Int64, as rawName: String) throws -> Int64? {
        guard let subject = subjects[subjectID],
              let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if let current = subject.clusterID, let cluster = clusters[current] {
            if cluster.name == nil { return try rename(current, to: name) }
            if cluster.name == name { return current }
        }
        guard let vector = try store.subjectVectors(ids: [subjectID], dimension: dimension)[subjectID] else { return nil }
        if let current = subject.clusterID {
            try store.addRejection(subjectID: subjectID, clusterID: current)
            rejected[subjectID, default: []].insert(current)
            detach(subjectID, vector: vector)
        }
        let target = try clusters.values.first(where: { $0.species == subject.species && $0.name == name })?.id
            ?? createCluster(species: subject.species, name: name)
        rejected[subjectID]?.remove(target)
        try join(subjectID, cluster: target, vector: vector, assignment: .confirmed)
        try removeEmptyClusters()
        return target
    }

    // MARK: - Queries

    func groups() -> [SubjectGroup] {
        var members: [Int64: [StoredSubject]] = [:]
        for subject in subjects.values {
            if let clusterID = subject.clusterID { members[clusterID, default: []].append(subject) }
        }
        return clusters.values.compactMap { cluster in
            let list = members[cluster.id] ?? []
            guard cluster.name != nil || list.count >= Self.minimumVisibleMembers else { return nil }
            return SubjectGroup(
                id: cluster.id,
                species: cluster.species,
                name: cluster.name,
                assetCount: Set(list.map(\.assetID)).count,
                cover: list.max { $0.quality < $1.quality }
            )
        }
        .sorted { ($0.name != nil ? 1 : 0, $0.assetCount, $1.id) > ($1.name != nil ? 1 : 0, $1.assetCount, $0.id) }
    }

    func names() -> [String] {
        Array(Set(clusters.values.compactMap(\.name))).sorted()
    }

    /// 이름마다 그 이름의 그룹 중 하나라도 나오는 에셋을 모으고, 여러 이름이면 모두 나오는 에셋만 남깁니다.
    func assetIDs(named names: [String]) -> Set<String> {
        var result: Set<String>?
        for name in names {
            let clusterIDs = Set(clusters.values.filter { $0.name == name }.map(\.id))
            let assets = Set(subjects.values.filter { $0.clusterID.map(clusterIDs.contains) ?? false }.map(\.assetID))
            result = result.map { $0.intersection(assets) } ?? assets
        }
        return result ?? []
    }

    func members(of clusterID: Int64) -> [StoredSubject] {
        subjects.values.filter { $0.clusterID == clusterID }
    }

    func subjects(inAsset assetID: String) -> [(subject: StoredSubject, name: String?)] {
        (subjectsByAsset[assetID] ?? []).compactMap { subjects[$0] }
            .sorted { $0.box.minX < $1.box.minX }
            .map { ($0, $0.clusterID.flatMap { clusters[$0]?.name }) }
    }

    func clusterName(_ clusterID: Int64) -> String? {
        clusters[clusterID]?.name
    }

    // MARK: - Private

    private func track(_ subject: StoredSubject) {
        if subjects[subject.id] == nil {
            subjectsByAsset[subject.assetID, default: []].append(subject.id)
        }
        subjects[subject.id] = subject
    }

    /// 한 사진에 함께 나온 개체는 서로 다른 개체이므로, 같은 사진의 다른 개체가 이미 들어간 그룹은 후보에서 뺍니다.
    private func place(_ subjectID: Int64, vector: [Float]) throws {
        guard let subject = subjects[subjectID] else { return }
        let siblings = (subjectsByAsset[subject.assetID] ?? []).compactMap { $0 == subjectID ? nil : subjects[$0]?.clusterID }
        let excluded = (rejected[subjectID] ?? []).union(siblings)
        var best: (id: Int64, score: Float)?
        for cluster in clusters.values where cluster.species == subject.species && cluster.count > 0 && !excluded.contains(cluster.id) {
            let score = vDSP.dot(vector, cluster.centroid)
            if score > (best?.score ?? -.infinity) { best = (cluster.id, score) }
        }
        let target: Int64
        if let best, best.score >= Self.threshold(for: subject.species) {
            target = best.id
        } else {
            target = try createCluster(species: subject.species, name: nil)
        }
        try join(subjectID, cluster: target, vector: vector, assignment: .auto)
    }

    private func createCluster(species: Species, name: String?) throws -> Int64 {
        let id = try store.createCluster(species: species, name: name)
        clusters[id] = Cluster(id: id, species: species, name: name, sum: [Float](repeating: 0, count: dimension), count: 0, centroid: [])
        return id
    }

    private func join(_ subjectID: Int64, cluster clusterID: Int64, vector: [Float], assignment: SubjectAssignment) throws {
        guard var cluster = clusters[clusterID] else { return }
        try store.assignSubjects([subjectID], to: clusterID, assignment: assignment)
        cluster.sum = vDSP.add(cluster.sum, vector)
        cluster.count += 1
        cluster.centroid = CLIPEncoder.normalized(cluster.sum)
        clusters[clusterID] = cluster
        subjects[subjectID]?.clusterID = clusterID
        subjects[subjectID]?.assignment = assignment
    }

    /// 메모리에서만 그룹에서 떼어냅니다. 이어서 다른 그룹에 넣거나 개체를 지우는 쪽에서 DB 를 갱신합니다.
    private func detach(_ subjectID: Int64, vector: [Float]) {
        guard let clusterID = subjects[subjectID]?.clusterID, var cluster = clusters[clusterID] else { return }
        cluster.sum = vDSP.subtract(cluster.sum, vector)
        cluster.count = max(0, cluster.count - 1)
        cluster.centroid = cluster.count > 0 ? CLIPEncoder.normalized(cluster.sum) : []
        clusters[clusterID] = cluster
        subjects[subjectID]?.clusterID = nil
    }

    private func merge(_ source: Int64, into target: Int64) throws {
        guard let from = clusters[source], var into = clusters[target] else { return }
        try store.mergeCluster(source, into: target)
        into.sum = vDSP.add(into.sum, from.sum)
        into.count += from.count
        into.centroid = into.count > 0 ? CLIPEncoder.normalized(into.sum) : []
        clusters[target] = into
        clusters[source] = nil
        for (id, subject) in subjects where subject.clusterID == source {
            subjects[id]?.clusterID = target
        }
        for (id, clusterIDs) in rejected where clusterIDs.contains(source) {
            rejected[id]?.remove(source)
            rejected[id]?.insert(target)
        }
    }

    private func removeEmptyClusters() throws {
        let empty = Set(clusters.values.filter { $0.count == 0 }.map(\.id))
        guard !empty.isEmpty else { return }
        try store.deleteClusters(empty)
        for id in empty { clusters[id] = nil }
        for (id, clusterIDs) in rejected where !clusterIDs.isDisjoint(with: empty) {
            rejected[id] = clusterIDs.subtracting(empty)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
