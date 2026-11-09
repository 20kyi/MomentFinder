import CoreGraphics
import Foundation

/// 사진 속에서 개체로 구분하는 대상. 사람은 얼굴 인식 모델, 개·고양이는 CLIP 으로 생김새를 비교합니다.
enum Species: Int, Sendable, Hashable, CaseIterable {
    case person = 1
    case dog = 2
    case cat = 3

    var isPet: Bool { self != .person }
}

/// 사용자가 직접 넣은 구성원은 자동 군집화가 다른 그룹으로 옮기지 않습니다.
enum SubjectAssignment: Int, Sendable {
    case auto = 0
    case confirmed = 1
}

/// 분석 직후의 개체. box 는 똑바로 세운 이미지 기준 0~1 좌표(왼쪽 위 원점)입니다.
struct DetectedSubject: Sendable {
    let species: Species
    let box: CGRect
    let quality: Float
    let vector: [Float]
}

struct StoredSubject: Sendable, Identifiable, Hashable {
    let id: Int64
    let assetID: String
    let species: Species
    let box: CGRect
    let quality: Float
    var clusterID: Int64?
    var assignment: SubjectAssignment

    static func == (lhs: StoredSubject, rhs: StoredSubject) -> Bool {
        lhs.id == rhs.id && lhs.clusterID == rhs.clusterID && lhs.assignment == rhs.assignment
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct StoredCluster: Sendable, Hashable {
    let id: Int64
    let species: Species
    var name: String?
}

/// 인물 화면과 검색 칩에 쓰는 그룹 요약.
struct SubjectGroup: Identifiable, Hashable, Sendable {
    let id: Int64
    let species: Species
    let name: String?
    let assetCount: Int
    let cover: StoredSubject?
}
