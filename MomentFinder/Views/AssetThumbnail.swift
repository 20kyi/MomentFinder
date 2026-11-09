import Photos
import SwiftUI

struct AssetThumbnail: View {
    let item: ResultItem
    /// 작은 썸네일 줄에 쓸 때는 정사각형을 고집하지 않고, 동영상 표시도 아이콘만 남깁니다.
    var compact = false
    @State private var image: PlatformImage?

    var body: some View {
        placeholder
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.hit.kind == .video && compact {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .padding(3)
                } else if item.hit.kind == .video {
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

    @ViewBuilder
    private var placeholder: some View {
        if compact {
            Color.secondary.opacity(0.15)
        } else {
            Color.secondary.opacity(0.15).aspectRatio(1, contentMode: .fit)
        }
    }
}

enum TimeFormatter {
    static func string(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
