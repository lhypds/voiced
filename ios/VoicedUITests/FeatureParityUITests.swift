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
        app.launch()
        let microphone = app.buttons["开始录音"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 15))
        let originalY = microphone.frame.midY
        app.buttons["搜索转写"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.frame.midY, originalY, accuracy: 1)
        app.buttons["取消"].tap()
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.frame.midY, originalY, accuracy: 1)
    }

    func testSearchIsGreyWithNothingToSearch() {
        app.launchArguments.append("--ui-empty")
        app.launch()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["搜索转写"].isEnabled)
        // The fixture's saved record is still in the history.
        XCTAssertTrue(app.buttons["历史记录"].isEnabled)
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

    /// End to end with the real model and Mac link, not the fixtures, the speech coming from a WAV
    /// in place of the microphone: TEST_RUNNER_VOICED_AUDIO=<16 kHz mono WAV> with an ordinary
    /// sentence at 2 s, speech to hold from 11 s to about 18 s and more ordinary speech at 27 s.
    /// Skipped without it.
    func testRealHoldWhileRecordingSendsToMac() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOICED_AUDIO"] == nil, "real end-to-end run only")
        let audio = try XCTUnwrap(ProcessInfo.processInfo.environment["VOICED_AUDIO"].flatMap { $0.isEmpty ? nil : $0 },
                                  "real end-to-end run only")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--ui-audio-file", audio, "--ui-log"]
        app.launch()
        let start = app.buttons["开始录音"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()
        let stop = app.buttons["停止录音"]
        XCTAssertTrue(stop.waitForExistence(timeout: 900), "the recording did not start")
        print("MARK-RECORDING")
        sleep(8)
        print("MARK-HOLD-START")
        stop.press(forDuration: 13)
        print("MARK-HOLD-END")
        XCTAssertTrue(app.buttons["停止录音"].exists, "letting go of the hold stopped the recording")
        sleep(35)
        print("MARK-DONE")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.buttons["停止录音"].exists, "the recording stopped after the hold")
    }

    func testEditingALineFromItsMenu() {
        app.launch()
        let row = app.staticTexts["这是一条测试转写。"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        // Cancel leaves the line as it was.
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 3))
        app.buttons["编辑"].tap()
        let editor = app.textViews["line-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "这是一条测试转写。")
        app.buttons["取消"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        // Done replaces its text.
        row.press(forDuration: 1)
        app.buttons["编辑"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        editor.typeText("Edited by hand.")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["Edited by hand."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["这是一条测试转写。"].exists)
    }

    func testHoldingStopWhileRecordingKeepsRecording() {
        app.launchArguments += ["--ui-recording", "--ui-send-to-mac"]
        app.launch()
        let stop = app.buttons["停止录音"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let holds = app.staticTexts["ui-hold-count"]
        XCTAssertEqual(holds.label, "0")
        // A hold records a clip (sent to the Mac too); letting go must not count as a tap on Stop.
        stop.press(forDuration: 1.5)
        XCTAssertEqual(holds.label, "1", "holding Stop did not start sending to the Mac")
        XCTAssertFalse(app.buttons["开始录音"].waitForExistence(timeout: 2), "holding Stop stopped the recording")
        XCTAssertTrue(app.buttons["停止录音"].exists)
        // A second hold behaves the same.
        app.buttons["停止录音"].press(forDuration: 1.5)
        XCTAssertEqual(holds.label, "2", "the second hold did not start sending")
        XCTAssertFalse(app.buttons["开始录音"].waitForExistence(timeout: 2), "the second hold stopped the recording")
    }

    func testTappingStopStillStopsRecording() {
        app.launchArguments += ["--ui-recording", "--ui-send-to-mac"]
        app.launch()
        let stop = app.buttons["停止录音"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        stop.tap()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui-hold-count"].label, "0", "a tap must not count as a hold")
    }

    func testHoldingStopWithSendToMacOffStillHoldsAndKeepsRecording() {
        app.launchArguments.append("--ui-recording")
        app.launch()
        let stop = app.buttons["停止录音"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        // With the switch off a hold still records a clip to transcribe; it just sends nothing.
        stop.press(forDuration: 1.5)
        XCTAssertEqual(app.staticTexts["ui-hold-count"].label, "1", "with the switch off a hold did not take effect")
        XCTAssertFalse(app.buttons["开始录音"].waitForExistence(timeout: 2), "a hold must never stop the recording")
    }

    func testStopDuringModelLoadKeepsLoadingInTheBackground() {
        app.launchArguments.append("--ui-loading")
        app.launch()
        let stop = app.buttons["取消准备"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["empty-transcript-prompt"].exists)
        stop.tap()
        // The recording is cancelled at once, but the model goes on loading, its progress showing.
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["停止录音"].exists)
        XCTAssertTrue(app.staticTexts["正在加载模型 3/3：音频编码器"].exists)
        XCTAssertFalse(app.staticTexts["empty-transcript-prompt"].exists)
    }

    /// With the real model, from a fresh launch: TEST_RUNNER_VOICED_AUDIO=<WAV> as for
    /// `testRealHoldWhileRecordingSendsToMac`. Skipped without it.
    func testRealStopWhileLoadingFinishesLoading() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOICED_AUDIO"] == nil, "real end-to-end run only")
        let audio = ProcessInfo.processInfo.environment["VOICED_AUDIO"]!
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--ui-audio-file", audio]
        app.launch()
        let start = app.buttons["开始录音"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()
        let cancel = app.buttons["取消准备"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the model was not loading")
        cancel.tap()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 3))
        // A warm load can be over before this looks, so the proof is the next start: had the stop
        // cancelled the load, it would have to load again, banner and all.
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '正在加载模型'")).firstMatch
        XCTAssertTrue(banner.waitForNonExistence(timeout: 300), "the model did not finish loading")
        XCTAssertFalse(app.buttons["停止录音"].exists, "a recording started although it was stopped")
        app.buttons["开始录音"].tap()
        XCTAssertFalse(banner.waitForExistence(timeout: 1), "stopping cancelled the model load: it loads again")
        XCTAssertTrue(app.buttons["停止录音"].waitForExistence(timeout: 8), "the loaded model was not kept")
    }

    func testRealHoldReleasedWhileLoadingFinishesLoading() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOICED_AUDIO"] == nil, "real end-to-end run only")
        let audio = ProcessInfo.processInfo.environment["VOICED_AUDIO"]!
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--ui-audio-file", audio]
        app.launch()
        let start = app.buttons["开始录音"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.press(forDuration: 1.2)
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '正在加载模型'")).firstMatch
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 3))
        XCTAssertTrue(banner.waitForNonExistence(timeout: 300), "the model did not finish loading")
        XCTAssertFalse(app.buttons["停止录音"].exists, "a recording started after the hold was let go")
        // The model was kept: a tap now records without loading again.
        app.buttons["开始录音"].tap()
        XCTAssertFalse(banner.waitForExistence(timeout: 1), "letting go cancelled the model load: it loads again")
        XCTAssertTrue(app.buttons["停止录音"].waitForExistence(timeout: 8), "the loaded model was not kept")
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
        XCTAssertFalse(app.sliders["能量阈值"].exists)
    }

    func testAudioInputOffersGainAndEnergyThreshold() {
        openSettings()
        app.buttons["音频输入"].tap()
        XCTAssertTrue(app.sliders["输入增益"].waitForExistence(timeout: 5))
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

    func testNewRecordWhileRecordingStopsAndStartsEmptyRecord() {
        app.launchArguments.append("--ui-recording")
        app.launch()
        XCTAssertTrue(app.buttons["停止录音"].waitForExistence(timeout: 15))
        let newRecord = app.buttons["新建转写"]
        XCTAssertTrue(newRecord.isEnabled)
        newRecord.tap()
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["empty-transcript-prompt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["这是一条测试转写。"].exists)
        // The previous record stays in the history.
        app.buttons["历史记录"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "history-record.fixture").firstMatch.waitForExistence(timeout: 5))
    }

}
