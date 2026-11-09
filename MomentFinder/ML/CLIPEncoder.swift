import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO

enum CLIPError: LocalizedError {
    case missingResource(String)
    case invalidModel
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): "모델 파일을 찾을 수 없습니다: \(name). scripts/download_models.sh 를 먼저 실행하세요."
        case .invalidModel: "모델 형식이 올바르지 않습니다."
        case .invalidOutput: "모델 출력이 올바르지 않습니다."
        }
    }
}

/// MobileCLIP 이미지/텍스트 인코더. 출력 벡터는 L2 정규화되어 있어 내적이 곧 코사인 유사도입니다.
final class CLIPEncoder: @unchecked Sendable {
    static let modelName = "mobileclip_s2"
    static let dimension = 512

    private let imageModel: MLModel
    private let textModel: MLModel
    private let imageConstraint: MLImageConstraint
    private let tokenizer: CLIPTokenizer

    init(bundle: Bundle = .main) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        imageModel = try MLModel(contentsOf: Self.compiledModelURL("\(Self.modelName)_image", in: bundle), configuration: config)
        textModel = try MLModel(contentsOf: Self.compiledModelURL("\(Self.modelName)_text", in: bundle), configuration: config)
        guard let constraint = imageModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw CLIPError.invalidModel
        }
        imageConstraint = constraint
        tokenizer = try CLIPTokenizer(bundle: bundle)
    }

    func embed(image: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> [Float] {
        let input = MLFeatureValue(pixelBuffer: try pixelBuffer(from: image, orientation: orientation))
        let output = try await imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        return try Self.normalizedEmbedding(from: output)
    }

    /// 회전 보정, 짧은 변 기준 축소, 센터 크롭을 CGContext 한 번의 그리기로 처리합니다.
    /// MLFeatureValue(cgImage:constraint:options:) 와 결과는 같지만 몇 배 빠릅니다.
    func pixelBuffer(from image: CGImage, orientation: CGImagePropertyOrientation) throws -> CVPixelBuffer {
        let width = imageConstraint.pixelsWide, height = imageConstraint.pixelsHigh
        guard imageConstraint.pixelFormatType == kCVPixelFormatType_32BGRA else { throw CLIPError.invalidModel }

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw CLIPError.invalidModel }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw CLIPError.invalidModel }

        let source = CGSize(width: image.width, height: image.height)
        let transposed = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let oriented = transposed ? CGSize(width: source.height, height: source.width) : source
        let scale = max(CGFloat(width) / oriented.width, CGFloat(height) / oriented.height)

        context.interpolationQuality = .medium
        context.translateBy(x: (CGFloat(width) - oriented.width * scale) / 2, y: (CGFloat(height) - oriented.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.concatenate(Self.transform(for: orientation, size: source))
        context.draw(image, in: CGRect(origin: .zero, size: source))
        return buffer
    }

    /// 저장된 픽셀(size)을 화면 방향으로 돌리는 변환. CoreGraphics 의 y-up 좌표계 기준입니다.
    static func transform(for orientation: CGImagePropertyOrientation, size: CGSize) -> CGAffineTransform {
        let w = size.width, h = size.height
        switch orientation {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        @unknown default: return .identity
        }
    }

    func embed(text: String) throws -> [Float] {
        let tokens = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        for (i, token) in tokens.enumerated() {
            array[i] = NSNumber(value: token)
        }
        let output = try textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": array]))
        return try Self.normalizedEmbedding(from: output)
    }

    /// 여러 프롬프트의 임베딩을 평균내 한 벡터로 만듭니다 (prompt ensembling).
    func embed(texts: [String]) throws -> [Float] {
        var sum = [Float](repeating: 0, count: Self.dimension)
        for text in texts {
            sum = vDSP.add(sum, try embed(text: text))
        }
        return Self.normalized(sum)
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vDSP.sumOfSquares(vector))
        return norm > 0 ? vDSP.divide(vector, norm) : vector
    }

    private static func normalizedEmbedding(from output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "final_emb_1")?.multiArrayValue, array.count == dimension else {
            throw CLIPError.invalidOutput
        }
        return normalized((0..<array.count).map { array[$0].floatValue })
    }

    private static func compiledModelURL(_ name: String, in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw CLIPError.missingResource(name)
        }
        return url
    }
}
