import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import MomentFinder

struct FaceAlignerTests {
    @Test func recoversKnownSimilarity() throws {
        let angle = CGFloat.pi / 7, scale: CGFloat = 1.8
        let known = CGAffineTransform(a: scale * cos(angle), b: scale * sin(angle), c: -scale * sin(angle), d: scale * cos(angle), tx: 30, ty: -12)
        let source = FaceAligner.template.map { $0.applying(known.inverted()) }

        let estimated = try #require(FaceAligner.similarity(from: source, to: FaceAligner.template))
        for (point, target) in zip(source, FaceAligner.template) {
            let mapped = point.applying(estimated)
            #expect(abs(mapped.x - target.x) < 1e-6 && abs(mapped.y - target.y) < 1e-6)
        }
    }

    /// 픽셀 좌표(위가 원점)와 CoreGraphics(아래가 원점) 사이의 뒤집기가 맞는지, 원본의 왼쪽 눈 위치에 칠한 점이 정렬 후 기준 위치에 오는지로 확인합니다.
    @Test func alignedFacePutsLandmarksOnTemplate() throws {
        let width = 400, height = 300
        let offset = CGPoint(x: 100, y: 40)
        let landmarks = FaceAligner.template.map { CGPoint(x: $0.x * 2 + offset.x, y: $0.y * 2 + offset.y) }

        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        let eye = landmarks[0]
        context.fillEllipse(in: CGRect(x: eye.x - 8, y: CGFloat(height) - eye.y - 8, width: 16, height: 16))
        let image = try #require(context.makeImage())

        let buffer = try #require(FaceAligner.alignedFace(from: image, landmarks: landmarks))
        #expect(CVPixelBufferGetWidth(buffer) == FaceAligner.side)
        #expect(pixel(buffer, at: FaceAligner.template[0]) == (255, 0, 0))
        #expect(pixel(buffer, at: FaceAligner.template[1]) == (255, 255, 255))
    }

    /// 시뮬레이터의 GPU 경로처럼 0 벡터가 나오면 모든 얼굴이 서로 구분되지 않으므로 단위 벡터인지 확인합니다.
    @Test func faceEncoderReturnsUnitVector() async throws {
        let encoder = try FaceEncoder()
        let side = FaceAligner.side
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.9, green: 0.7, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: 0.2, green: 0.1, blue: 0.1, alpha: 1)
        for point in FaceAligner.template {
            context.fillEllipse(in: CGRect(x: point.x - 4, y: CGFloat(side) - point.y - 4, width: 8, height: 8))
        }
        let image = try #require(context.makeImage())
        let buffer = try #require(FaceAligner.alignedFace(from: image, landmarks: FaceAligner.template))

        let vector = try await encoder.embed(alignedFace: buffer)
        #expect(vector.count == FaceEncoder.dimension)
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
    }

    @Test func convertsVisionBoxToTopLeft() {
        let box = SubjectDetector.topLeftBox(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(abs(box.minY - 0.4) < 1e-9)
        #expect(box.minX == 0.1 && box.width == 0.3 && box.height == 0.4)
    }

    private func pixel(_ buffer: CVPixelBuffer, at point: CGPoint) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4
        func level(_ value: UInt8) -> Int { value > 200 ? 255 : value < 55 ? 0 : Int(value) }
        return (level(base[offset + 2]), level(base[offset + 1]), level(base[offset]))
    }
}

struct SubjectClustererTests {
    private func store() throws -> IndexStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try IndexStore(url: directory.appending(path: "index.sqlite"))
    }

    /// i 번 축 방향에 약간의 j 번 축 성분을 섞은 단위 벡터.
    private func vector(_ i: Int, noise j: Int = 511, _ amount: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: CLIPEncoder.dimension)
        v[i] = 1
        v[j] += amount
        return CLIPEncoder.normalized(v)
    }

    @discardableResult
    private func add(_ clusterer: SubjectClusterer, _ store: IndexStore, asset: String, species: Species = .person, _ vectors: [[Float]]) async throws -> [StoredSubject] {
        let detected = vectors.map { DetectedSubject(species: species, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), quality: 0.5, vector: $0) }
        let stored = try store.saveSubjects(assetID: asset, model: "m", subjects: detected)
        try await clusterer.add(stored, vectors: vectors)
        return stored
    }

    private func clusterIDs(_ clusterer: SubjectClusterer, _ assets: [String]) async -> [Int64?] {
        var ids: [Int64?] = []
        for asset in assets {
            ids.append(await clusterer.subjects(inAsset: asset).first?.subject.clusterID)
        }
        return ids
    }

    @Test func groupsSimilarFacesAndHidesSmallGroups() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        for (i, amount) in [Float(0), 0.2, 0.3].enumerated() {
            try await add(clusterer, store, asset: "mom\(i)", [vector(0, amount)])
        }
        try await add(clusterer, store, asset: "stranger", [vector(1)])

        let ids = await clusterIDs(clusterer, ["mom0", "mom1", "mom2", "stranger"])
        #expect(Set(ids[0..<3]).count == 1)
        #expect(ids[3] != ids[0])

        let groups = await clusterer.groups()
        #expect(groups.count == 1)
        #expect(groups.first?.assetCount == 3)
    }

    /// 한 사진 속 닮은 두 고양이(시뮬레이터 샘플에서 실제 유사도 0.82)가 한 그룹이 되면 안 됩니다.
    @Test func subjectsInSamePhotoNeverShareGroup() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        try await add(clusterer, store, asset: "two-cats", species: .cat, [vector(0), vector(0, 0.05)])

        let entries = await clusterer.subjects(inAsset: "two-cats")
        #expect(entries.count == 2)
        #expect(entries[0].subject.clusterID != entries[1].subject.clusterID)
    }

    @Test func keepsSpeciesApartAndUsesStricterPetThreshold() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        try await add(clusterer, store, asset: "a", species: .dog, [vector(0)])
        try await add(clusterer, store, asset: "b", species: .cat, [vector(0)])
        // 사람 기준(0.45)이면 합쳐질 유사도(약 0.7)지만 반려동물 기준(0.85)에는 못 미칩니다.
        try await add(clusterer, store, asset: "c", species: .dog, [vector(0, noise: 2, 1)])

        let ids = await clusterIDs(clusterer, ["a", "b", "c"])
        #expect(Set(ids).count == 3)
    }

    @Test func rejectedSubjectNeverReturnsEvenAfterReload() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        var stored: [StoredSubject] = []
        for i in 0..<4 {
            let added = try await add(clusterer, store, asset: "p\(i)", [vector(0, Float(i) * 0.1)])
            stored.append(contentsOf: added)
        }
        let original = try #require(await clusterIDs(clusterer, ["p0"]).first ?? nil)

        try await clusterer.reject([stored[3].id], from: original)
        let moved = await clusterIDs(clusterer, ["p3"]).first ?? nil
        #expect(moved != nil && moved != original)
        #expect(await clusterer.members(of: original).count == 3)

        let reloaded = SubjectClusterer(store: store)
        try await reloaded.load()
        #expect(await clusterIDs(reloaded, ["p0", "p3"]) == [original, moved])

        // 거절한 뒤 새로 들어온 비슷한 얼굴은 원래 그룹으로 가야 합니다.
        try await add(reloaded, store, asset: "p4", [vector(0, 0.05)])
        #expect(await clusterIDs(reloaded, ["p4"]).first == original)
    }

    @Test func sameNameMergesGroupsAndSearchesByName() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        try await add(clusterer, store, asset: "front", [vector(0)])
        try await add(clusterer, store, asset: "side", [vector(1)])
        try await add(clusterer, store, asset: "dad", [vector(2)])
        let ids = await clusterIDs(clusterer, ["front", "side", "dad"]).compactMap { $0 }

        try await clusterer.rename(ids[0], to: "엄마")
        let merged = try await clusterer.rename(ids[1], to: " 엄마 ")
        try await clusterer.rename(ids[2], to: "아빠")

        #expect(merged == ids[0])
        #expect(await clusterIDs(clusterer, ["side"]).first == ids[0])
        #expect(await clusterer.names() == ["아빠", "엄마"])
        #expect(await clusterer.assetIDs(named: ["엄마"]) == ["front", "side"])
        #expect(await clusterer.assetIDs(named: ["엄마", "아빠"]).isEmpty)

        try await add(clusterer, store, asset: "family", [vector(0, 0.1), vector(2, 0.1)])
        #expect(await clusterer.assetIDs(named: ["엄마", "아빠"]) == ["family"])
    }

    @Test func namingOneSubjectMovesItOutOfWrongGroup() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        try await add(clusterer, store, asset: "a", [vector(0)])
        let wrong = try await add(clusterer, store, asset: "b", [vector(0, 0.3)])
        try await add(clusterer, store, asset: "c", [vector(3)])
        let ids = await clusterIDs(clusterer, ["a", "c"]).compactMap { $0 }
        try await clusterer.rename(ids[0], to: "이모")
        try await clusterer.rename(ids[1], to: "고모")

        let target = try await clusterer.name(subject: wrong[0].id, as: "고모")
        #expect(target == ids[1])
        let entry = try #require(await clusterer.subjects(inAsset: "b").first)
        #expect(entry.name == "고모")
        #expect(entry.subject.assignment == .confirmed)
        #expect(await clusterer.assetIDs(named: ["이모"]) == ["a"])
    }

    @Test func removingAssetsDropsEmptyGroups() async throws {
        let store = try store()
        let clusterer = SubjectClusterer(store: store)
        try await add(clusterer, store, asset: "only", [vector(0)])
        let clusterID = try #require(await clusterIDs(clusterer, ["only"]).first ?? nil)
        try await clusterer.rename(clusterID, to: "초코")

        try await clusterer.remove(assetIDs: ["only"])
        try store.delete(assetIDs: ["only"])
        #expect(await clusterer.names().isEmpty)
        #expect(try store.loadClusters().isEmpty)
    }
}

struct SubjectStoreTests {
    @Test func savesSubjectsAndCascadesOnDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try IndexStore(url: directory.appending(path: "index.sqlite"))
        let vector = [Float](repeating: 0.1, count: CLIPEncoder.dimension)
        let face = DetectedSubject(species: .person, box: CGRect(x: 0.25, y: 0.5, width: 0.125, height: 0.25), quality: 0.7, vector: vector)

        let stored = try store.saveSubjects(assetID: "a", model: "m", subjects: [face, face])
        try store.saveSubjects(assetID: "empty", model: "m", subjects: [])
        #expect(stored.count == 2)
        #expect(try store.subjectScannedAssetIDs(model: "m") == ["a", "empty"])
        #expect(try store.subjectScannedAssetIDs(model: "other").isEmpty)

        var loaded: [StoredSubject] = []
        try store.forEachSubject(dimension: CLIPEncoder.dimension) { subject, _ in loaded.append(subject) }
        #expect(loaded.map(\.box) == [face.box, face.box])

        // 다시 분석하면 이전 결과를 대체합니다.
        try store.saveSubjects(assetID: "a", model: "m", subjects: [face])
        #expect(try store.subjectVectors(ids: stored.map(\.id), dimension: CLIPEncoder.dimension).isEmpty)

        try store.delete(assetIDs: ["a", "empty"])
        loaded = []
        try store.forEachSubject(dimension: CLIPEncoder.dimension) { subject, _ in loaded.append(subject) }
        #expect(loaded.isEmpty)
        #expect(try store.subjectScannedAssetIDs(model: "m").isEmpty)
    }
}

struct SubjectSearchTests {
    @Test func searchIndexRestrictsToAssets() async {
        let index = SearchIndex()
        var v = [Float](repeating: 0, count: CLIPEncoder.dimension)
        v[0] = 1
        for (id, score) in [("a", Float(0.9)), ("b", 0.8), ("c", 0.7)] {
            var scaled = v
            scaled[0] = score
            await index.add(assetID: id, kind: .photo, frames: [FrameEmbedding(time: 0, vector: scaled)])
        }
        #expect(await index.search(v, kind: nil, assets: ["b", "c"], limit: 10).map(\.assetID) == ["b", "c"])
        #expect(await index.search(v, kind: nil, assets: [], limit: 10).isEmpty)
    }

    @Test func extractsNamesWithParticles() {
        let parsed = QueryParser.parse("초코랑 엄마가 산책하는 동영상", names: ["엄마", "초코"])
        #expect(parsed.names == ["초코", "엄마"])
        #expect(parsed.text == "산책하는")
        #expect(parsed.kind == .video)
    }

    @Test func nameOnlyQueryLeavesNoText() {
        let parsed = QueryParser.parse("초코 사진", names: ["초코"])
        #expect(parsed.names == ["초코"])
        #expect(parsed.text.isEmpty)
        #expect(parsed.kind == .photo)
    }

    @Test func ignoresNameInsideOtherWords() {
        let parsed = QueryParser.parse("초코칩 쿠키", names: ["초코"])
        #expect(parsed.names.isEmpty)
        #expect(parsed.text == "초코칩 쿠키")
    }

    @Test func matchesEnglishNamesCaseInsensitively() {
        let parsed = QueryParser.parse("max playing fetch", names: ["Max"])
        #expect(parsed.names == ["Max"])
        #expect(parsed.text == "playing fetch")
    }
}
