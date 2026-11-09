import SwiftUI

struct PermissionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("사진 보관함 접근이 필요해요", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("사진과 동영상을 기기 안에서 분석해서 \"고양이 하품\"처럼 문장으로 찾을 수 있게 해요. iCloud 사진도 함께 검색되고, 사진은 외부로 전송되지 않아요.")
        } actions: {
            Button("사진 접근 허용") {
                Task { await model.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct PermissionDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("사진 접근이 꺼져 있어요", systemImage: "lock.shield")
        } description: {
            Text("설정에서 Moment Finder의 사진 접근을 \"전체 접근\"으로 바꿔주세요.")
        } actions: {
            Button("설정 열기") {
                if let url = settingsURL { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var settingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}
