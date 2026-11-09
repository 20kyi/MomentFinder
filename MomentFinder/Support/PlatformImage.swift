import CoreGraphics
import ImageIO
import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension UIImage {
    convenience init(cgImageValue: CGImage) {
        self.init(cgImage: cgImageValue)
    }

    var cgImageValue: CGImage? { cgImage }

    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
#else
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension NSImage {
    convenience init(cgImageValue: CGImage) {
        self.init(cgImage: cgImageValue, size: .zero)
    }

    var cgImageValue: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    var cgOrientation: CGImagePropertyOrientation { .up }
}
#endif
