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
        .safeAreaInset(edge: .bottom) {
            SubjectsInAssetRow(assetID: item.hit.assetID)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let score = item.hit.score {
                ToolbarItem(placement: .primaryAction) {
                    Text("일치도 \(score, format: .number.precision(.fractionLength(3)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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

/// 사진 속에서 찾은 인물·반려동물. 이름 있는 그룹은 눌러서 모아 보고, 이름이 없거나 잘못된 경우 이름을 붙입니다.
private struct SubjectsInAssetRow: View {
    let assetID: String
    @Environment(AppModel.self) private var model
    @State private var entries: [(subject: StoredSubject, name: String?)] = []
    @State private var naming: StoredSubject?
    @State private var openedGroup: Int64?

    var body: some View {
        Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("이 사진 속 인물")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(entries, id: \.subject.id) { entry in
                                chip(entry.subject, name: entry.name)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .task(id: model.groups) { entries = await model.subjects(inAsset: assetID) }
        .sheet(item: $naming) { subject in
            NameSubjectSheet(subject: subject, currentName: entries.first { $0.subject.id == subject.id }?.name)
        }
        .navigationDestination(item: $openedGroup) { PersonDetailView(clusterID: $0) }
    }

    private func chip(_ subject: StoredSubject, name: String?) -> some View {
        Button {
            if name != nil, let clusterID = subject.clusterID {
                openedGroup = clusterID
            } else {
                naming = subject
            }
        } label: {
            VStack(spacing: 4) {
                SubjectThumbnail(subject: subject, size: 44)
                Text(name ?? "이름 없음")
                    .font(.caption2)
                    .foregroundStyle(name == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("이름 바꾸기", systemImage: "pencil") { naming = subject }
        }
        .accessibilityIdentifier("subject-chip")
    }
}

private struct NameSubjectSheet: View {
    let subject: StoredSubject
    let currentName: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var suggestions: [String] {
        Array(Set(model.groups.filter { $0.species == subject.species }.compactMap(\.name))).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        SubjectThumbnail(subject: subject, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("이름", text: $name)
                        .submitLabel(.done)
                        .onSubmit { save(name) }
                } footer: {
                    Text(currentName == nil
                         ? "이 그룹의 모든 사진에 이름이 붙어요. 이미 있는 이름이면 한 그룹으로 합쳐져요."
                         : "이 사진만 다른 이름의 그룹으로 옮겨요.")
                }
                if !suggestions.isEmpty {
                    Section("이미 있는 이름") {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { save(suggestion) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(subject.species == .person ? "누구예요?" : "이름이 뭐예요?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = currentName ?? "" }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else { dismiss(); return }
        Task {
            await model.nameSubject(subject.id, as: trimmed)
            dismiss()
        }
    }
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
