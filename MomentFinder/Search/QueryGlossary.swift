import Foundation

/// 자주 쓰는 사진 검색어를 번역기 없이 영어로 옮깁니다.
/// 기기 번역 모델은 짧은 단어 나열을 엉뚱하게 옮길 때가 있어서("고양이 하품" → "cat snawn") 사전에 있는 말은 사전을 우선합니다.
/// 모든 단어를 사전으로 옮길 수 있을 때만 결과를 돌려주고, 하나라도 모르면 nil 을 돌려 번역기에 맡깁니다.
enum QueryGlossary {
    /// 뜻이 여럿인 말(눈, 말, 배, 차, 강, 길, 다리, 새 등)은 넣지 않고 번역기에 맡깁니다.
    /// 동작은 CLIP 이 잘 알아듣는 -ing 형태로 둡니다.
    private static let words: [String: String] = [
        // 동물
        "고양이": "cat", "아기고양이": "kitten", "새끼고양이": "kitten", "강아지": "dog", "개": "dog",
        "토끼": "rabbit", "햄스터": "hamster", "물고기": "fish", "앵무새": "parrot", "비둘기": "pigeon",
        "오리": "duck", "돼지": "pig", "닭": "chicken", "거북이": "turtle", "다람쥐": "squirrel",
        "사슴": "deer", "코끼리": "elephant", "기린": "giraffe", "사자": "lion", "호랑이": "tiger",
        "곰": "bear", "펭귄": "penguin", "원숭이": "monkey", "나비": "butterfly",
        // 사람
        "아기": "baby", "아이": "child", "아이들": "children", "남자": "man", "여자": "woman",
        "엄마": "mother", "아빠": "father", "할머니": "grandmother", "할아버지": "grandfather",
        "친구": "friends", "가족": "family", "사람들": "people", "커플": "couple", "셀카": "selfie",
        // 장소·풍경
        "바다": "ocean", "바닷가": "beach", "해변": "beach", "산": "mountain", "강가": "riverside",
        "호수": "lake", "숲": "forest", "공원": "park", "하늘": "sky", "구름": "clouds",
        "노을": "sunset", "일몰": "sunset", "일출": "sunrise", "해돋이": "sunrise", "야경": "city at night",
        "도시": "city", "거리": "street", "집": "house", "방": "room", "카페": "cafe", "식당": "restaurant",
        "학교": "school", "놀이터": "playground", "수영장": "swimming pool", "텐트": "tent", "폭포": "waterfall",
        "꽃": "flowers", "벚꽃": "cherry blossoms", "단풍": "autumn leaves", "나무": "tree", "잔디": "grass",
        "비": "rain", "무지개": "rainbow", "눈사람": "snowman", "불꽃놀이": "fireworks",
        // 음식·물건·행사
        "케이크": "cake", "생일": "birthday", "촛불": "candles", "커피": "coffee", "피자": "pizza",
        "아이스크림": "ice cream", "음식": "food", "밥": "rice", "라면": "ramen", "치킨": "fried chicken",
        "고기": "meat", "과일": "fruit", "수박": "watermelon", "딸기": "strawberry",
        "자동차": "car", "자전거": "bicycle", "기차": "train", "비행기": "airplane", "공": "ball",
        "장난감": "toy", "책": "book", "풍선": "balloons", "선물": "gift", "크리스마스": "christmas",
        "졸업식": "graduation ceremony", "결혼식": "wedding", "여행": "travel", "파티": "party",
        "캠핑": "camping", "축구": "soccer", "야구": "baseball", "농구": "basketball",
        // 동작
        "하품": "yawning", "산책": "walking", "수영": "swimming", "낮잠": "napping", "잠": "sleeping",
        "자는": "sleeping", "자고": "sleeping", "잠자는": "sleeping",
        "웃음": "smiling", "웃는": "smiling", "웃고": "smiling", "미소": "smiling",
        "울음": "crying", "우는": "crying", "울고": "crying",
        "먹는": "eating", "먹고": "eating", "식사": "eating",
        "달리기": "running", "달리는": "running", "뛰는": "running", "뛰어노는": "playing",
        "노는": "playing", "놀고": "playing", "놀이": "playing", "점프": "jumping",
        "춤": "dancing", "춤추는": "dancing", "노래": "singing", "요리": "cooking", "운동": "exercising",
        "등산": "hiking", "낚시": "fishing", "키스": "kissing", "뽀뽀": "kissing", "포옹": "hugging",
        "박수": "clapping", "기지개": "stretching", "그루밍": "grooming", "목욕": "bathing",
        "샤워": "showering", "운전": "driving", "독서": "reading",
    ]

    /// 단어 뒤에 붙는 조사와 "하다" 활용. 여러 개가 이어 붙을 수 있습니다("고양이들이", "하품하고있는").
    /// "중"은 "집중" 같은 낱말을 잘못 쪼개므로 넣지 않습니다.
    private static let suffixes = [
        "하고있는", "하는중", "하면서", "하는", "하고", "하다", "한다", "해요", "하며", "하기", "한", "해",
        "중인", "이랑", "에서", "에게", "한테", "으로", "들", "이", "가", "은", "는", "을", "를", "의",
        "와", "과", "랑", "에", "도", "만", "로",
    ]

    /// 띄어 쓴 낱말 전체가 이것일 때만 뜻 없이 버립니다.
    private static let ignoredWords: Set<String> = ["있는", "있다", "있어요", "중", "중인", "모습", "장면", "순간"]

    private static let keysByLength = words.keys.sorted { $0.count > $1.count }

    static func translate(_ text: String) -> String? {
        var english: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            if !QueryParser.containsHangul(String(token)) {
                english.append(String(token))
            } else if ignoredWords.contains(String(token)) {
                continue
            } else if let parts = segment(token) {
                english.append(contentsOf: parts)
            } else {
                return nil
            }
        }
        return english.isEmpty ? nil : english.joined(separator: " ")
    }

    /// 띄어쓰기 없이 붙여 쓴 말("고양이하품")도 사전 단어와 조사로 끝까지 나눠질 때만 받아들입니다.
    private static func segment(_ text: Substring) -> [String]? {
        if text.isEmpty { return [] }
        for key in keysByLength where text.hasPrefix(key) {
            if let rest = segmentAfterWord(text.dropFirst(key.count)) {
                return [words[key]!] + rest
            }
        }
        return nil
    }

    private static func segmentAfterWord(_ text: Substring) -> [String]? {
        if let rest = segment(text) { return rest }
        for suffix in suffixes where text.hasPrefix(suffix) {
            if let rest = segmentAfterWord(text.dropFirst(suffix.count)) { return rest }
        }
        return nil
    }
}
