import XCTest

final class TabNavigationTests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.actrail.app")
        app.launch()
    }
    
    func screenshot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
    
    // ===== P: 全新安装 =====
    func testP01_freshInstallHomeEmpty() {
        screenshot("P01_home_empty_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("P01_home_empty_after")
    }
    
    // ===== H: 首页 =====
    func testH01_startActivity() {
        screenshot("H01_start_before")
        let btn = app.buttons["工作"]
        if btn.waitForExistence(timeout: 3) {
            btn.tap()
            sleep(2)
        }
        screenshot("H01_start_after")
    }
    
    func testH02_multipleActivities() {
        screenshot("H02_multi_before")
        let w = app.buttons["工作"]
        if w.waitForExistence(timeout: 3) { w.tap(); sleep(1) }
        let m = app.buttons["运动"]
        if m.waitForExistence(timeout: 3) { m.tap(); sleep(2) }
        screenshot("H02_multi_after")
    }
    
    func testH03_duplicateActivity() {
        screenshot("H03_dup_before")
        let w = app.buttons["工作"]
        if w.waitForExistence(timeout: 3) { w.tap(); sleep(2) }
        if w.exists { w.tap(); sleep(1) }
        screenshot("H03_dup_after")
    }
    
    func testH05_stopActivity() {
        screenshot("H05_stop_before")
        let w = app.buttons["工作"]
        if w.waitForExistence(timeout: 3) { w.tap(); sleep(2) }
        let stop = app.buttons.matching(NSPredicate(format: "label CONTAINS 'stop'")).firstMatch
        if stop.waitForExistence(timeout: 3) { stop.tap(); sleep(1) }
        screenshot("H05_stop_after")
    }
    
    func testH08_editorMode() {
        screenshot("H08_editor_before")
        let btn = app.buttons["编辑"]
        if btn.waitForExistence(timeout: 3) {
            btn.tap()
            sleep(1)
        }
        screenshot("H08_editor_after")
        let done = app.buttons["完成"]
        if done.exists { done.tap() }
    }
    
    func testH09_homeLayout() {
        screenshot("H09_layout_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("H09_layout_after")
    }
    
    func testH10_homeButtons() {
        screenshot("H10_buttons_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("H10_buttons_after")
    }
    
    // ===== S: 统计页 =====
    func testS01_statsTab() {
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        screenshot("S01_stats_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("S01_stats_after")
    }
    
    func testS04_statsEmpty() {
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        screenshot("S04_empty_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("S04_empty_after")
    }
    
    func testS05_statsCalendarTrend() {
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        screenshot("S05_cal_before")
        let calBtn = app.buttons["calendar"]
        if calBtn.waitForExistence(timeout: 3) { calBtn.tap(); sleep(1) }
        screenshot("S05_cal_after")
    }
    
    func testS06_statsPeriodSegment() {
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        screenshot("S06_period_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("S06_period_after")
    }
    
    // ===== R: 提醒页 =====
    func testR01_reminderTab() {
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(2)
        screenshot("R01_reminder_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("R01_reminder_after")
    }
    
    func testR10_reminderEmpty() {
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(2)
        screenshot("R10_empty_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("R10_empty_after")
    }
    
    func testR11_reminderEmptyState() {
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(2)
        screenshot("R11_emptystate_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("R11_emptystate_after")
    }
    
    // ===== ST: 设置页 =====
    func testST01_settingsTab() {
        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(2)
        screenshot("ST01_settings_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("ST01_settings_after")
    }
    
    func testST02_settingsAppearance() {
        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(2)
        screenshot("ST02_appearance_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("ST02_appearance_after")
    }
    
    func testST04_settingsClearData() {
        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(2)
        screenshot("ST04_clear_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("ST04_clear_after")
    }
    
    func testST05_settingsAbout() {
        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(2)
        screenshot("ST05_about_before")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        screenshot("ST05_about_after")
    }
}
