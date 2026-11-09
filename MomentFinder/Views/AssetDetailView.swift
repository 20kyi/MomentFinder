import AVKit
import Photos
import SwiftUI

struct AssetDetailView: View {
    let item: ResultItem

    var body: some View {
        Group {
            if item.hit.kind == .video {
                VideoMomentView(asset: item.asset, momentTime: item.hit.time)
            } else {
                PhotoDetailView(asset: item.asset)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("일치도 \(item.hit.score, format: .number.precision(.fractionLength(3)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        guard let date = item.asset.creationDate else { return "" }
        let day = Self.dayFormatter.string(from: date)
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) \(time)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private struct PhotoDetailView: View {
    let asset: PHAsset
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            image = await PhotoLibrary.image(for: asset, side: 2048, allowNetwork: true)
        }
    }
}

/// 검색어와 가장 잘 맞는 장면 1초 전부터 재생합니다.
private struct VideoMomentView: View {
    let asset: PHAsset
    let momentTime: Double
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("동영상 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button {
                    seek(to: momentTime)
                } label: {
                    Label("찾은 장면 \(TimeFormatter.string(momentTime))", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("moment-button")
                Button {
                    seek(to: 0)
                } label: {
                    Label("처음부터", systemImage: "backward.end")
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom)
        }
        .task(id: asset.localIdentifier) {
            guard let item = await PhotoLibrary.playerItem(for: asset) else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            seek(to: momentTime)
        }
        .onDisappear { player?.pause() }
    }

    private func seek(to time: Double) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, time - 1), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }
}
