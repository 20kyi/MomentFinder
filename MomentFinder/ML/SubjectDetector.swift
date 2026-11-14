import CoreGraphics
import Foundation
import ImageIO
import Vision

/// 한 장의 이미지에서 얼굴과 개·고양이를 찾아 개체 구분용 벡터를 만듭니다.
/// 얼굴은 정렬 후 얼굴 인식 모델로, 반려동물은 잘라낸 부분을 CLIP 이미지 인코더로 임베딩합니다.
final class SubjectDetector: @unchecked Sendable {
    /// 짧은 변이 이보다 작은 얼굴은 신원을 구분하기에 정보가 부족합니다(1024px 분석 이미지 기준).
    static let minimumFaceSide: CGFloat = 40
    static let minimumPetSide: CGFloat = 64
    /// Vision 의 얼굴 촬영 품질(0~1). 흐리거나 많이 돌아간 얼굴은 0.2 아래로 나와 군집을 흐트러뜨립니다.
    static let minimumFaceQuality: Float = 0.2
    static let minimumPetConfidence: Float = 0.5

    private let faceEncoder: FaceEncoder?
    private let clipEncoder: CLIPEncoder

    /// 얼굴 모델이 나중에 추가되면 이미 분석한 에셋도 다시 분석하도록 분석 버전에 포함합니다.
    var modelTag: String { faceEncoder == nil ? "subjects-v1" : "subjects-v1+\(FaceEncoder.modelName)" }
    var recognizesFaces: Bool { faceEncoder != nil }

    init(faceEncoder: FaceEncoder?, clipEncoder: CLIPEncoder) {
        self.faceEncoder = faceEncoder
        self.clipEncoder = clipEncoder
    }

    /// Vision 이 실패하면 nil, 아무것도 없으면 빈 배열을 돌려줍니다.
    func analyze(image: CGImage, orientation: CGImagePropertyOrientation) async -> [DetectedSubject]? {
        guard let upright = UprightImage.make(image, orientation: orientation) else { return nil }
        let size = CGSize(width: upright.width, height: upright.height)

        let faceRequest = VNDetectFaceLandmarksRequest()
        let animalRequest = VNRecognizeAnimalsRequest()
        Self.prepare(faceRequest)
        Self.prepare(animalRequest)
        let handler = VNImageRequestHandler(cgImage: upright, options: [:])
        do {
            try handler.perform(faceEncoder == nil ? [animalRequest] : [faceRequest, animalRequest])
        } catch {
            return nil
        }

        var subjects: [DetectedSubject] = []
        if let faceEncoder {
            let faces = (faceRequest.results ?? []).filter {
                min($0.boundingBox.width * size.width, $0.boundingBox.height * size.height) >= Self.minimumFaceSide
            }
            let qualities = faceQualities(faces, handler: handler)
            for (face, quality) in zip(faces, qualities) where quality >= Self.minimumFaceQuality {
                guard let points = Self.fivePoints(face, size: size),
                      let aligned = FaceAligner.alignedFace(from: upright, landmarks: points),
                      let vector = try? await faceEncoder.embed(alignedFace: aligned) else { continue }
                subjects.append(DetectedSubject(species: .person, box: Self.topLeftBox(face.boundingBox), quality: quality, vector: vector))
            }
        }

        for animal in animalRequest.results ?? [] {
            guard let label = animal.labels.first, label.confidence >= Self.minimumPetConfidence,
                  min(animal.boundingBox.width * size.width, animal.boundingBox.height * size.height) >= Self.minimumPetSide else { continue }
            let species: Species
            switch label.identifier {
            case VNAnimalIdentifier.dog.rawValue: species = .dog
            case VNAnimalIdentifier.cat.rawValue: species = .cat
            default: continue
            }
            let box = Self.topLeftBox(animal.boundingBox)
            guard let crop = UprightImage.squareCrop(upright, box: box, padding: 0.15),
                  let vector = try? await clipEncoder.embed(image: crop) else { continue }
            subjects.append(DetectedSubject(species: species, box: box, quality: label.confidence, vector: vector))
        }
        return subjects
    }

    private func faceQualities(_ faces: [VNFaceObservation], handler: VNImageRequestHandler) -> [Float] {
        guard !faces.isEmpty else { return [] }
        let request = VNDetectFaceCaptureQualityRequest()
        request.inputFaceObservations = faces
        Self.prepare(request)
        guard (try? handler.perform([request])) != nil, let results = request.results, results.count == faces.count else {
            return faces.map { _ in 0 }
        }
        let byID = Dictionary(results.map { ($0.uuid, $0.faceCaptureQuality ?? 0) }, uniquingKeysWith: { first, _ in first })
        return faces.enumerated().map { index, face in byID[face.uuid] ?? results[index].faceCaptureQuality ?? 0 }
    }

    /// 시뮬레이터에서는 Vision 이 GPU·뉴럴 엔진 추론 컨텍스트를 만들지 못해("Could not create inference context") CPU 로 돌립니다.
    /// 이 경로의 얼굴 랜드마크는 부정확해서 시뮬레이터의 인물 구분 결과는 참고용입니다. 정확도는 실기기나 macOS 에서 확인해야 합니다.
    static func prepare(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        guard let devices = try? request.supportedComputeStageDevices else { return }
        for (stage, candidates) in devices {
            if let cpu = candidates.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }

    /// Vision 은 왼쪽 아래 원점이라 저장·표시에 쓰는 왼쪽 위 원점으로 바꿉니다.
    static func topLeftBox(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// FaceAligner.template 순서(이미지에서 보이는 왼쪽 눈, 오른쪽 눈, 코끝, 왼쪽 입꼬리, 오른쪽 입꼬리)의 픽셀 좌표.
    /// 고개가 기울어도 맞도록 좌우는 이미지 x 가 아니라 눈→입 방향을 기준으로 정합니다.
    static func fivePoints(_ face: VNFaceObservation, size: CGSize) -> [CGPoint]? {
        guard let landmarks = face.landmarks else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        guard var firstEye = centroid(points(landmarks.leftPupil).isEmpty ? points(landmarks.leftEye) : points(landmarks.leftPupil)),
              var secondEye = centroid(points(landmarks.rightPupil).isEmpty ? points(landmarks.rightEye) : points(landmarks.rightPupil)) else { return nil }
        let lips = points(landmarks.outerLips)
        guard lips.count >= 2, let mouthCenter = centroid(lips) else { return nil }

        let eyeCenter = CGPoint(x: (firstEye.x + secondEye.x) / 2, y: (firstEye.y + secondEye.y) / 2)
        let down = CGPoint(x: mouthCenter.x - eyeCenter.x, y: mouthCenter.y - eyeCenter.y)
        var across = CGPoint(x: secondEye.x - firstEye.x, y: secondEye.y - firstEye.y)
        if across.x * down.y - across.y * down.x < 0 {
            swap(&firstEye, &secondEye)
            across = CGPoint(x: -across.x, y: -across.y)
        }

        let crest = points(landmarks.noseCrest)
        let noseTip = crest.max { project($0, down) < project($1, down) } ?? centroid(points(landmarks.nose))
        guard let noseTip,
              let leftMouth = lips.min(by: { project($0, across) < project($1, across) }),
              let rightMouth = lips.max(by: { project($0, across) < project($1, across) }) else { return nil }
        return [firstEye, secondEye, noseTip, leftMouth, rightMouth]
    }

    private static func project(_ point: CGPoint, _ axis: CGPoint) -> CGFloat {
        point.x * axis.x + point.y * axis.y
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        return points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }
    }
}
