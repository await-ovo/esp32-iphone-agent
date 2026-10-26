import XCTest
import UIKit
@testable import IPhoneAgent

@MainActor final class ScreenCaptureTests: XCTestCase {
    private func jpeg(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400), format: format).jpegData(withCompressionQuality: 0.75) { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }
    }

    func testIdenticalFramesSettleWithoutRepeatedImageComparisons() async throws {
        let feed = ScreenCaptureFeed(), image = jpeg(.black)
        feed.show(image, width: 200, height: 400)
        let updates = Task {
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(20))
                feed.show(image, width: 200, height: 400)
            }
        }
        let result = await feed.settled(quiet: 0.1, least: 0, most: 1)
        try await updates.value
        XCTAssertEqual(result.reason, .quiet)
        XCTAssertEqual(result.comparisons, 0)
        XCTAssertEqual(result.comparisonMs, 0)
    }

    func testAChangedFrameRestartsTheQuietPeriod() async throws {
        let feed = ScreenCaptureFeed(), changed = jpeg(.white)
        feed.show(jpeg(.black), width: 200, height: 400)
        let update = Task {
            try await Task.sleep(for: .milliseconds(20))
            feed.show(changed, width: 200, height: 400)
            return now()
        }
        let result = await feed.settled(quiet: 0.1, least: 0, most: 2)
        let arrived = try await update.value
        XCTAssertEqual(result.reason, .quiet)
        XCTAssertEqual(result.comparisons, 1)
        XCTAssertEqual(feed.frame, changed)
        XCTAssertGreaterThanOrEqual(now() - arrived, 0.1)
    }

    func testSettlingReportsCancellationInsteadOfWaitingForTheLimit() async throws {
        let feed = ScreenCaptureFeed()
        feed.show(jpeg(.black), width: 200, height: 400)
        let job = Task { await feed.settled(quiet: 5, least: 5, most: 10) }
        try await Task.sleep(for: .milliseconds(20))
        job.cancel()
        let result = await job.value
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertLessThan(result.elapsedMs, 1000)
    }

    func testAnUnavailableFrameIsNotReportedAsQuiet() async {
        let result = await ScreenCaptureFeed().settled(quiet: 0.01, least: 0, most: 0.1)
        XCTAssertEqual(result.reason, .timeout)
        XCTAssertEqual(result.comparisons, 0)
    }

    func testScreenshotWaitsForAnImageAfterTheAction() async throws {
        let feed = ScreenCaptureFeed()
        feed.show(Data([1]), width: 200, height: 400)
        let action = now()
        let arrival = Task {
            try await Task.sleep(for: .milliseconds(30))
            feed.show(Data([2]), width: 200, height: 400)
        }
        let result = try await feed.image(after: action, timeout: 0.5)
        try await arrival.value
        XCTAssertEqual(result, Data([2]))
        XCTAssertGreaterThan(feed.capturedAt, action)
    }

    func testUnchangedContentRemainsUsableWithoutFakingItsCaptureTime() async throws {
        let feed = ScreenCaptureFeed()
        let captured = now() - 20
        feed.show(Data([1]), width: 200, height: 400, captured: captured)
        XCTAssertTrue(feed.live)
        let snapshot = try await feed.snapshot(after: now() - 1, timeout: 0.03)
        XCTAssertEqual(snapshot.jpeg, Data([1]))
        XCTAssertEqual(snapshot.capturedAt, captured)
    }

    func testInvalidatedStreamCannotServeItsPreviousImage() async {
        let feed = ScreenCaptureFeed()
        feed.show(Data([1]), width: 200, height: 400)
        feed.invalidateFrame()
        XCTAssertFalse(feed.live)
        do { _ = try await feed.snapshot(timeout: 0.03); XCTFail("Blank or suspended streams must not serve their cache") }
        catch { XCTAssertTrue(error is ScreenCaptureError) }
    }

    func testMissingPostActionFrameTimesOutWithoutUsingThePreviousImage() async {
        let feed = ScreenCaptureFeed()
        feed.show(Data([1]), width: 200, height: 400)
        do { _ = try await feed.image(after: now() + 1, timeout: 0.03); XCTFail("Expected a fresh image") }
        catch { XCTAssertTrue(error is ScreenCaptureError) }
    }

    func testWaitingForAFrameCanBeCancelled() async throws {
        let feed = ScreenCaptureFeed()
        feed.show(Data([1]), width: 200, height: 400)
        let job = Task { try await feed.image(after: now() + 1) }
        try await Task.sleep(for: .milliseconds(20)); job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStoppingWakesAnOutstandingScreenshotRequest() async throws {
        let feed = ScreenCaptureFeed()
        feed.show(Data([1]), width: 200, height: 400)
        let waiting = Task { try await feed.image(after: now() + 1, timeout: 5) }
        try await Task.sleep(for: .milliseconds(20))
        let stopped = now()
        await feed.stop()
        do { _ = try await waiting.value; XCTFail("A stopped session must reject pending screenshots") }
        catch { XCTAssertTrue(error is ScreenCaptureError) }
        XCTAssertLessThan(now() - stopped, 0.5)
    }

    func testStoppingInvalidatesCachedFramesAndSelectedImagesStayImmutable() async throws {
        let feed = ScreenCaptureFeed()
        feed.show(Data([1]), width: 200, height: 400)
        let selected = try await feed.image()
        feed.show(Data([2]), width: 200, height: 400)
        XCTAssertEqual(selected, Data([1]))
        await feed.stop()
        XCTAssertFalse(feed.live); XCTAssertNil(feed.frame)
        do { _ = try await feed.image(); XCTFail("Stopped capture cannot return a cache") }
        catch { XCTAssertTrue(error is ScreenCaptureError) }
    }
}
