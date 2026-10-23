import AppKit
import XCTest
@testable import Voiced

final class AppDelegateTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.close()
        }
        windows = []
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func testClosesEveryVisibleMainWindowButOne() {
        _ = NSApplication.shared
        let first = makeWindow()
        let second = makeWindow()
        let third = makeWindow()
        for window in [first, second, third] {
            window.orderFront(nil)
        }
        XCTAssertTrue(first.isVisible && second.isVisible && third.isVisible)

        let kept = AppDelegate.closeExtraWindows()

        XCTAssertNotNil(kept)
        let stillVisible = [first, second, third].filter(\.isVisible)
        XCTAssertEqual(stillVisible.count, 1)
        XCTAssertTrue(stillVisible.first === kept)
    }

    func testSingleWindowIsLeftAlone() {
        _ = NSApplication.shared
        let only = makeWindow()
        only.orderFront(nil)

        let kept = AppDelegate.closeExtraWindows()

        XCTAssertTrue(kept === only)
        XCTAssertTrue(only.isVisible)
    }
}
