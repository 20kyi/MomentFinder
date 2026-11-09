import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// 눈·코·입꼬리 5점을 ArcFace 기준 좌표에 맞추는 닮음 변환(회전·균등 확대·이동)으로 112x112 얼굴 이미지를 만듭니다.
/// 얼굴 인식 모델은 이 기준 배치로 학습되어 있어서 정렬하지 않으면 같은 사람도 다른 벡터가 나옵니다.
enum FaceAligner {
    static let side = 112

    /// 112x112 이미지 안의 기준점. 왼쪽 눈, 오른쪽 눈, 코끝, 왼쪽 입꼬리, 오른쪽 입꼬리 순서(이미지에서 보이는 좌우, y 는 아래로 증가).
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// 최소제곱 닮음 변환. 반사는 허용하지 않습니다.
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)
        let sourceMean = source.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }
        let targetMean = target.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }

        var dotSum: CGFloat = 0, crossSum: CGFloat = 0, norm: CGFloat = 0
        for (s, t) in zip(source, target) {
            let sx = s.x - sourceMean.x, sy = s.y - sourceMean.y
            let tx = t.x - targetMean.x, ty = t.y - targetMean.y
            dotSum += sx * tx + sy * ty
            crossSum += sx * ty - sy * tx
            norm += sx * sx + sy * sy
        }
        guard norm > 0 else { return nil }
        let a = dotSum / norm, b = crossSum / norm
        return CGAffineTransform(
            a: a, b: b, c: -b, d: a,
            tx: targetMean.x - (a * sourceMean.x - b * sourceMean.y),
            ty: targetMean.y - (b * sourceMean.x + a * sourceMean.y)
        )
    }

    /// landmarks 는 image 의 픽셀 좌표(왼쪽 위 원점)이고 template 과 같은 순서입니다. 결과는 얼굴 인식 모델 입력용 BGRA 버퍼입니다.
    static func alignedFace(from image: CGImage, landmarks: [CGPoint]) -> CVPixelBuffer? {
        guard let toTemplate = similarity(from: landmarks, to: template) else { return nil }

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // CoreGraphics 는 y 가 위로 증가하므로 원본과 결과 모두 y 를 뒤집어 픽셀 좌표계에서 계산한 변환을 적용합니다.
        let height = CGFloat(image.height)
        let sourceFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let targetFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        context.interpolationQuality = .high
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.concatenate(sourceFlip.concatenating(toTemplate).concatenating(targetFlip))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

enum UprightImage {
    /// EXIF 방향을 반영해 똑바로 세운 이미지를 만듭니다. 이후 좌표 계산을 단순하게 하려고 분석 전에 한 번만 그립니다.
    static func make(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let source = CGSize(width: image.width, height: image.height)
        let transposed = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let size = transposed ? CGSize(width: source.height, height: source.width) : source
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.concatenate(CLIPEncoder.transform(for: orientation, size: source))
        context.draw(image, in: CGRect(origin: .zero, size: source))
        return context.makeImage()
    }

    /// 0~1 좌표(왼쪽 위 원점)의 box 를 감싸는 정사각형으로 넓혀 자릅니다. 이미지 밖으로 나가는 부분은 안쪽으로 밀어 넣습니다.
    static func squareCrop(_ image: CGImage, box: CGRect, padding: CGFloat) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let side = min(max(box.width * width, box.height * height) * (1 + padding), min(width, height))
        guard side >= 1 else { return nil }
        let x = min(max(box.midX * width - side / 2, 0), width - side)
        let y = min(max(box.midY * height - side / 2, 0), height - side)
        return image.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral)
    }
}
