import Accelerate
import Foundation

/// 모든 임베딩을 하나의 행렬로 메모리에 들고 있다가 질의 벡터와 한 번에 내적합니다.
/// 검색 루프에서 문자열 해싱을 피하려고 행은 에셋 ID 대신 정수 슬롯 번호를 가리킵니다.
actor SearchIndex {
    private let dimension: Int
    private var rowSlots: [Int] = []
    private var times: [Double] = []
    private var matrix: [Float] = []
    private var slotIDs: [String] = []
    private var slotKinds: [MediaKind] = []
    private var slotByID: [String: Int] = [:]

    init(dimension: Int = CLIPEncoder.dimension) {
        self.dimension = dimension
    }

    var assetCount: Int { slotByID.count }

    func replaceAll(with vectors: [StoredVector]) {
        rowSlots = []
        times = []
        matrix = []
        slotIDs = []
        slotKinds = []
        slotByID = [:]
        for vector in vectors where vector.vector.count == dimension {
            appendRow(assetID: vector.assetID, kind: vector.kind, time: vector.time, vector: vector.vector)
        }
    }

    func add(assetID: String, kind: MediaKind, frames: [FrameEmbedding]) {
        remove([assetID])
        for frame in frames where frame.vector.count == dimension {
            appendRow(assetID: assetID, kind: kind, time: frame.time, vector: frame.vector)
        }
    }

    func remove(_ ids: Set<String>) {
        guard ids.contains(where: { slotByID[$0] != nil }) else { return }

        var newSlot = [Int](repeating: -1, count: slotIDs.count)
        var keptIDs: [String] = [], keptKinds: [MediaKind] = []
        for slot in slotIDs.indices where !ids.contains(slotIDs[slot]) {
            newSlot[slot] = keptIDs.count
            keptIDs.append(slotIDs[slot])
            keptKinds.append(slotKinds[slot])
        }

        var keptRows: [Int] = [], keptTimes: [Double] = [], keptMatrix: [Float] = []
        for row in rowSlots.indices where newSlot[rowSlots[row]] >= 0 {
            keptRows.append(newSlot[rowSlots[row]])
            keptTimes.append(times[row])
            keptMatrix.append(contentsOf: matrix[(row * dimension)..<((row + 1) * dimension)])
        }

        (rowSlots, times, matrix) = (keptRows, keptTimes, keptMatrix)
        (slotIDs, slotKinds) = (keptIDs, keptKinds)
        slotByID = Dictionary(uniqueKeysWithValues: keptIDs.enumerated().map { ($1, $0) })
    }

    /// 에셋별로 가장 점수가 높은 프레임을 대표로 삼아 정렬된 결과를 돌려줍니다. minScore 미만인 에셋은 뺍니다.
    /// assets 를 주면 그 에셋들 안에서만 찾습니다(특정 인물이 나오는 사진 등).
    func search(_ query: [Float], kind: MediaKind?, assets: Set<String>? = nil, minScore: Float = -.infinity, limit: Int) -> [SearchHit] {
        let rows = rowSlots.count
        guard rows > 0, limit > 0, query.count == dimension else { return [] }
        let allowed = assets.map { assets in slotIDs.map { assets.contains($0) } }

        var scores = [Float](repeating: 0, count: rows)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
            }
        }

        var bestScore = [Float](repeating: -.infinity, count: slotIDs.count)
        var bestRow = [Int](repeating: -1, count: slotIDs.count)
        scores.withUnsafeBufferPointer { scores in
            rowSlots.withUnsafeBufferPointer { rowSlots in
                slotKinds.withUnsafeBufferPointer { slotKinds in
                    for row in 0..<rows {
                        let slot = rowSlots[row]
                        if let kind, slotKinds[slot] != kind { continue }
                        if let allowed, !allowed[slot] { continue }
                        if scores[row] > bestScore[slot] {
                            bestScore[slot] = scores[row]
                            bestRow[slot] = row
                        }
                    }
                }
            }
        }

        // 전체 정렬 대신 상위 limit 개만 점수 내림차순으로 유지합니다.
        var top: [Int] = []
        top.reserveCapacity(limit + 1)
        for slot in bestRow.indices where bestRow[slot] >= 0 {
            let score = bestScore[slot]
            if score < minScore { continue }
            if top.count == limit, score <= bestScore[top[limit - 1]] { continue }
            var low = 0, high = top.count
            while low < high {
                let mid = (low + high) / 2
                if bestScore[top[mid]] >= score { low = mid + 1 } else { high = mid }
            }
            top.insert(slot, at: low)
            if top.count > limit { top.removeLast() }
        }

        return top.map { slot in
            SearchHit(assetID: slotIDs[slot], kind: slotKinds[slot], score: bestScore[slot], time: times[bestRow[slot]])
        }
    }

    /// 한 에셋의 모든 프레임이 검색어와 얼마나 맞는지 시각 순으로 돌려줍니다. 동영상에서 장면이 이어지는 구간을 찾는 데 씁니다.
    func frameScores(_ query: [Float], assetID: String) -> [FrameScore] {
        guard query.count == dimension, let slot = slotByID[assetID] else { return [] }
        var result: [FrameScore] = []
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                for row in rowSlots.indices where rowSlots[row] == slot {
                    var score: Float = 0
                    vDSP_dotpr(m.baseAddress! + row * dimension, 1, q.baseAddress!, 1, &score, vDSP_Length(dimension))
                    result.append(FrameScore(time: times[row], score: score))
                }
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private func appendRow(assetID: String, kind: MediaKind, time: Double, vector: [Float]) {
        let slot: Int
        if let existing = slotByID[assetID] {
            slot = existing
        } else {
            slot = slotIDs.count
            slotIDs.append(assetID)
            slotKinds.append(kind)
            slotByID[assetID] = slot
        }
        rowSlots.append(slot)
        times.append(time)
        matrix.append(contentsOf: vector)
    }
}
