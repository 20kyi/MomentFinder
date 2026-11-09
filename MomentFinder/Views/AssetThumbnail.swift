import Photos
import SwiftUI

struct AssetThumbnail: View {
    let item: ResultItem
    @State private var image: PlatformImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.hit.kind == .video {
                    Label(TimeFormatter.string(item.hit.time), systemImage: "play.fill")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .task(id: item.id) {
                if item.hit.kind == .video, let frame = await PhotoLibrary.videoFrame(for: item.asset, at: item.hit.time, side: 300) {
                    image = frame
                } else {
                    image = await PhotoLibrary.image(for: item.asset, side: 300, allowNetwork: true)
                }
            }
    }
}

enum TimeFormatter {
    static func string(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
