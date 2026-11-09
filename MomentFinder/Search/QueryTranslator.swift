import Foundation
import Observation
import Translation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Apple Translation 프레임워크로 한국어 검색어를 기기 안에서 영어로 번역합니다.
/// TranslationSession 은 SwiftUI `.translationTask` 안에서만 얻을 수 있어서, 요청을 큐에 쌓고 뷰가 처리하게 합니다.
/// 세션을 매번 새로 열면 느리므로 `.translationTask` 클로저를 끝내지 않고 새 요청을 기다리게 둡니다.
@MainActor
@Observable
final class QueryTranslator {
    private(set) var configuration: TranslationSession.Configuration?

    private static let source = Locale.Language(identifier: "ko")
    private static let target = Locale.Language(identifier: "en")

    @ObservationIgnored
    private var pending: [(text: String, continuation: CheckedContinuation<String, Error>)] = []
    @ObservationIgnored
    private var wake: AsyncStream<Void>.Continuation?
    @ObservationIgnored
    private var sessionGeneration = 0
    @ObservationIgnored
    private var cache: [String: String] = [:]

    /// 번역 언어가 이미 내려받아져 있으면 세션을 미리 열어 첫 검색이 기다리지 않게 합니다.
    /// 설치돼 있지 않으면 다운로드 안내가 뜨지 않도록 첫 검색 때까지 미룹니다.
    func prepare() async {
        guard configuration == nil else { return }
        let status = await LanguageAvailability().status(from: Self.source, to: Self.target)
        if status == .installed, configuration == nil {
            configuration = .init(source: Self.source, target: Self.target)
        }
    }

    func translate(_ text: String) async throws -> String {
        if let cached = cache[text] { return cached }
        let translated: String
        if let known = QueryGlossary.translate(text) {
            translated = known
        } else {
            let sentence = try await request(text)
            if Self.looksLikeEnglish(sentence) {
                translated = sentence
            } else {
                translated = try await translateWordByWord(text)
            }
        }
        cache[text] = translated
        return translated
    }

    /// 문장째 번역한 결과에 없는 영어 단어가 섞이면, 사전에 있는 말은 사전으로, 나머지는 한 단어씩 번역해 이어 붙입니다.
    private func translateWordByWord(_ text: String) async throws -> String {
        var words: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let known = QueryGlossary.translate(token) {
                words.append(known)
            } else {
                words.append(try await request(token))
            }
        }
        return words.joined(separator: " ")
    }

    /// 번역 모델이 만들어 낸 "snawn" 같은 없는 단어나 옮기지 못한 한글이 있으면 false 입니다.
    static func looksLikeEnglish(_ text: String) -> Bool {
        guard !QueryParser.containsHangul(text) else { return false }
        #if canImport(UIKit)
        guard let language = UITextChecker.availableLanguages.first(where: { $0.hasPrefix("en") }) else { return true }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return UITextChecker().rangeOfMisspelledWord(in: text, range: range, startingAt: 0, wrap: false, language: language).location == NSNotFound
        #elseif canImport(AppKit)
        let checker = NSSpellChecker.shared
        guard let language = checker.availableLanguages.first(where: { $0.hasPrefix("en") }) else { return true }
        return checker.checkSpelling(of: text, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        #else
        return true
        #endif
    }

    private func request(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((text, continuation))
            if let wake {
                wake.yield()
            } else if configuration == nil {
                configuration = .init(source: Self.source, target: Self.target)
            } else {
                configuration?.invalidate()
            }
        }
    }

    func process(_ session: TranslationSession) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        let (signals, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        defer {
            if generation == sessionGeneration { wake = nil }
        }

        if pending.isEmpty {
            _ = try? await session.translate("고양이")
        }
        guard await drain(session) else { return }
        for await _ in signals {
            guard await drain(session) else { return }
        }
    }

    /// 실패하면 남은 요청도 함께 실패시키고 false 를 돌려 세션을 닫습니다. 다음 요청 때 세션을 다시 열어 다운로드 안내를 다시 띄울 수 있게 합니다.
    private func drain(_ session: TranslationSession) async -> Bool {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            do {
                let response = try await session.translate(job.text)
                job.continuation.resume(returning: response.targetText)
            } catch {
                job.continuation.resume(throwing: error)
                let failed = pending
                pending = []
                failed.forEach { $0.continuation.resume(throwing: error) }
                return false
            }
        }
        return true
    }
}
