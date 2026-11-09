import Foundation

/// OpenAI CLIP과 동일한 byte-level BPE 토크나이저. MobileCLIP 텍스트 인코더 입력을 만듭니다.
struct CLIPTokenizer: Sendable {
    static let startToken: Int32 = 49406
    static let endToken: Int32 = 49407
    static let contextLength = 77

    private let vocabulary: [String: Int32]
    private let mergeRanks: [String: Int]
    private let byteEncoder: [UInt8: Character]
    private let pattern: NSRegularExpression

    init(vocabularyURL: URL, mergesURL: URL) throws {
        vocabulary = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocabularyURL))

        var ranks: [String: Int] = [:]
        let lines = try String(contentsOf: mergesURL, encoding: .utf8).split(whereSeparator: \.isNewline)
        for line in lines where !line.hasPrefix("#version") {
            ranks[String(line)] = ranks.count
        }
        mergeRanks = ranks

        byteEncoder = Self.makeByteEncoder()
        pattern = try NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive]
        )
    }

    init(bundle: Bundle) throws {
        guard let vocab = bundle.url(forResource: "clip-vocab", withExtension: "json"),
              let merges = bundle.url(forResource: "clip-merges", withExtension: "txt") else {
            throw CLIPError.missingResource("clip-vocab.json / clip-merges.txt")
        }
        try self.init(vocabularyURL: vocab, mergesURL: merges)
    }

    /// 시작/끝 토큰을 포함하고 0으로 패딩된 길이 77의 토큰 배열.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        var tokens: [Int32] = [Self.startToken]
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in pattern.matches(in: cleaned, range: range) {
            guard let r = Range(match.range, in: cleaned) else { continue }
            let encoded = String(cleaned[r].utf8.compactMap { byteEncoder[$0] })
            for piece in bpe(encoded) {
                if let id = vocabulary[piece] { tokens.append(id) }
            }
        }

        tokens = Array(tokens.prefix(Self.contextLength - 1)) + [Self.endToken]
        return tokens + Array(repeating: 0, count: Self.contextLength - tokens.count)
    }

    private func bpe(_ token: String) -> [String] {
        var word = token.unicodeScalars.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let rank = mergeRanks[word[i] + " " + word[i + 1]], rank < (best?.rank ?? .max) {
                    best = (rank, i)
                }
            }
            guard let best else { break }

            let first = word[best.index], second = word[best.index + 1]
            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }

    private static func makeByteEncoder() -> [UInt8: Character] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for b in 0...255 where !bytes.contains(b) {
            bytes.append(b)
            scalars.append(256 + extra)
            extra += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, s) in zip(bytes, scalars) {
            map[UInt8(b)] = Character(UnicodeScalar(UInt32(s))!)
        }
        return map
    }
}
