import XCTest

final class ActrailUITests: XCTestCase {
    let app = XCUIApplication()
    var screenshotCounter = 0
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--reset-data"]
        app.launch()
        screenshotCounter = 0
    }
    
    func takeScreenshot(_ name: String) {
        screenshotCounter += 1
        let attachment = XCUIScreenshotAttachment(
            name: "\(screenshotCounter)_\(name)",
            screenshot: app.screenshot(),
            lifetime: .keepAlways
        )
        XCTContext.current.add(attachment)
    }
    
    func test01_HomePage() throws {
        takeScreenshot("01_home_empty")
        XCTAssertTrue(app.staticTexts["行迹"].exists, "首页标题存在")
    }
    
    func test02_EditorMode() throws {
        let editButton = app.buttons["编辑"]
        if editButton.exists {
            editButton.tap()
            takeScreenshot("02_editor_mode")
            let doneButton = app.buttons["完成"]
            XCTAssertTrue(doneButton.exists, "编辑模式显示完成按钮")
            doneButton.tap()
        }
    }
    
    func test03_StatsTab() throws {
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        takeScreenshot("03_stats_tab")
    }
    
    func test04_ReminderTab() throws {
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(2)
        takeScreenshot("04_reminder_tab")
    }
    
    func test05_SettingsTab() throws {
        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(2)
        takeScreenshot("05_settings_tab")
    }
    
    func test06_BackToHome() throws {
        app.tabBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        takeScreenshot("06_back_home")
    }
    
    func test07_StartActivity() throws {
        // 尝试点击第一个活动图标
        let workButton = app.buttons["工作"]
        if workButton.exists {
            workButton.tap()
            sleep(2)
            takeScreenshot("07_activity_running")
        }
    }
    
    func test08_StopActivity() throws {
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'stop'")).firstMatch
        if stopButton.exists {
            stopButton.tap()
            sleep(1)
            takeScreenshot("08_activity_stopped")
        }
    }
    
    func test09_StatsAfterActivity() throws {
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        takeScreenshot("09_stats_with_data")
    }
    
    func test10_ReminderAdd() throws {
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(1)
        let addBtn = app.buttons["+"]
        if addBtn.exists {
            addBtn.tap()
            sleep(1)
            takeScreenshot("10_reminder_add_sheet")
        }
    }
}
