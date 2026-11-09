import CoreML
import CoreVideo
import Foundation

/// 정렬된 112x112 얼굴에서 512차원 신원 벡터를 뽑습니다(InsightFace MobileFaceNet). 출력은 L2 정규화되어 있습니다.
final class FaceEncoder: @unchecked Sendable {
    static let modelName = "face_mbf"
    static let dimension = 512

    private let model: MLModel

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            throw CLIPError.missingResource(Self.modelName)
        }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // 시뮬레이터의 GPU 경로는 이 모델에서 0 벡터를 돌려줍니다.
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        model = try MLModel(contentsOf: url, configuration: config)
    }

    func embed(alignedFace: CVPixelBuffer) async throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: alignedFace)])
        let output = try await model.prediction(from: input)
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == Self.dimension else {
            throw CLIPError.invalidOutput
        }
        return CLIPEncoder.normalized((0..<array.count).map { array[$0].floatValue })
    }
}
