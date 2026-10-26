import XCTest

final class FeatureParityUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    }

    func testSearchKeyboardKeepsMicrophoneInPlace() {
        app.launchArguments.append("--ui-empty")
        app.launch()
        let microphone = app.buttons["开始录音"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 15))
        let originalY = microphone.frame.midY
        let prompt = app.staticTexts["empty-transcript-prompt"]
        XCTAssertTrue(prompt.exists)
        let originalPromptY = prompt.frame.midY
        app.buttons["搜索转写"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.frame.midY, originalY, accuracy: 1)
        XCTAssertEqual(prompt.frame.midY, originalPromptY, accuracy: 1)
        app.buttons["取消"].tap()
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.frame.midY, originalY, accuracy: 1)
        XCTAssertEqual(prompt.frame.midY, originalPromptY, accuracy: 1)
    }

    func testRecordingShowsLiveAndCommittedTextWithoutIdlePrompt() {
        app.launchArguments.append("--ui-recording")
        app.launch()
        XCTAssertTrue(app.buttons["停止录音"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["正在识别的实时文字。"].exists)
        XCTAssertTrue(app.staticTexts["这是一条测试转写。"].exists)
        XCTAssertFalse(app.staticTexts["empty-transcript-prompt"].exists)
    }

    func testRecordingBeforeFirstDecodeDoesNotShowIdlePrompt() {
        app.launchArguments += ["--ui-recording", "--ui-empty"]
        app.launch()
        XCTAssertTrue(app.buttons["停止录音"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["LIVE"].exists)
        XCTAssertFalse(app.staticTexts["empty-transcript-prompt"].exists)
    }

    func testHistorySelectionLoadsMainScreenDirectly() {
        app.launchArguments.append("--ui-empty")
        app.launch()
        app.buttons["历史记录"].tap()
        let row = app.buttons["history-record.fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["这是一条测试转写。"].exists)
        XCTAssertFalse(app.navigationBars["历史记录"].exists)
        XCTAssertFalse(app.buttons["导出转写"].exists)
    }

    func testHistorySearchFindsRecordsAndOpensThemWithTheSearch() {
        app.launchArguments.append("--ui-empty")
        app.launch()
        app.buttons["历史记录"].tap()
        let row = app.buttons["history-record.fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let field = app.textFields["history-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        field.typeText("没有这句话")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        app.buttons["history-search-clear"].tap()
        field.tap()
        field.typeText("测试")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 处匹配"].exists)

        row.tap()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["历史记录"].exists)
        XCTAssertEqual(app.textFields["搜索当前转写"].value as? String, "测试")
        XCTAssertTrue(app.staticTexts["这是一条测试转写。"].exists)
    }

    func testStopDismissesModelLoadingImmediately() {
        app.launchArguments.append("--ui-loading")
        app.launch()
        let stop = app.buttons["取消准备"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        // The idle prompt stays hidden while the model loads; it returns once loading is cancelled.
        XCTAssertFalse(app.staticTexts["empty-transcript-prompt"].exists)
        stop.tap()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["empty-transcript-prompt"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["正在加载模型 3/3：音频编码器"].exists)
        XCTAssertFalse(app.buttons["停止录音"].exists)
    }

    private func openSettings() {
        app.launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 15))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    }

    func testAISettingsOfferIndependentModelsSearchAndLanguage() {
        openSettings()
        app.buttons["AI"].tap()
        // Hidden, the key shows one dot per character; the eye shows it as text and hides it
        // again, and the box keeps its height.
        func keyField(value: String) -> XCUIElement {
            app.textViews.matching(NSPredicate(format: "identifier == 'openai-api-key' AND value == %@", value)).firstMatch
        }
        let dots = String(repeating: "•", count: "ui-test-key".count)
        XCTAssertTrue(keyField(value: dots).waitForExistence(timeout: 5))
        let hint = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '密钥保存在此设备'")).firstMatch
        let hiddenY = hint.frame.minY
        app.buttons["reveal-api-key"].tap()
        XCTAssertTrue(keyField(value: "ui-test-key").waitForExistence(timeout: 3))
        XCTAssertEqual(hint.frame.minY, hiddenY, accuracy: 0.5)
        app.buttons["reveal-api-key"].tap()
        XCTAssertTrue(keyField(value: dots).waitForExistence(timeout: 3))
        XCTAssertEqual(hint.frame.minY, hiddenY, accuracy: 0.5)
        let hints = app.switches["AI 提示"]
        XCTAssertTrue(hints.exists)
        hints.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(hints.value as? String, "1")
        let search = app.switches["联网搜索"]
        XCTAssertTrue(search.exists)
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(search.value as? String, "1")
        XCTAssertTrue(app.buttons["modelPicker.提示模型"].exists)
        app.swipeUp()
        XCTAssertTrue(app.switches["AI 摘要"].exists)
        XCTAssertTrue(app.buttons["modelPicker.摘要模型"].exists)
    }

    func testSummaryCanBeGeneratedAndOpenedFromHistory() {
        app.launch()
        app.buttons["历史记录"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "history-record.fixture").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        app.buttons["生成摘要"].tap()
        XCTAssertTrue(app.staticTexts["这是测试摘要。"].waitForExistence(timeout: 5))
        app.navigationBars["摘要"].buttons["完成"].tap()
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["查看摘要"].waitForExistence(timeout: 5))
    }

    func testTranslationAndSpeechControlsArePresent() {
        openSettings()
        app.buttons["翻译"].tap()
        XCTAssertTrue(app.switches["翻译"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["translation-emphasis"].exists)
        XCTAssertTrue(app.buttons["添加翻译规则"].exists)
        app.swipeUp()
        XCTAssertTrue(app.switches["朗读译文"].exists)
    }

    func testRecognitionOffersPromptDetectionLanguagesAndPreview() {
        openSettings()
        app.buttons["识别"].tap()
        XCTAssertTrue(app.buttons["自动检测语言范围"].waitForExistence(timeout: 5))
        app.buttons["识别提示词"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["开始预览"].exists)
        XCTAssertTrue(app.sliders["能量阈值"].exists)
    }

    /// The note has no close button and leaves on its own after its reading time (about 5 s here).
    func testHintIsRenderedAndLeavesOnItsOwn() {
        app.launchArguments.append("--ui-hints")
        app.launch()
        let hint = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '这是测试 AI 提示。'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["关闭提示"].exists)
        XCTAssertTrue(hint.waitForNonExistence(timeout: 15))
    }
    func testTranslationIsAppliedToTheTranscript() {
        openSettings()
        app.buttons["翻译"].tap()
        app.buttons["translation-target"].firstMatch.tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["翻译"].waitForExistence(timeout: 5))
        let toggle = app.switches["翻译"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["Test translation."].waitForExistence(timeout: 5))
    }

    func testInterfaceLanguageChangesNativeSettingsLabels() {
        openSettings()
        app.buttons["通用"].tap()
        app.buttons["interface-language"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 5))
    }

    func testHistoryContextMenuOffersSharingWithoutResumeOrPlayback() {
        app.launch()
        app.buttons["历史记录"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "history-record.fixture").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["导出文字"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["sample.wav"].exists)
        XCTAssertFalse(app.buttons["继续录音"].exists)
        XCTAssertFalse(app.buttons["播放录音"].exists)
    }

    func testCopyFromContextMenuShowsCopiedToast() {
        app.launch()
        let row = app.staticTexts["这是一条测试转写。"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["从此处播放"].exists)
        XCTAssertFalse(app.buttons["分享"].exists)
        app.buttons["复制"].tap()
        // One query checks both identity and text: the toast lives 1.2 s, too short for a second snapshot.
        let toast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'copied-toast' AND label CONTAINS '已复制'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        // The toast dismisses itself.
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3))
    }

}
