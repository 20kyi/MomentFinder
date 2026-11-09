import Foundation
import Observation

@MainActor
@Observable
final class IndexSettings {
    private enum Key {
        static let useICloud = "settings.useICloud"
        static let allowCellular = "settings.allowCellular"
        static let includeVideos = "settings.includeVideos"
        static let analyzeSubjects = "settings.analyzeSubjects"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// iCloud 에만 있는 원본을 내려받아 분석할지 여부.
    var useICloud: Bool { didSet { defaults.set(useICloud, forKey: Key.useICloud) } }
    /// 셀룰러처럼 비싼 네트워크에서도 iCloud 다운로드를 허용할지 여부.
    var allowCellular: Bool { didSet { defaults.set(allowCellular, forKey: Key.allowCellular) } }
    var includeVideos: Bool { didSet { defaults.set(includeVideos, forKey: Key.includeVideos) } }
    /// 얼굴과 개·고양이를 찾아 인물별로 묶을지 여부.
    var analyzeSubjects: Bool { didSet { defaults.set(analyzeSubjects, forKey: Key.analyzeSubjects) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.useICloud: true, Key.allowCellular: false, Key.includeVideos: true, Key.analyzeSubjects: true])
        useICloud = defaults.bool(forKey: Key.useICloud)
        allowCellular = defaults.bool(forKey: Key.allowCellular)
        includeVideos = defaults.bool(forKey: Key.includeVideos)
        analyzeSubjects = defaults.bool(forKey: Key.analyzeSubjects)
    }
}
