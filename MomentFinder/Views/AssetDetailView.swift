import AVKit
import Photos
import SwiftUI

/// 결과 하나를 크게 보여주고, 좌우로 넘기거나 아래 썸네일을 눌러 같은 결과 목록의 다른 항목으로 이동합니다.
struct AssetDetailView: View {
    /// 화면을 연 시점의 결과 목록. 보는 도중 분석으로 결과가 바뀌어도 순서가 흔들리지 않도록 고정합니다.
    @State private var items: [ResultItem]
    @State private var currentID: String?
    @State private var width: CGFloat = 0
    /// 사진 앱처럼 화면을 탭하면 위아래 UI를 숨기고 배경을 검게 바꿉니다.
    @State private var chromeHidden = false
    /// 마지막으로 화면에 보인 동영상의 재생 상태. 지금 결과가 그 동영상일 때만 컨트롤을 띄웁니다.
    @State private var activePlayback: VideoPlayback?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var hidesChrome: Bool { chromeHidden && !voiceOverEnabled }

    init(item: ResultItem, in items: [ResultItem] = []) {
        _items = State(initialValue: items.contains { $0.id == item.id } ? items : [item])
        _currentID = State(initialValue: item.id)
    }

    private var item: ResultItem {
        items.first { $0.id == currentID } ?? items[0]
    }

    private var currentPlayback: VideoPlayback? {
        guard item.hit.kind == .video, let activePlayback, activePlayback.assetID == item.id,
              activePlayback.player != nil else { return nil }
        return activePlayback
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        page(item)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .scrollDisabled(items.count < 2)
            // scrollPosition 의 처음 값만으로는 첫 페이지에 머물러서, 너비가 정해지거나 바뀔 때마다 선택된 결과로 맞춥니다.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: width) {
                if let currentID { proxy.scrollTo(currentID) }
            }
        }
        // 위아래 UI를 보이거나 숨겨도 사진·동영상의 크기와 위치가 그대로이도록 항상 전체 화면 기준으로 배치하고, UI 는 그 위에 겹칩니다.
        .ignoresSafeArea()
        .background {
            if hidesChrome { Color.black.ignoresSafeArea() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !hidesChrome {
                VStack(spacing: 0) {
                    if let currentPlayback {
                        VideoControls(playback: currentPlayback)
                            .transition(.opacity)
                    }
                    if items.count > 1 {
                        ResultStrip(items: items, currentID: $currentID)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: currentPlayback == nil)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(hidesChrome ? .hidden : .automatic, for: .navigationBar, .bottomBar)
        .statusBarHidden(hidesChrome)
        #endif
        .toolbar {
            if let score = item.hit.score {
                ToolbarItem(placement: .primaryAction) {
                    Text("일치도 \(score, format: .number.precision(.fractionLength(3)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: Self.actionsPlacement) {
                AssetShareLink(item: item)
                #if os(iOS)
                Spacer()
                #endif
                FavoriteButton(item: item)
                #if os(iOS)
                Spacer()
                #endif
                if let currentPlayback {
                    ClipMenu(playback: currentPlayback)
                    #if os(iOS)
                    Spacer()
                    #endif
                }
                Button("삭제", systemImage: "trash", role: .destructive) {
                    Task { await model.delete([item]) }
                }
                .accessibilityIdentifier("delete-button")
            }
        }
        .onChange(of: model.libraryRevision) { refetchItems() }
    }

    #if os(iOS)
    private static let actionsPlacement = ToolbarItemPlacement.bottomBar
    #else
    private static let actionsPlacement = ToolbarItemPlacement.primaryAction
    #endif

    /// 즐겨찾기 변경을 반영하고, 지워진 항목은 빼고 바로 다음(마지막이었다면 이전) 결과로 넘어갑니다. 남은 게 없으면 닫습니다.
    private func refetchItems() {
        let refetched = ResultItem.refetched(items)
        guard refetched != items else { return }
        guard !refetched.isEmpty else {
            dismiss()
            return
        }
        let remaining = Set(refetched.map(\.id))
        if let currentID, !remaining.contains(currentID), let index = items.firstIndex(where: { $0.id == currentID }) {
            self.currentID = items[index...].first { remaining.contains($0.id) }?.id
                ?? items[..<index].last { remaining.contains($0.id) }?.id
        }
        items = refetched
    }

    @ViewBuilder
    private func page(_ item: ResultItem) -> some View {
        let isActive = item.id == currentID
        let toggleChrome = { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
        Group {
            if item.hit.kind == .video {
                VideoMomentView(asset: item.asset, momentTime: item.hit.time, isActive: isActive,
                                onTap: toggleChrome, activePlayback: $activePlayback)
            } else {
                PhotoDetailView(asset: item.asset, onTap: toggleChrome)
            }
        }
        .accessibilityHidden(!isActive)
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

/// 같은 검색 결과를 작은 썸네일로 늘어놓은 줄. 선택된 결과는 항상 가운데에 고정되고,
/// 직접 넘기면 가운데에 닿은 결과로 한 칸씩 넘어갑니다.
private struct ResultStrip: View {
    let items: [ResultItem]
    @Binding var currentID: String?
    @State private var width: CGFloat = 0
    @State private var isUserScrolling = false
    /// 줄 가운데가 첫 칸 가운데에서 얼마나 떨어져 있는지. 스크롤한 만큼 썸네일을 되돌려 선택 항목을 가운데에 묶어 둡니다.
    @State private var scrollX: CGFloat = 0

    /// 가운데 항목을 위치로 계산하므로 모든 칸의 너비가 같아야 합니다.
    /// 선택된 썸네일은 칸보다 크게 그리고, 양옆은 offset 으로만 밀어내 배치는 그대로 둡니다.
    private static let cellWidth: CGFloat = 32
    private static let spacing: CGFloat = 2
    private static let step = cellWidth + spacing
    private static let height: CGFloat = 38

    var body: some View {
        let selectedIndex = items.firstIndex { $0.id == currentID }
        let push = selectedIndex == nil ? 0 : (Self.height - Self.cellWidth) / 2 + 3
        let pin = selectedIndex.map { scrollX - CGFloat($0) * Self.step } ?? 0

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        cell(item)
                            .offset(x: pin + (selectedIndex.map { index < $0 ? -push : index > $0 ? push : 0 } ?? 0))
                    }
                }
                .animation(.snappy(duration: 0.2), value: currentID)
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentMargins(.horizontal, max(0, (width - Self.cellWidth) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.midX - Self.cellWidth / 2
            } action: { _, x in
                scrollX = x
                guard isUserScrolling, !items.isEmpty else { return }
                let index = min(max(Int((x / Self.step).rounded()), 0), items.count - 1)
                if items[index].id != currentID { currentID = items[index].id }
            }
            .onChange(of: width) { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) {
                guard !isUserScrolling else { return }
                withAnimation { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: currentID) { _, _ in isUserScrolling }
    }

    private func cell(_ item: ResultItem) -> some View {
        let selected = item.id == currentID
        return Button {
            withAnimation { currentID = item.id }
        } label: {
            let side = selected ? Self.height : Self.cellWidth
            AssetThumbnail(item: item, compact: true)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .opacity(selected ? 1 : 0.7)
                .frame(width: Self.cellWidth, height: Self.height)
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityIdentifier("detail-strip-item")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 사진·동영상을 그릴 크기. 화면보다 세로로 긴 것은 양옆에 여백이 생기지 않도록 너비를 꽉 채우고 위아래를 잘라냅니다.
/// 화면보다 가로로 긴 것은 잘리지 않게 원본 비율 그대로 너비에 맞춥니다.
private func mediaFrame(for asset: PHAsset, in container: CGSize) -> CGSize {
    guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return container }
    let ratio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    return CGSize(width: container.width, height: min(container.height, container.width / ratio))
}

private struct PhotoDetailView: View {
    let asset: PHAsset
    let onTap: () -> Void
    @State private var image: PlatformImage?
    @State private var containerSize: CGSize = .zero

    var body: some View {
        ZStack {
            if let image {
                let frame = mediaFrame(for: asset, in: containerSize)
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .task(id: asset.localIdentifier) {
            image = await PhotoLibrary.image(for: asset, side: 2048, allowNetwork: true)
        }
    }
}

/// 동영상 한 개의 재생 상태. 화면은 페이지 안에서 그리고, 컨트롤은 썸네일 줄 위에서 같은 상태를 씁니다.
@MainActor @Observable
private final class VideoPlayback {
    enum ClipState { case idle, saving, saved }

    let asset: PHAsset
    var assetID: String { asset.localIdentifier }
    /// 검색어와 가장 잘 맞는 장면. 1초 전부터 재생합니다.
    let momentTime: Double
    var clipState = ClipState.idle
    var player: AVPlayer?
    /// 옆 페이지로 미리 불러온 동영상은 불러온 뒤에도 재생하지 않습니다.
    var playsWhenReady = false
    var isPlaying = false
    var isMuted = false
    var isScrubbing = false
    var currentTime: Double = 0
    var duration: Double = 0
    var frames: [PlatformImage] = []

    init(asset: PHAsset, momentTime: Double) {
        self.asset = asset
        self.momentTime = momentTime
    }

    func load(_ asset: PHAsset) async {
        guard let item = await PhotoLibrary.playerItem(for: asset) else { return }
        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        self.player = player
        play(from: momentTime - 1, autoplay: playsWhenReady)
        while !Task.isCancelled {
            if !isScrubbing { currentTime = player.currentTime().seconds }
            isPlaying = player.timeControlStatus != .paused
            if item.duration.isNumeric { duration = item.duration.seconds }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func play(from time: Double, autoplay: Bool = true) {
        guard let player else { return }
        let target = max(0, time)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            if autoplay { player.play() }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if duration > 0, currentTime >= duration - 0.1 {
            play(from: 0)
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }
}

/// 동영상 화면만 그립니다. 재생 컨트롤은 썸네일 줄에 가리지 않도록 AssetDetailView 가 그 위에 따로 둡니다.
private struct VideoMomentView: View {
    let asset: PHAsset
    /// 지금 화면에 보이는 페이지인지. 보이는 동안에만 재생하고 컨트롤에 자기 재생 상태를 넘깁니다.
    let isActive: Bool
    let onTap: () -> Void
    @Binding var activePlayback: VideoPlayback?
    @State private var playback: VideoPlayback
    @State private var containerSize: CGSize = .zero

    init(asset: PHAsset, momentTime: Double, isActive: Bool, onTap: @escaping () -> Void, activePlayback: Binding<VideoPlayback?>) {
        self.asset = asset
        self.isActive = isActive
        self.onTap = onTap
        _activePlayback = activePlayback
        _playback = State(initialValue: VideoPlayback(asset: asset, momentTime: momentTime))
    }

    var body: some View {
        ZStack {
            if let player = playback.player {
                let frame = mediaFrame(for: asset, in: containerSize)
                PlayerSurface(player: player)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
            } else {
                ProgressView("동영상 불러오는 중…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .task(id: asset.localIdentifier) { await playback.load(asset) }
        .task(id: asset.localIdentifier) {
            playback.frames = await PhotoLibrary.filmstrip(for: asset, count: 10, side: 120)
        }
        .onChange(of: isActive, initial: true) {
            playback.playsWhenReady = isActive
            if isActive {
                activePlayback = playback
                playback.play(from: playback.momentTime - 1)
            } else {
                playback.player?.pause()
            }
        }
        .onDisappear { playback.player?.pause() }
    }
}

/// 사진 앱처럼 재생 버튼 · 장면 미리보기 재생바 · 소리 버튼을 유리 질감의 한 줄로 띄웁니다.
private struct VideoControls: View {
    let playback: VideoPlayback

    private static let barHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    playback.play(from: playback.momentTime - 1)
                } label: {
                    Label("찾은 장면 \(TimeFormatter.string(playback.momentTime))", systemImage: "scope")
                }
                .glassButtonStyle(prominent: true)
                .accessibilityIdentifier("moment-button")
                Button {
                    playback.play(from: 0)
                } label: {
                    Label("처음부터", systemImage: "backward.end")
                }
                .glassButtonStyle(prominent: false)
            }
            .buttonBorderShape(.capsule)

            HStack(spacing: 8) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Label(playback.isPlaying ? "일시정지" : "재생", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: Self.barHeight, height: Self.barHeight)
                        .contentShape(Circle())
                }
                .glassBackground(Circle())
                .accessibilityIdentifier("play-pause-button")

                Filmstrip(frames: playback.frames,
                          progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                          scrubTime: playback.isScrubbing ? playback.currentTime : nil) { fraction, ended in
                    playback.isScrubbing = !ended
                    playback.seek(to: fraction * playback.duration)
                }
                .padding(4)
                .frame(height: Self.barHeight)
                .glassBackground(Capsule())
                .accessibilityRepresentation {
                    Slider(value: Binding { playback.currentTime } set: { playback.seek(to: $0) },
                           in: 0...max(playback.duration, 0.1)) { Text("재생 위치") }
                }

                Button {
                    playback.toggleMute()
                } label: {
                    Label(playback.isMuted ? "소리 켜기" : "소리 끄기", systemImage: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: Self.barHeight, height: Self.barHeight)
                        .contentShape(Circle())
                }
                .glassBackground(Circle())
                .accessibilityIdentifier("mute-button")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// 찾은 장면을 가운데에 두고 고른 길이만큼 잘라 저장하는 메뉴. 동영상보다 짧은 길이만 고를 수 있습니다.
private struct ClipMenu: View {
    let playback: VideoPlayback
    @Environment(AppModel.self) private var model

    var body: some View {
        let lengths = VideoClip.lengths.filter { $0 < playback.duration }
        Menu {
            Section("찾은 장면을 가운데에 두고 ‘\(VideoClip.albumTitle)’ 앨범에 저장") {
                ForEach(lengths, id: \.self) { length in
                    Button("\(Int(length))초") { saveClip(length: length) }
                        .accessibilityIdentifier("clip-length-\(Int(length))")
                }
            }
        } label: {
            switch playback.clipState {
            case .idle: Label("클립 저장", systemImage: "scissors")
            case .saving: ProgressView().accessibilityLabel("클립 저장 중")
            case .saved: Label("클립 저장됨", systemImage: "checkmark")
            }
        }
        .disabled(lengths.isEmpty || playback.clipState == .saving)
        .accessibilityIdentifier("clip-menu")
    }

    private func saveClip(length: Double) {
        let range = VideoClip.range(around: playback.momentTime, length: length, duration: playback.duration)
        playback.clipState = .saving
        Task {
            do {
                try await VideoClip.save(from: playback.asset, range: range)
                playback.clipState = .saved
                try? await Task.sleep(for: .seconds(2))
                if playback.clipState == .saved { playback.clipState = .idle }
            } catch {
                playback.clipState = .idle
                model.errorMessage = "클립을 저장하지 못했어요. \(error.localizedDescription)"
            }
        }
    }
}

/// 동영상 장면들을 늘어놓고 흰 막대로 재생 위치를 보여주는 재생바. 끌면 그 위치로 이동합니다.
private struct Filmstrip: View {
    let frames: [PlatformImage]
    let progress: Double
    /// 끄는 동안에만 재생 위치 위에 시간을 띄웁니다.
    let scrubTime: Double?
    let onScrub: (_ fraction: Double, _ ended: Bool) -> Void

    private static let playheadWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            HStack(spacing: 0) {
                ForEach(frames.indices, id: \.self) { index in
                    Image(platformImage: frames[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width / CGFloat(frames.count), height: size.height)
                        .clipped()
                }
            }
            .frame(width: size.width, height: size.height)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white)
                    .frame(width: Self.playheadWidth, height: size.height + 4)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .overlay(alignment: .top) {
                        if let scrubTime {
                            Text(TimeFormatter.string(scrubTime))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .fixedSize()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassBackground(Capsule())
                                .offset(y: -34)
                        }
                    }
                    .offset(x: min(max(progress, 0), 1) * (size.width - Self.playheadWidth))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onScrub(fraction(of: $0.location.x, in: size.width), false) }
                    .onEnded { onScrub(fraction(of: $0.location.x, in: size.width), true) }
            )
        }
    }

    private func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }
}

private extension View {
    /// iOS 26 이상에서는 사진 앱과 같은 유리 질감을, 그 아래에서는 반투명 재질을 씁니다.
    @ViewBuilder
    func glassBackground(_ shape: some Shape) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// 컨트롤 없이 화면만 그리는 플레이어. 컨트롤은 VideoMomentView 가 직접 그립니다.
#if os(iOS)
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#else
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
#endif
