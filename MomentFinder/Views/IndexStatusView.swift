import SwiftUI

struct IndexStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isIndexing {
            Gauge(value: model.progress.currentStageFraction) {
                Image(systemName: "sparkles")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .scaleEffect(0.6)
            .frame(width: 32, height: 32)
            .accessibilityLabel("사진 분석 진행률")
        } else {
            Image(systemName: "slider.horizontal.3")
                .accessibilityLabel("인덱스 설정")
        }
    }
}

struct IndexStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsReset = false

    var body: some View {
        @Bindable var settings = model.settings

        NavigationStack {
            Form {
                Section("분석 상태") {
                    LabeledContent("검색 가능", value: "\(model.indexedAssetCount)개")
                    LabeledContent("진행", value: "\(model.progress.indexed) / \(model.progress.total)")
                    if model.progress.subjectTotal > 0 {
                        LabeledContent("인물·반려동물 분석", value: "\(model.progress.subjectsDone) / \(model.progress.subjectTotal)")
                    }
                    if model.progress.videoTotal > 0 {
                        LabeledContent("동영상 장면 분석", value: "\(model.progress.videoScenesDone) / \(model.progress.videoTotal)")
                    }
                    if model.progress.failed > 0 {
                        LabeledContent("실패 (다음에 재시도)", value: "\(model.progress.failed)개")
                    }
                    if model.isIndexing {
                        ProgressView(value: model.progress.currentStageFraction)
                        Button("일시정지") { model.pauseIndexing() }
                    } else {
                        Button("지금 분석") { model.startIndexing() }
                            .disabled(!model.isEngineReady)
                    }
                }

                Section {
                    Toggle("iCloud 원본 내려받기", isOn: $settings.useICloud)
                    Toggle("셀룰러 데이터 허용", isOn: $settings.allowCellular)
                        .disabled(!settings.useICloud)
                    Toggle("동영상 분석", isOn: $settings.includeVideos)
                    Toggle("인물·반려동물 구분", isOn: $settings.analyzeSubjects)
                } header: {
                    Text("옵션")
                } footer: {
                    Text("사진과 동영상 대표 장면을 먼저 분석해 바로 검색할 수 있게 해요. 그다음 얼굴과 개·고양이를 찾아 인물별로 묶고, 동영상을 1초 간격으로 분석해서 \"하품\" 같은 순간도 찾을 수 있게 해요. iCloud에만 있는 동영상은 원본을 내려받아야 해서 기기에 있는 동영상보다 나중에 분석해요. 얼굴 정보는 기기 밖으로 나가지 않아요.")
                }

                Section {
                    Button("인덱스 초기화", role: .destructive) { confirmsReset = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("사진 분석")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .confirmationDialog("인덱스를 초기화하고 처음부터 다시 분석할까요?", isPresented: $confirmsReset) {
                Button("초기화", role: .destructive) {
                    Task { await model.resetIndex() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}
