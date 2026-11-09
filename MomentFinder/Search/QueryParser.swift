import Foundation

struct ParsedQuery: Equatable, Sendable {
    var text: String
    var kind: MediaKind?
    /// 검색어에서 찾은 인물·반려동물 이름. 나온 순서대로입니다.
    var names: [String] = []
}

/// "고양이가 하품하는 동영상" → 텍스트 "고양이가 하품하는", 종류 동영상 처럼 검색어에서 미디어 종류를 분리합니다.
/// 사용자가 붙인 이름("초코랑 산책")도 분리해서, 번역기가 이름을 엉뚱하게 옮기지 않게 합니다.
enum QueryParser {
    private static let videoPattern = #"(동영상|영상|비디오)(을|를|이|가|은|는|에서|속)?|\b(videos?|clips?)\b"#
    private static let photoPattern = #"(사진|이미지)(을|를|이|가|은|는|에서|속)?|\b(photos?|pictures?|images?)\b"#
    private static let fillerPattern = #"(찾아\s*줘|찾아\s*주세요|보여\s*줘|보여\s*주세요|검색해\s*줘)"#
    /// 이름 뒤에 붙는 조사. 긴 것부터 맞춰야 "이랑" 이 "이" 로 잘리지 않습니다.
    private static let nameParticles = "(이랑|하고|이가|에게|한테|이는|이를|이의|랑|와|과|가|이|의|를|을|은|는|도|만)?"

    static func parse(_ raw: String, names: [String] = []) -> ParsedQuery {
        var text = raw
        var kind: MediaKind?

        var found: [(name: String, position: Int)] = []
        for name in names.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + nameParticles + #"(?![\p{L}\p{N}])"#
            guard text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let position = raw.range(of: pattern, options: [.regularExpression, .caseInsensitive])
                .map { raw.distance(from: raw.startIndex, to: $0.lowerBound) } ?? 0
            found.append((name, position))
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }

        if text.range(of: videoPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            kind = .video
            text = text.replacingOccurrences(of: videoPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        } else if text.range(of: photoPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            kind = .photo
            text = text.replacingOccurrences(of: photoPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: fillerPattern, with: " ", options: .regularExpression)

        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let fallback = found.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : ""
        return ParsedQuery(
            text: collapsed.isEmpty ? fallback : collapsed,
            kind: kind,
            names: found.sorted { $0.position < $1.position }.map(\.name)
        )
    }

    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
    }

    /// CLIP은 "a photo of ..." 형태의 문장에서 성능이 좋아서 원문과 함께 평균냅니다.
    static func prompts(for englishText: String) -> [String] {
        let text = englishText
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        return ["a photo of \(text)", text]
    }
}
