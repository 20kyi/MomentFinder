import AVKit
import Photos
import SwiftUI

/// 클립 편집 상태. 고른 구간만 반복 재생하고, 9:16 로 자를 때는 피사체 위치를 미리 분석해 둡니다.
@MainActor @Observable
final class ClipEditor {
    enum Length: Hashable {
        case scene
        case seconds(Double)
    }

    let asset: PHAsset
    let moment: Double
    let duration: Double
    private(set) var range: ClosedRange<Double>
    private(set) var scores: [FrameScore] = []
    /// 검색어와 계속 잘 맞는 구간. 장면 분석 전이거나 이름만으로 검색했으면 nil 입니다.
    private(set) var sceneRange: ClosedRange<Double>?
    private(set) var frames: [PlatformImage] = []
    private(set) var player: AVPlayer?
    /// iCloud 에서 스트리밍하다 네트워크가 끊기면 true 가 됩니다.
    private(set) var loadFailed = false
    /// 다시 시도할 때마다 올려 runPlayer 를 새로 시작합니다.
    private(set) var loadAttempt = 0
    private(set) var currentTime: Double = 0
    private(set) var isPaused = false
    private(set) var isTrimming = false
    var isVertical = false {
        didSet { refreshCrop() }
    }
    var followsSubject = true {
        didSet { refreshCrop() }
    }
    /// 따라가기와 고정 위치로 자른 화면을 나란히 보여줍니다. 고정을 고른 상태에서도 피사체 위치를 분석합니다.
    var isComparing = false {
        didSet { refreshCrop() }
    }
    /// 피사체를 따라가지 않을 때 자르는 창의 고정 위치.
    private(set) var manualCenter: CGFloat = 0.5
    /// 피사체를 따라갈 때의 창 위치. 시각은 클립 시작 기준입니다.
    private(set) var keyframes: [ReelCrop.Keyframe] = []
    private(set) var isTracking = false
    var includesAudio = true {
        didSet { player?.isMuted = !includesAudio }
    }
    private(set) var isSaving = false

    @ObservationIgnored private var tracker: SubjectTracker?
    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    /// 사용자가 구간을 직접 고른 뒤에는 장면 분석 결과가 늦게 와도 구간을 바꾸지 않습니다.
    @ObservationIgnored private var userAdjusted = false
    @ObservationIgnored private var isSeeking = false

    init(asset: PHAsset, moment: Double, duration: Double) {
        self.asset = asset
        self.moment = moment
        self.duration = duration
        range = VideoClip.range(around: moment, length: 5, duration: duration)
    }

    var displaySize: CGSize { CGSize(width: asset.pixelWidth, height: asset.pixelHeight) }

    var trackedCenter: CGFloat {
        ReelCrop.center(at: currentTime - range.lowerBound, in: keyframes)
    }

    var previewCenter: CGFloat {
        followsSubject ? trackedCenter : manualCenter
    }

    var selectedLength: Length? {
        func matches(_ other: ClosedRange<Double>) -> Bool {
            abs(range.lowerBound - other.lowerBound) < 0.05 && abs(range.upperBound - other.upperBound) < 0.05
        }
        if let sceneRange, matches(sceneRange) { return .scene }
        return VideoClip.lengths
            .first { matches(VideoClip.range(around: moment, length: $0, duration: duration)) }
            .map { .seconds($0) }
    }

    func apply(scores: [FrameScore]) {
        self.scores = scores
        sceneRange = VideoClip.sceneRange(scores: scores, moment: moment, duration: duration)
        if !userAdjusted, let sceneRange {
            range = sceneRange
            refreshCrop()
            restartPreview()
        }
    }

    func choose(_ length: Length) {
        userAdjusted = true
        switch length {
        case .scene:
            guard let sceneRange else { return }
            range = sceneRange
        case .seconds(let seconds):
            range = VideoClip.range(around: moment, length: seconds, duration: duration)
        }
        refreshCrop()
        restartPreview()
    }

    // MARK: - Trimming

    func beginTrim() {
        isTrimming = true
        player?.pause()
    }

    /// 끄는 동안 바뀌는 쪽 끝 화면을 보여줍니다.
    func trim(_ edge: VideoClip.TrimEdge, from origin: ClosedRange<Double>, by delta: Double) {
        userAdjusted = true
        range = VideoClip.trimmed(origin, edge: edge, by: delta, duration: duration)
        seek(to: edge == .end ? range.upperBound : range.lowerBound, thenPlay: false)
    }

    func endTrim() {
        isTrimming = false
        refreshCrop()
        restartPreview()
    }

    func nudge(_ edge: VideoClip.TrimEdge, by delta: Double) {
        beginTrim()
        trim(edge, from: range, by: delta)
        endTrim()
    }

    // MARK: - Framing

    func placeCrop(at center: CGFloat) {
        if followsSubject { followsSubject = false }
        manualCenter = ReelCrop.clampedCenter(center, displaySize: displaySize)
    }

    private func refreshCrop() {
        trackingTask?.cancel()
        guard isVertical, followsSubject || isComparing else {
            isTracking = false
            return
        }
        let range = range
        isTracking = true
        trackingTask = Task {
            if tracker == nil, let video = await PhotoLibrary.videoAsset(for: asset, allowNetwork: true), tracker == nil {
                tracker = SubjectTracker(video: video, displaySize: displaySize)
            }
            let frames = await tracker?.keyframes(for: range) ?? []
            guard !Task.isCancelled else { return }
            keyframes = frames
            isTracking = false
        }
    }

    // MARK: - Playback

    func loadFrames() async {
        frames = await PhotoLibrary.filmstrip(for: asset, count: 12, side: 120)
    }

    /// 화면이 떠 있는 동안 고른 구간 끝에 닿으면 처음으로 돌아가 반복 재생합니다.
    func runPlayer() async {
        if player == nil {
            guard let item = await PhotoLibrary.playerItem(for: asset) else {
                if !Task.isCancelled { loadFailed = true }
                return
            }
            let player = AVPlayer(playerItem: item)
            player.isMuted = !includesAudio
            self.player = player
            restartPreview()
        }
        while !Task.isCancelled {
            if let player, player.currentItem?.status == .failed {
                player.pause()
                self.player = nil
                loadFailed = true
                return
            }
            if let player, !isTrimming, !isSeeking {
                currentTime = player.currentTime().seconds
                if !isPaused, currentTime >= range.upperBound - 0.03 {
                    seek(to: range.lowerBound, thenPlay: true)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 실패한 AVPlayerItem 은 다시 쓸 수 없어서, 아이템부터 새로 요청합니다.
    func retryPlayer() {
        loadFailed = false
        loadAttempt += 1
    }

    func togglePlayback() {
        guard let player else { return }
        if isPaused {
            isPaused = false
            if currentTime < range.lowerBound || currentTime >= range.upperBound - 0.05 {
                seek(to: range.lowerBound, thenPlay: true)
            } else {
                player.play()
            }
        } else {
            isPaused = true
            player.pause()
        }
    }

    func stop() {
        player?.pause()
        trackingTask?.cancel()
    }

    private func restartPreview() {
        isPaused = false
        seek(to: range.lowerBound, thenPlay: true)
    }

    private func seek(to time: Double, thenPlay: Bool) {
        guard let player else { return }
        isSeeking = true
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if thenPlay, finished, !self.isTrimming, !self.isPaused { self.player?.play() }
            }
        }
    }

    // MARK: - Saving

    func save() async throws {
        isSaving = true
        defer { isSaving = false }
        player?.pause()
        var crop: [ReelCrop.Keyframe]?
        if isVertical {
            if followsSubject {
                await trackingTask?.value
                crop = keyframes
            } else {
                crop = [ReelCrop.Keyframe(time: 0, center: manualCenter)]
            }
        }
        try await VideoClip.save(from: asset, options: VideoClip.Options(range: range, verticalCrop: crop, includesAudio: includesAudio))
    }
}

/// 찾은 장면을 릴스 소스로 다듬는 화면. 구간을 고르고, 9:16 로 자를지와 소리를 넣을지 정해 보관함에 저장합니다.
struct ClipEditorView: View {
    @State private var editor: ClipEditor
    /// 가로로 넓은 화면에서는 미리보기 옆에 옵션을 두어, 미리보기가 옵션에 밀려 납작해지지 않게 합니다.
    @State private var isWide = false
    /// 앱 전체 알림은 이 시트 아래에 가려 보이지 않으므로, 저장 실패는 시트 안에서 알립니다.
    @State private var saveError: String?
    let onSaved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let sidebarWidth: CGFloat = 320

    init(asset: PHAsset, moment: Double, duration: Double, onSaved: @escaping () -> Void) {
        _editor = State(initialValue: ClipEditor(asset: asset, moment: moment, duration: duration))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isWide {
                    HStack(alignment: .top, spacing: 20) {
                        ClipPreview(editor: editor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                lengthChoices
                                options
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: Self.sidebarWidth)
                    }
                } else {
                    ClipPreview(editor: editor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 6) {
                    ClipTrimBar(editor: editor)
                        .frame(height: ClipTrimBar.height)
                    rangeLabel
                }

                if !isWide {
                    lengthChoices
                    options
                }
            }
            .padding()
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.2 } action: { isWide = $0 }
            .navigationTitle("클립 만들기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .disabled(editor.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editor.isSaving {
                        ProgressView().accessibilityLabel("클립 저장 중")
                    } else {
                        Button("저장") { save() }
                            .accessibilityIdentifier("clip-save-button")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 920, minHeight: 540, idealHeight: 640)
        #else
        .presentationSizing(.page)
        #endif
        .interactiveDismissDisabled(editor.isSaving)
        .alert("클립을 저장하지 못했어요", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .task(id: editor.loadAttempt) { await editor.runPlayer() }
        .task { await editor.loadFrames() }
        .task { editor.apply(scores: await model.frameScores(for: editor.asset.localIdentifier)) }
        .onDisappear { editor.stop() }
    }

    private var rangeLabel: some View {
        let range = editor.range
        let length = String(format: "%.1f초", range.upperBound - range.lowerBound)
        return Text("\(TimeFormatter.precise(range.lowerBound)) – \(TimeFormatter.precise(range.upperBound)) · \(length)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("clip-range-label")
    }

    private var lengthChoices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if editor.sceneRange != nil {
                    choice(.scene, title: "장면 맞춤", systemImage: "wand.and.stars", identifier: "clip-length-scene")
                }
                ForEach(VideoClip.lengths.filter { $0 < editor.duration }, id: \.self) { length in
                    choice(.seconds(length), title: "\(Int(length))초", systemImage: nil, identifier: "clip-length-\(Int(length))")
                }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    @ViewBuilder
    private func choice(_ length: ClipEditor.Length, title: String, systemImage: String?, identifier: String) -> some View {
        let label = Group {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        if editor.selectedLength == length {
            Button { editor.choose(length) } label: { label }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button { editor.choose(length) } label: { label }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(identifier)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("화면비", selection: $editor.isVertical) {
                Text("원본").tag(false)
                Text("릴스 9:16").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("clip-aspect-picker")

            if editor.isVertical {
                HStack {
                    Toggle("피사체 따라가기", isOn: $editor.followsSubject)
                        .accessibilityIdentifier("clip-follow-toggle")
                    if editor.isTracking {
                        ProgressView().controlSize(.small).accessibilityLabel("피사체 찾는 중")
                    }
                    Spacer()
                    Toggle(isOn: $editor.isComparing) {
                        Label("비교", systemImage: "rectangle.split.2x1")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .accessibilityIdentifier("clip-compare-toggle")
                }
                Text(followHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("원본 소리 넣기", isOn: $editor.includesAudio)
                .accessibilityIdentifier("clip-audio-toggle")
        }
    }

    private var followHint: String {
        if editor.isComparing {
            return "왼쪽은 피사체를 따라가고, 오른쪽은 한 위치에 고정해요. 아래 이름을 눌러 저장할 방식을 고르세요."
        }
        return editor.followsSubject
            ? "얼굴이나 반려동물을 따라 화면이 움직여요. 미리보기를 끌면 그 위치에 고정돼요."
            : "미리보기를 끌어 자를 위치를 정하세요."
    }

    private func save() {
        Task {
            do {
                try await editor.save()
                onSaved()
                dismiss()
            } catch {
                let error = error as NSError
                saveError = [error.localizedDescription, error.localizedFailureReason, "(\(error.domain) \(error.code))"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
        }
    }
}

/// 고른 구간을 반복 재생하는 미리보기. 9:16 로 자를 때는 잘려 나갈 부분을 어둡게 덮고, 끌어서 위치를 정할 수 있습니다.
private struct ClipPreview: View {
    let editor: ClipEditor
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let videoRect = Self.fitRect(editor.displaySize, in: geometry.size)
            let comparing = editor.isVertical && editor.isComparing
            ZStack {
                if let player = editor.player {
                    if comparing {
                        comparison(player: player, container: geometry.size)
                    } else {
                        PlayerSurface(player: player, gravity: .resizeAspect)
                    }
                } else if editor.loadFailed {
                    VideoLoadFailedView { editor.retryPlayer() }
                        .environment(\.colorScheme, .dark)
                } else {
                    ProgressView("동영상 불러오는 중…")
                }
                if editor.isVertical, !comparing, editor.player != nil {
                    cropOverlay(videoRect: videoRect, container: geometry.size)
                        .allowsHitTesting(false)
                }
                if editor.isPaused {
                    Image(systemName: "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .padding(18)
                        .background(.black.opacity(0.45), in: Circle())
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture { editor.togglePlayback() }
            .gesture(cropDrag(videoRect: videoRect), including: editor.isVertical && !comparing ? .all : .subviews)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("클립 미리보기")
        .accessibilityAction(named: editor.isPaused ? "재생" : "일시정지") { editor.togglePlayback() }
    }

    /// 같은 플레이어를 두 번 그려, 따라가기와 고정 위치로 자른 결과를 같은 순간끼리 나란히 보여줍니다.
    private func comparison(player: AVPlayer, container: CGSize) -> some View {
        let spacing: CGFloat = 12
        let captionHeight: CGFloat = 36
        let width = max(0, min((container.width - spacing * 3) / 2,
                               (container.height - captionHeight - spacing * 3) * ReelCrop.aspect))
        let size = CGSize(width: width, height: width / ReelCrop.aspect)
        return HStack(spacing: spacing) {
            comparePane(player: player, size: size, center: editor.trackedCenter, follows: true,
                        title: "피사체 따라가기", identifier: "clip-compare-follow")
            comparePane(player: player, size: size, center: editor.manualCenter, follows: false,
                        title: "고정 위치", identifier: "clip-compare-fixed")
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func comparePane(player: AVPlayer, size: CGSize, center: CGFloat, follows: Bool,
                             title: String, identifier: String) -> some View {
        let isSelected = editor.followsSubject == follows
        VStack(spacing: 8) {
            ReelCropSurface(player: player, displaySize: editor.displaySize, center: center, size: size)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? .yellow : .white.opacity(0.3), lineWidth: isSelected ? 3 : 1)
                }
                .overlay {
                    if follows, editor.isTracking {
                        ProgressView().accessibilityLabel("피사체 찾는 중")
                    }
                }
            if isSelected {
                Button(title) { editor.followsSubject = follows }
                    .buttonStyle(.borderedProminent)
                    .accessibilityAddTraits(.isSelected)
                    .accessibilityIdentifier(identifier)
            } else {
                Button(title) { editor.followsSubject = follows }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(identifier)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    private func cropOverlay(videoRect: CGRect, container: CGSize) -> some View {
        let size = editor.displaySize
        let crop = ReelCrop.cropRect(displaySize: size, center: editor.previewCenter)
        let scale = size.width > 0 ? videoRect.width / size.width : 0
        let rect = CGRect(x: videoRect.minX + crop.minX * scale, y: videoRect.minY + crop.minY * scale,
                          width: crop.width * scale, height: crop.height * scale)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: container))
                path.addRect(rect)
            }
            .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .animation(.linear(duration: 0.1), value: rect)
    }

    private func cropDrag(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = dragStart ?? ReelCrop.clampedCenter(editor.previewCenter, displaySize: editor.displaySize)
                if dragStart == nil { dragStart = start }
                let delta = ReelCrop.movesHorizontally(editor.displaySize)
                    ? value.translation.width / max(videoRect.width, 1)
                    : value.translation.height / max(videoRect.height, 1)
                editor.placeCrop(at: start + delta)
            }
            .onEnded { _ in dragStart = nil }
    }

    static func fitRect(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// 9:16 로 잘린 결과만 보이도록 동영상을 키워 자르는 창 부분만 남깁니다.
private struct ReelCropSurface: View {
    let player: AVPlayer
    let displaySize: CGSize
    let center: CGFloat
    let size: CGSize

    var body: some View {
        let crop = ReelCrop.cropRect(displaySize: displaySize, center: center)
        let scale = crop.width > 0 ? size.width / crop.width : 0
        PlayerSurface(player: player, gravity: .resizeAspect)
            .frame(width: displaySize.width * scale, height: displaySize.height * scale)
            .offset(x: -crop.minX * scale, y: -crop.minY * scale)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .animation(.linear(duration: 0.1), value: crop)
    }
}

/// 사진 앱처럼 장면 띠 위에 노란 테두리로 고른 구간을 보여주고, 양 끝을 끌어 줄이거나 가운데를 끌어 옮깁니다.
/// 아래 띠는 검색어와 맞는 정도라, 진한 곳을 보고 구간을 맞출 수 있습니다.
private struct ClipTrimBar: View {
    static let height: CGFloat = 64
    private static let handleWidth: CGFloat = 16
    private static let stripHeight: CGFloat = 48
    private static let heatTop: CGFloat = 54
    private static let heatHeight: CGFloat = 6

    let editor: ClipEditor
    @State private var dragOrigin: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let handle = Self.handleWidth
            let track = max(geometry.size.width - handle * 2, 1)
            let duration = max(editor.duration, 0.1)
            let x = { (time: Double) in handle + CGFloat(min(max(time / duration, 0), 1)) * track }
            let range = editor.range
            let startX = x(range.lowerBound), endX = x(range.upperBound)

            ZStack(alignment: .topLeading) {
                filmstrip(width: track)
                    .offset(x: handle)
                Color.black.opacity(0.55)
                    .frame(width: max(0, startX - handle), height: Self.stripHeight)
                    .offset(x: handle)
                Color.black.opacity(0.55)
                    .frame(width: max(0, handle + track - endX), height: Self.stripHeight)
                    .offset(x: endX)

                heatStrip(duration: duration)
                    .frame(width: track, height: Self.heatHeight)
                    .offset(x: handle, y: Self.heatTop)
                Capsule()
                    .fill(.primary)
                    .frame(width: 2, height: Self.heatHeight + 4)
                    .offset(x: x(editor.moment) - 1, y: Self.heatTop - 2)
                    .accessibilityHidden(true)

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(0, endX - startX), height: Self.stripHeight)
                    .offset(x: startX)
                    .gesture(drag(.whole, track: track, duration: duration))
                    .accessibilityHidden(true)

                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.yellow, lineWidth: 3)
                    .frame(width: endX - startX + handle * 2, height: Self.stripHeight)
                    .offset(x: startX - handle)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .frame(width: 3, height: Self.stripHeight + 6)
                    .offset(x: x(editor.currentTime) - 1.5, y: -3)
                    .allowsHitTesting(false)

                handleView(.start, systemImage: "chevron.compact.left")
                    .offset(x: startX - handle)
                    .gesture(drag(.start, track: track, duration: duration))
                handleView(.end, systemImage: "chevron.compact.right")
                    .offset(x: endX)
                    .gesture(drag(.end, track: track, duration: duration))
            }
        }
    }

    private func filmstrip(width: CGFloat) -> some View {
        let frames = editor.frames
        return HStack(spacing: 0) {
            ForEach(frames.indices, id: \.self) { index in
                Image(platformImage: frames[index])
                    .resizable()
                    .scaledToFill()
                    .frame(width: width / CGFloat(max(frames.count, 1)), height: Self.stripHeight)
                    .clipped()
            }
        }
        .frame(width: width, height: Self.stripHeight)
        .background(Color.secondary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    /// 프레임마다 앞뒤 프레임과의 중간까지를 칠합니다. 동영상 안에서의 상대 점수라 가장 잘 맞는 곳이 가장 진합니다.
    private func heatStrip(duration: Double) -> some View {
        let scores = editor.scores
        return Canvas { context, size in
            guard scores.count > 1, let low = scores.map(\.score).min(), let high = scores.map(\.score).max() else { return }
            let span = max(high - low, 0.0001)
            for index in scores.indices {
                let start = index == 0 ? 0 : (scores[index - 1].time + scores[index].time) / 2
                let end = index == scores.count - 1 ? duration : (scores[index].time + scores[index + 1].time) / 2
                let rect = CGRect(x: start / duration * size.width, y: 0,
                                  width: max(1, (end - start) / duration * size.width), height: size.height)
                let strength = Double((scores[index].score - low) / span)
                context.fill(Path(rect), with: .color(.orange.opacity(0.1 + 0.9 * strength)))
            }
        }
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func handleView(_ edge: VideoClip.TrimEdge, systemImage: String) -> some View {
        let isStart = edge == .start
        let time = isStart ? editor.range.lowerBound : editor.range.upperBound
        return UnevenRoundedRectangle(
            topLeadingRadius: isStart ? 6 : 0, bottomLeadingRadius: isStart ? 6 : 0,
            bottomTrailingRadius: isStart ? 0 : 6, topTrailingRadius: isStart ? 0 : 6
        )
        .fill(.yellow)
        .overlay {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .foregroundStyle(.black.opacity(0.7))
        }
        .frame(width: Self.handleWidth, height: Self.stripHeight)
        .contentShape(Rectangle().inset(by: -8))
        .accessibilityElement()
        .accessibilityLabel(isStart ? "클립 시작" : "클립 끝")
        .accessibilityValue(TimeFormatter.precise(time))
        .accessibilityAdjustableAction { direction in
            editor.nudge(edge, by: direction == .increment ? 0.5 : -0.5)
        }
        .accessibilityIdentifier(isStart ? "clip-start-handle" : "clip-end-handle")
    }

    private func drag(_ edge: VideoClip.TrimEdge, track: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? editor.range
                if dragOrigin == nil {
                    dragOrigin = origin
                    editor.beginTrim()
                }
                editor.trim(edge, from: origin, by: Double(value.translation.width / track) * duration)
            }
            .onEnded { _ in
                dragOrigin = nil
                editor.endTrim()
            }
    }
}
