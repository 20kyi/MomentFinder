import SwiftUI

/// 자동으로 묶인 인물·반려동물 그룹. 이름 붙은 그룹이 먼저 나옵니다.
struct PeopleView: View {
    @Environment(AppModel.self) private var model

    private var named: [SubjectGroup] { model.groups.filter { $0.name != nil } }
    private var unnamed: [SubjectGroup] { model.groups.filter { $0.name == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusNote
                if !named.isEmpty {
                    section("이름 있음", groups: named)
                }
                if !unnamed.isEmpty {
                    section("이름 붙이기", groups: unnamed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.groups.isEmpty {
                ContentUnavailableView(
                    "아직 찾은 인물이 없어요",
                    systemImage: "person.2",
                    description: Text(emptyDescription)
                )
            }
        }
        .navigationTitle("인물·반려동물")
        .task { await model.refreshGroups() }
    }

    private var emptyDescription: String {
        if !model.settings.analyzeSubjects {
            return "사진 분석 설정에서 \"인물·반려동물 구분\"을 켜 주세요."
        }
        return "같은 얼굴이나 반려동물이 사진 \(SubjectClusterer.minimumVisibleMembers)장 이상에서 보이면 여기에 묶여 나타나요."
    }

    @ViewBuilder
    private var statusNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isIndexing && model.progress.remainingSubjects > 0 {
                Label("인물 분석 중 \(model.progress.subjectsDone) / \(model.progress.subjectTotal)", systemImage: "person.crop.rectangle.stack")
                ProgressView(value: model.progress.subjectFraction)
            }
            if !model.recognizesFaces {
                Label("얼굴 인식 모델이 없어 반려동물만 구분해요. make face-model 로 모델을 준비해 주세요.", systemImage: "exclamationmark.triangle")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func section(_ title: String, groups: [SubjectGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                ForEach(groups) { group in
                    NavigationLink {
                        PersonDetailView(clusterID: group.id)
                    } label: {
                        GroupCell(group: group)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("subject-group")
                }
            }
        }
    }
}

private struct GroupCell: View {
    let group: SubjectGroup

    var body: some View {
        VStack(spacing: 6) {
            SubjectThumbnail(subject: group.cover, size: 88)
                .overlay(alignment: .bottomTrailing) {
                    if group.species.isPet {
                        Image(systemName: "pawprint.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .orange)
                    }
                }
            Text(group.name ?? "이름 없음")
                .font(.subheadline.weight(group.name == nil ? .regular : .semibold))
                .foregroundStyle(group.name == nil ? .secondary : .primary)
                .lineLimit(1)
            Text("사진 \(group.assetCount)장")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
