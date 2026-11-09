import XCTest

/// 시뮬레이터 보관함에 고양이 사진들과, 앞 5초 정지 표지판 / 뒤 5초 고양이로 이어 붙인 동영상이 들어 있다고 가정합니다.
final class SearchFlowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testFindsCatPhotosAndVideoMoment() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")
        attachScreenshot("1-indexed")

        search("two cats sleeping on a couch")
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 30))
        attachScreenshot("2-results")

        let video = app.buttons["result-video"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), "동영상 결과가 없습니다")
        video.tap()

        let moment = app.buttons["moment-button"]
        XCTAssertTrue(moment.waitForExistence(timeout: 20))
        attachScreenshot("3-video-moment")
        let seconds = try XCTUnwrap(Self.seconds(in: moment.label), moment.label)
        XCTAssertGreaterThanOrEqual(seconds, 5, "고양이 장면(5초 이후)이 아닌 \(moment.label) 을 찾았습니다")
    }

    /// 보관함에 생일 케이크 사진이 없으므로 엉뚱한 사진 대신 "없음" 화면을 보여주고, 원하면 비슷한 사진을 볼 수 있어야 합니다.
    func testHidesWeakMatchesUntilAsked() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")

        search("birthday cake with candles")
        XCTAssertTrue(app.staticTexts["딱 맞는 사진이 없어요"].waitForExistence(timeout: 30))
        attachScreenshot("4-no-match")

        app.buttons["비슷한 사진 보기"].tap()
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10))
        attachScreenshot("5-weak-matches")
    }

    /// 인물 분석이 끝나면 인물 화면에서 그룹을 보고 이름을 붙인 뒤, 그 이름이 검색 칩으로 나타나야 합니다.
    func testNamesSubjectGroupAndFiltersByChip() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")
        let analyzing = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '인물·반려동물 분석'")).firstMatch
        let deadline = Date().addingTimeInterval(300)
        while analyzing.exists && Date() < deadline { sleep(2) }

        app.buttons["people-button"].tap()
        XCTAssertTrue(app.navigationBars["인물·반려동물"].waitForExistence(timeout: 10))
        attachScreenshot("6-people")

        let group = app.buttons["subject-group"].firstMatch
        guard group.waitForExistence(timeout: 5) else {
            throw XCTSkip("시뮬레이터 보관함에서 3장 이상 묶인 그룹이 없습니다")
        }
        group.tap()
        let nameField = app.textFields["subject-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("나비\n")
        attachScreenshot("7-named-group")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let chip = app.buttons["subject-filter-chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "이름 칩이 나타나지 않았습니다")
        chip.tap()
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10))
        attachScreenshot("8-chip-filter")
    }

    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text + "\n")
    }

    private func grantPhotoAccessIfNeeded() {
        let allowInApp = app.buttons["사진 접근 허용"]
        guard allowInApp.waitForExistence(timeout: 5) else { return }
        allowInApp.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = ["Allow Full Access", "전체 접근 허용", "Allow Access to All Photos", "모든 사진에 대한 접근 허용"]
        for label in candidates where springboard.buttons[label].waitForExistence(timeout: 3) {
            springboard.buttons[label].tap()
            break
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func seconds(in label: String) -> Int? {
        guard let match = label.range(of: #"\d+:\d{2}"#, options: .regularExpression) else { return nil }
        let parts = label[match].split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }
}
