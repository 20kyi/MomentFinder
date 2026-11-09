import Foundation

struct ParsedQuery: Equatable, Sendable {
    var text: String
    var kind: MediaKind?
}

/// "고양이가 하품하는 동영상" → 텍스트 "고양이가 하품하는", 종류 동영상 처럼 검색어에서 미디어 종류를 분리합니다.
enum QueryParser {
    private static let videoPattern = #"(동영상|영상|비디오)(을|를|이|가|은|는|에서|속)?|\b(videos?|clips?)\b"#
    private static let photoPattern = #"(사진|이미지)(을|를|이|가|은|는|에서|속)?|\b(photos?|pictures?|images?)\b"#
    private static let fillerPattern = #"(찾아\s*줘|찾아\s*주세요|보여\s*줘|보여\s*주세요|검색해\s*줘)"#

    static func parse(_ raw: String) -> ParsedQuery {
        var text = raw
        var kind: MediaKind?

        if text.range(of: videoPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            kind = .video
            text = text.replacingOccurrences(of: videoPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        } else if text.range(of: photoPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            kind = .photo
            text = text.replacingOccurrences(of: photoPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: fillerPattern, with: " ", options: .regularExpression)

        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ParsedQuery(text: collapsed.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : collapsed, kind: kind)
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
