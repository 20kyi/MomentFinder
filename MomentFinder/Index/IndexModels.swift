import Foundation

enum MediaKind: Int, Sendable, Hashable {
    case photo = 1
    case video = 2
}

/// 동영상은 먼저 대표 이미지 한 장(preview)으로 검색되게 하고, 장면 분석을 마치면 complete 가 됩니다. 사진은 처음부터 complete.
enum IndexDetail: Int, Sendable {
    case preview = 0
    case complete = 1
}

/// 한 에셋에서 뽑은 임베딩 하나. 사진은 time 0 하나, 동영상은 프레임마다 하나씩 가집니다.
struct FrameEmbedding: Sendable {
    let time: Double
    let vector: [Float]
}

struct StoredVector: Sendable {
    let assetID: String
    let kind: MediaKind
    let time: Double
    let vector: [Float]
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let assetID: String
    let kind: MediaKind
    let score: Float
    /// 동영상에서 가장 잘 맞는 장면의 시각(초).
    let time: Double

    var id: String { assetID }
}

struct IndexProgress: Sendable, Equatable {
    /// 사진과 동영상 대표 이미지 분석. 이것이 끝나면 모든 에셋이 검색됩니다.
    var total = 0
    var indexed = 0
    var failed = 0
    /// 동영상 장면 분석. iCloud 동영상은 원본을 내려받아야 해서 오래 걸립니다.
    var videoTotal = 0
    var videoScenesDone = 0

    var fraction: Double { total == 0 ? 0 : Double(indexed) / Double(total) }
    var isQuickPassComplete: Bool { indexed + failed >= total }
    var sceneFraction: Double { videoTotal == 0 ? 1 : Double(videoScenesDone) / Double(videoTotal) }
    var remainingVideoScenes: Int { max(0, videoTotal - videoScenesDone) }
}
