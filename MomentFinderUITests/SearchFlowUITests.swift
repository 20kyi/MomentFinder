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

        // 저장하면 보관함에 동영상이 늘어 다른 테스트 결과가 바뀌므로 편집 화면만 열어 보고 닫습니다.
        let clipButton = app.buttons["clip-button"]
        XCTAssertTrue(clipButton.waitForExistence(timeout: 10), "클립 만들기 버튼이 없습니다")
        XCTAssertTrue(clipButton.isHittable, "클립 만들기 버튼이 화면 밖에 있습니다")
        clipButton.tap()

        let scene = app.buttons["clip-length-scene"]
        XCTAssertTrue(scene.waitForExistence(timeout: 10), "장면 맞춤 선택지가 없습니다")
        XCTAssertTrue(scene.isSelected, "처음 구간이 찾은 장면에 맞춰지지 않았습니다")
        XCTAssertTrue(app.buttons["clip-length-3"].exists)
        XCTAssertFalse(app.buttons["clip-length-15"].exists, "동영상보다 긴 클립 길이가 보입니다")
        let rangeLabel = app.staticTexts["clip-range-label"]
        let start = try XCTUnwrap(Self.seconds(in: rangeLabel.label), rangeLabel.label)
        XCTAssertGreaterThanOrEqual(start, 4, "장면 구간이 정지 표지판 부분까지 넓어졌습니다: \(rangeLabel.label)")
        attachScreenshot("19-clip-editor")

        app.segmentedControls["clip-aspect-picker"].buttons["릴스 9:16"].tap()
        XCTAssertTrue(app.switches["clip-follow-toggle"].waitForExistence(timeout: 5), "9:16 옵션이 보이지 않습니다")
        XCTAssertTrue(app.buttons["clip-save-button"].isEnabled)
        attachScreenshot("20-clip-editor-vertical")

        app.descendants(matching: .any)["clip-compare-toggle"].firstMatch.tap()
        let fixed = app.buttons["clip-compare-fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5), "따라가기 비교 화면이 보이지 않습니다")
        XCTAssertTrue(app.buttons["clip-compare-follow"].isSelected, "처음에는 따라가기가 골라져 있어야 합니다")
        attachScreenshot("21-clip-editor-compare")
        fixed.tap()
        XCTAssertTrue(fixed.isSelected, "고정 위치를 골라도 반영되지 않았습니다")
        XCTAssertEqual(app.switches["clip-follow-toggle"].value as? String, "0", "고정을 골랐는데 따라가기가 켜져 있습니다")

        app.buttons["clip-length-3"].tap()
        XCTAssertTrue(app.buttons["clip-length-3"].isSelected, "길이 선택이 반영되지 않았습니다")
        app.buttons["취소"].tap()
        XCTAssertTrue(clipButton.waitForExistence(timeout: 5), "편집 화면이 닫히지 않았습니다")
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

    /// 결과를 열면 아래에 다른 결과 썸네일이 보이고, 좌우로 넘기거나 썸네일을 눌러 이동할 수 있어야 합니다.
    func testSwipesBetweenResultsInDetail() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")

        search("two cats sleeping on a couch")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 30))
        let showWeak = app.buttons["관련도가 낮은 사진도 보기"]
        if !waitUntil(timeout: 5, { results.count >= 3 }), showWeak.exists {
            showWeak.tap()
        }
        guard waitUntil(timeout: 10, { results.count >= 3 }) else { throw XCTSkip("결과가 3개 미만입니다") }
        results.element(boundBy: 0).tap()

        let strip = app.buttons.matching(identifier: "detail-strip-item")
        XCTAssertTrue(strip.firstMatch.waitForExistence(timeout: 10), "아래 썸네일 줄이 없습니다")
        XCTAssertTrue(strip.element(boundBy: 0).isSelected, "처음 연 결과가 선택되어 있지 않습니다")
        let moment = app.buttons["moment-button"]
        if moment.waitForExistence(timeout: 5) {
            XCTAssertTrue(moment.isHittable, "찾은 장면 버튼이 썸네일 줄에 가려졌습니다")
        }
        attachScreenshot("9-detail-strip")

        app.swipeLeft()
        XCTAssertTrue(waitUntil { strip.element(boundBy: 1).isSelected }, "왼쪽으로 넘겨도 다음 결과로 가지 않았습니다")
        attachScreenshot("10-swiped-next")

        app.swipeRight()
        XCTAssertTrue(waitUntil { strip.element(boundBy: 0).isSelected }, "오른쪽으로 넘겨도 이전 결과로 가지 않았습니다")

        strip.element(boundBy: 2).tap()
        XCTAssertTrue(waitUntil { strip.element(boundBy: 2).isSelected }, "썸네일을 눌러도 이동하지 않았습니다")
        sleep(1)
        attachScreenshot("11-tapped-strip")

        let start = strip.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 38, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitUntil { strip.element(boundBy: 1).isSelected }, "썸네일 줄을 한 칸 넘겨도 바로 옆 결과가 선택되지 않았습니다")
        let selectedFrame = strip.element(boundBy: 1).frame
        XCTAssertEqual(selectedFrame.midX, app.windows.firstMatch.frame.midX, accuracy: 4, "선택된 썸네일이 가운데에 있지 않습니다")
        sleep(1)
        attachScreenshot("12-scrubbed-strip")
    }

    /// 첫 번째가 아닌 결과를 열어도 그 결과가 화면에 보여야 합니다. 공유·삭제 대상과 보이는 항목이 어긋나면 안 됩니다.
    func testOpensTappedResultInDetail() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")

        search("two cats sleeping on a couch")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 30))
        guard waitUntil(timeout: 10, { results.count >= 2 }),
              results.element(boundBy: 0).identifier != results.element(boundBy: 1).identifier else {
            throw XCTSkip("첫 두 결과의 종류(사진/동영상)가 달라야 구분할 수 있습니다")
        }
        let opensVideo = results.element(boundBy: 1).identifier == "result-video"
        results.element(boundBy: 1).tap()

        let strip = app.buttons.matching(identifier: "detail-strip-item")
        XCTAssertTrue(strip.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(strip.element(boundBy: 1).isSelected)
        let moment = app.buttons["moment-button"]
        let showsVideo = waitUntil(timeout: 3) { moment.exists && app.windows.firstMatch.frame.contains(moment.frame) }
        attachScreenshot("16-opened-second")
        XCTAssertEqual(showsVideo, opensVideo, "누른 결과가 아닌 다른 결과가 화면에 보입니다")
    }

    /// 상세 화면에서 즐겨찾기를 켜고 끄고, 공유 시트와 삭제 확인 창을 열 수 있어야 합니다. 삭제는 확인 창에서 취소합니다.
    func testFavoriteShareAndDeleteInDetail() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")

        search("two cats sleeping on a couch")
        let firstResult = app.buttons["result-photo"].firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 30))
        firstResult.tap()

        let favorite = app.buttons["favorite-button"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), "즐겨찾기 버튼이 없습니다")
        let before = favorite.label
        favorite.tap()
        XCTAssertTrue(waitUntil { favorite.label != before }, "즐겨찾기를 눌러도 바뀌지 않았습니다")
        attachScreenshot("13-favorite-toggled")
        favorite.tap()
        XCTAssertTrue(waitUntil { favorite.label == before }, "즐겨찾기를 되돌리지 못했습니다")

        app.buttons["share-button"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10), "공유 시트가 열리지 않았습니다")
        attachScreenshot("14-share-sheet")
        let close = shareSheet.buttons["Close"].exists ? shareSheet.buttons["Close"] : shareSheet.buttons["닫기"]
        if close.exists { close.tap() } else { app.swipeDown() }
        XCTAssertTrue(waitUntil(timeout: 5) { !shareSheet.exists })

        app.buttons["delete-button"].tap()
        // 삭제 확인 창은 앱이 아니라 시스템이 띄웁니다.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancelLabels = ["Don’t Allow", "Don't Allow", "허용 안 함"]
        var cancel: XCUIElement?
        XCTAssertTrue(waitUntil(timeout: 10) {
            cancel = cancelLabels.flatMap { [springboard.buttons[$0], app.buttons[$0]] }.first { $0.exists }
            return cancel != nil
        }, "삭제 확인 창이 뜨지 않았습니다")
        attachScreenshot("15-delete-confirm")
        cancel?.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { cancel?.exists == false })
        XCTAssertTrue(favorite.exists, "삭제를 취소했는데 상세 화면이 닫혔습니다")
    }

    /// 결과를 여러 개 골라 한 번에 공유 시트로 넘길 수 있어야 합니다. 고른 순서가 편집 앱에 넘어갈 순서입니다.
    func testSelectsMultipleResultsAndShares() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")

        search("two cats sleeping on a couch")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 30))
        guard waitUntil(timeout: 10, { results.count >= 2 }) else { throw XCTSkip("결과가 2개 미만입니다") }

        app.buttons["select-button"].tap()
        let share = app.buttons["share-selection-button"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertFalse(share.isEnabled, "아무것도 고르지 않았는데 공유할 수 있습니다")

        results.element(boundBy: 1).tap()
        results.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil { results.element(boundBy: 0).isSelected && results.element(boundBy: 1).isSelected })
        XCTAssertEqual(app.staticTexts["selection-count"].label, "2개 선택됨")
        XCTAssertFalse(app.buttons["moment-button"].exists, "선택 모드에서 상세 화면이 열렸습니다")
        attachScreenshot("17-multi-select")

        share.tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10), "공유 시트가 열리지 않았습니다")
        attachScreenshot("18-multi-share-sheet")
        let close = shareSheet.buttons["Close"].exists ? shareSheet.buttons["Close"] : shareSheet.buttons["닫기"]
        if close.exists { close.tap() } else { app.swipeDown() }
        XCTAssertTrue(waitUntil(timeout: 5) { !shareSheet.exists })

        app.buttons["cancel-selection-button"].tap()
        XCTAssertTrue(waitUntil { !results.element(boundBy: 0).isSelected }, "선택을 취소해도 선택이 남아 있습니다")
    }

    /// 인물 분석이 끝나면 인물 화면에서 그룹을 보고 이름을 붙인 뒤, 그 이름이 검색 칩으로 나타나야 합니다.
    func testNamesSubjectGroupAndFiltersByChip() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '검색 가능'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 180), "인덱싱이 끝나지 않았습니다")
        let analyzing = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '인물·반려동물 분석'")).firstMatch
        let deadline = Date().addingTimeInterval(300)
        while analyzing.exists && Date() < deadline { sleep(2) }

        let people = app.buttons["people-button"]
        guard people.waitForExistence(timeout: 5) else {
            throw XCTSkip("시뮬레이터 보관함에서 묶인 인물·반려동물 그룹이 없습니다")
        }
        people.tap()
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
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let chip = app.buttons["subject-filter-chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "이름 칩이 나타나지 않았습니다")
        chip.tap()
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10))
        attachScreenshot("8-chip-filter")
    }

    /// 검색하지 않아도 홈 화면에서 보관함 전체를 사진 앱처럼 보고, 눌러서 크게 볼 수 있어야 합니다.
    func testShowsWholeLibraryOnHome() throws {
        app.launch()
        grantPhotoAccessIfNeeded()

        let items = app.buttons.matching(identifier: "library-item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 30), "홈 화면에 보관함 갤러리가 없습니다")
        XCTAssertTrue(app.staticTexts["모든 사진"].exists)
        XCTAssertTrue(app.staticTexts["library-day-header"].exists, "갤러리가 날짜로 나뉘지 않았습니다")
        app.swipeUp()
        attachScreenshot("23-home-library")

        // 내비게이션 바나 검색창 밑에 걸친 항목을 누르면 바가 탭을 받으므로, 화면 가운데에 온전히 보이는 항목을 고릅니다.
        let visible = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 150)
        let item = try XCTUnwrap((0..<items.count).lazy.map { items.element(boundBy: $0) }.first { visible.contains($0.frame) })
        item.tap()
        XCTAssertTrue(app.buttons["favorite-button"].waitForExistence(timeout: 10), "갤러리 항목을 눌러도 상세 화면이 열리지 않았습니다")
        XCTAssertFalse(app.buttons["moment-button"].exists, "검색하지 않은 항목에 찾은 장면 버튼이 보입니다")
        attachScreenshot("24-home-library-detail")
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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
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
