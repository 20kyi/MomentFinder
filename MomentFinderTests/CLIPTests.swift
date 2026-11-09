import CoreGraphics
import CoreML
import Foundation
import ImageIO
import SQLite3
import Testing
import Vision
@testable import MomentFinder

struct CLIPTokenizerTests {
    @Test func encodesLikeOpenAICLIP() throws {
        let tokenizer = try CLIPTokenizer(bundle: .main)
        let tokens = tokenizer.encode("A photo of a  CAT")

        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(Array(tokens.prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407])
        #expect(tokens.dropFirst(7).allSatisfy { $0 == 0 })
    }

    @Test func truncatesLongText() throws {
        let tokenizer = try CLIPTokenizer(bundle: .main)
        let tokens = tokenizer.encode(String(repeating: "cat ", count: 200))

        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(tokens.last == CLIPTokenizer.endToken)
    }
}

struct CLIPEncoderTests {
    private static let encoder = Result { try CLIPEncoder() }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    @Test func textEmbeddingsAreSemantic() throws {
        let encoder = try Self.encoder.get()
        let cat = try encoder.embed(text: "a photo of a cat")
        let kitten = try encoder.embed(text: "a photo of a kitten")
        let truck = try encoder.embed(text: "a photo of a truck")

        #expect(abs(dot(cat, cat) - 1) < 1e-3)
        #expect(dot(cat, kitten) > dot(cat, truck))
    }

    /// 채널 순서(RGB/BGR)나 전처리가 틀리면 빨강/파랑이 뒤바뀌므로 이미지 파이프라인 검증용으로 씁니다.
    @Test func imageEmbeddingMatchesColor() async throws {
        let encoder = try Self.encoder.get()
        let red = try await encoder.embed(image: Self.solidImage(red: 1, green: 0, blue: 0))
        let redText = try encoder.embed(text: "a plain red image")
        let blueText = try encoder.embed(text: "a plain blue image")

        #expect(dot(red, redText) > dot(red, blueText))
    }

    @Test func searchIndexRanksBestFramePerAsset() async throws {
        let encoder = try Self.encoder.get()
        let index = SearchIndex()
        let red = try await encoder.embed(image: Self.solidImage(red: 1, green: 0, blue: 0))
        let blue = try await encoder.embed(image: Self.solidImage(red: 0, green: 0, blue: 1))
        await index.add(assetID: "video", kind: .video, frames: [
            FrameEmbedding(time: 0, vector: blue),
            FrameEmbedding(time: 5, vector: red),
        ])
        await index.add(assetID: "photo", kind: .photo, frames: [FrameEmbedding(time: 0, vector: blue)])

        let hits = await index.search(try encoder.embed(text: "a plain red image"), kind: nil, limit: 10)
        #expect(hits.first?.assetID == "video")
        #expect(hits.first?.time == 5)

        let photosOnly = await index.search(try encoder.embed(text: "a plain red image"), kind: .photo, limit: 10)
        #expect(photosOnly.map(\.assetID) == ["photo"])
    }

    /// 직접 구현한 전처리(회전·축소·센터 크롭)가 Core ML 의 이미지 전처리와 같은 임베딩을 내는지 확인합니다.
    @Test(arguments: [
        CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored,
        .left, .leftMirrored, .right, .rightMirrored,
    ])
    func preprocessingMatchesCoreML(orientation: CGImagePropertyOrientation) async throws {
        let encoder = try Self.encoder.get()
        let image = Self.asymmetricImage()

        let ours = try await encoder.embed(image: image, orientation: orientation)
        let reference = try Self.coreMLEmbedding(image, orientation: orientation)
        let upright = try Self.coreMLEmbedding(image, orientation: .up)

        #expect(dot(ours, reference) > 0.99)
        if orientation != .up {
            #expect(dot(ours, reference) > dot(ours, upright))
        }
    }

    private static func coreMLEmbedding(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> [Float] {
        let url = try #require(Bundle.main.url(forResource: "\(CLIPEncoder.modelName)_image", withExtension: "mlmodelc"))
        let model = try MLModel(contentsOf: url)
        let constraint = try #require(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        let value = try MLFeatureValue(
            cgImage: image,
            orientation: orientation,
            constraint: constraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        )
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
        let array = try #require(output.featureValue(for: "final_emb_1")?.multiArrayValue)
        return CLIPEncoder.normalized((0..<array.count).map { array[$0].floatValue })
    }

    /// 가로로 긴 이미지에 위치마다 다른 색을 칠해, 회전·반전·크롭 위치가 틀리면 임베딩이 달라지게 합니다.
    private static func asymmetricImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 80, y: 200, width: 160, height: 120))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 80, y: 0, width: 320, height: 60))
        context.setFillColor(red: 0, green: 0.7, blue: 0, alpha: 1)
        context.move(to: CGPoint(x: 400, y: 320))
        context.addLine(to: CGPoint(x: 400, y: 120))
        context.addLine(to: CGPoint(x: 260, y: 320))
        context.fillPath()
        return context.makeImage()!
    }

    private static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        return context.makeImage()!
    }
}

struct SearchIndexTests {
    private func axis(_ i: Int, _ weight: Float = 1) -> [Float] {
        var v = [Float](repeating: 0, count: CLIPEncoder.dimension)
        v[i] = weight
        return v
    }

    @Test func limitKeepsHighestScoresInOrder() async {
        let index = SearchIndex()
        for i in 0..<50 {
            await index.add(assetID: "a\(i)", kind: .photo, frames: [FrameEmbedding(time: 0, vector: axis(0, Float(i) / 50))])
        }
        let hits = await index.search(axis(0), kind: nil, limit: 5)
        #expect(hits.map(\.assetID) == ["a49", "a48", "a47", "a46", "a45"])
    }

    @Test func minScoreDropsWeakMatches() async {
        let index = SearchIndex()
        for i in 0..<10 {
            await index.add(assetID: "a\(i)", kind: .photo, frames: [FrameEmbedding(time: 0, vector: axis(0, Float(i) / 10))])
        }
        let hits = await index.search(axis(0), kind: nil, minScore: 0.75, limit: 120)
        #expect(hits.map(\.assetID) == ["a9", "a8"])
    }

    @Test func removeAndReAddKeepRowsConsistent() async {
        let index = SearchIndex()
        await index.add(assetID: "a", kind: .photo, frames: [FrameEmbedding(time: 0, vector: axis(0))])
        await index.add(assetID: "b", kind: .video, frames: [
            FrameEmbedding(time: 1, vector: axis(1)),
            FrameEmbedding(time: 2, vector: axis(2)),
        ])
        await index.add(assetID: "c", kind: .photo, frames: [FrameEmbedding(time: 0, vector: axis(2, 0.5))])

        await index.remove(["a"])
        #expect(await index.assetCount == 2)
        let hits = await index.search(axis(2), kind: nil, limit: 10)
        #expect(hits.map(\.assetID) == ["b", "c"])
        #expect(hits.first?.time == 2)

        await index.add(assetID: "b", kind: .video, frames: [FrameEmbedding(time: 3, vector: axis(0))])
        #expect(await index.search(axis(0), kind: .video, limit: 10).map(\.time) == [3])
        #expect(await index.search(axis(0), kind: .photo, limit: 10).map(\.assetID) == ["c"])
    }
}

struct IndexStoreTests {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "index.sqlite")
    }

    private func frame(_ time: Double) -> FrameEmbedding {
        FrameEmbedding(time: time, vector: [Float](repeating: 0.1, count: CLIPEncoder.dimension))
    }

    @Test func tracksVideosWaitingForSceneAnalysis() throws {
        let store = try IndexStore(url: temporaryURL())
        try store.save(assetID: "photo", kind: .photo, created: nil, duration: 0, model: "m", frames: [frame(0)])
        try store.save(assetID: "video", kind: .video, created: nil, duration: 30, model: "m", detail: .preview, frames: [frame(0)])

        #expect(try store.indexedAssetIDs(model: "m") == ["photo", "video"])
        #expect(try store.previewAssetIDs(model: "m") == ["video"])

        try store.save(assetID: "video", kind: .video, created: nil, duration: 30, model: "m", frames: [frame(0.5), frame(1.5)])
        #expect(try store.previewAssetIDs(model: "m").isEmpty)
        #expect(try store.loadVectors(model: "m", dimension: CLIPEncoder.dimension).count == 3)
    }

    /// detail 열이 생기기 전 DB 에서, 대표 이미지 한 장(0초)으로 분석된 동영상만 장면 분석 대상으로 바뀌어야 합니다.
    @Test func migratesOldDatabase() throws {
        let url = try temporaryURL()
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let blob = "x'" + String(repeating: "00", count: CLIPEncoder.dimension * 4) + "'"
        let sql = """
            CREATE TABLE assets (id TEXT PRIMARY KEY, kind INTEGER NOT NULL, created REAL, duration REAL NOT NULL DEFAULT 0,
                                 model TEXT NOT NULL, indexed_at REAL NOT NULL);
            CREATE TABLE vectors (asset_id TEXT NOT NULL, time REAL NOT NULL, embedding BLOB NOT NULL);
            INSERT INTO assets VALUES ('photo', 1, NULL, 0, 'm', 0), ('poster', 2, NULL, 30, 'm', 0), ('scenes', 2, NULL, 30, 'm', 0);
            INSERT INTO vectors VALUES ('photo', 0, \(blob)), ('poster', 0, \(blob)), ('scenes', 0.5, \(blob)), ('scenes', 1.5, \(blob));
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try IndexStore(url: url)
        #expect(try store.indexedAssetIDs(model: "m") == ["photo", "poster", "scenes"])
        #expect(try store.previewAssetIDs(model: "m") == ["poster"])
    }
}

struct QueryParserTests {
    @Test func extractsVideoKind() {
        let parsed = QueryParser.parse("고양이가 하품하는 동영상")
        #expect(parsed.kind == .video)
        #expect(parsed.text == "고양이가 하품하는")
    }

    @Test func extractsPhotoKindWithParticle() {
        let parsed = QueryParser.parse("내가 고양이를 안고있는 사진을 찾아줘")
        #expect(parsed.kind == .photo)
        #expect(parsed.text == "내가 고양이를 안고있는")
    }

    @Test func keepsPlainQuery() {
        let parsed = QueryParser.parse("고양이 하품")
        #expect(parsed.kind == nil)
        #expect(parsed.text == "고양이 하품")
        #expect(QueryParser.containsHangul(parsed.text))
        #expect(!QueryParser.containsHangul("cat yawning"))
    }

    @Test func englishVideoKeyword() {
        let parsed = QueryParser.parse("cat yawning video")
        #expect(parsed.kind == .video)
        #expect(parsed.text == "cat yawning")
    }
}

struct QueryGlossaryTests {
    @Test func translatesKnownWords() {
        #expect(QueryGlossary.translate("고양이 하품") == "cat yawning")
        #expect(QueryGlossary.translate("고양이가 하품하는") == "cat yawning")
        #expect(QueryGlossary.translate("고양이들이 하품하고 있는") == "cat yawning")
        #expect(QueryGlossary.translate("고양이하품") == "cat yawning")
        #expect(QueryGlossary.translate("바닷가 일몰") == "beach sunset")
        #expect(QueryGlossary.translate("생일 케이크 촛불") == "birthday cake candles")
        #expect(QueryGlossary.translate("강아지랑 산책") == "dog walking")
    }

    @Test func leavesUnknownWordsToTranslator() {
        #expect(QueryGlossary.translate("눈 오는 거리") == nil)
        #expect(QueryGlossary.translate("내가 고양이를 안고있는") == nil)
        #expect(QueryGlossary.translate("집중") == nil)
        #expect(QueryGlossary.translate("공항") == nil)
        #expect(QueryGlossary.translate("있는") == nil)
    }

    @MainActor @Test func rejectsMadeUpEnglish() {
        #expect(QueryTranslator.looksLikeEnglish("Cat yawn"))
        #expect(QueryTranslator.looksLikeEnglish("Sunset by the beach"))
        #expect(!QueryTranslator.looksLikeEnglish("cat snawn"))
        #expect(!QueryTranslator.looksLikeEnglish("고양이 yawn"))
    }
}
