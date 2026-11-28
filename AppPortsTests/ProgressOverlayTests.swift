import Testing
@testable import AppPorts

struct ProgressOverlayTests {
    @Test("Hides byte progress when both copied and total bytes are zero")
    func hidesZeroByteProgress() {
        #expect(ProgressOverlay.formatProgress(copiedBytes: 0, totalBytes: 0) == nil)
    }

    @Test("Formats copied bytes when total bytes is unknown")
    func formatsCopiedBytesWithoutTotal() {
        let text = ProgressOverlay.formatProgress(copiedBytes: 1024 * 1024, totalBytes: 0)
        #expect(text != nil)
        #expect(text?.contains("/") == false)
    }

    @Test("Formats copied and total bytes when total is known")
    func formatsCopiedAndTotalBytes() {
        let text = ProgressOverlay.formatProgress(copiedBytes: 1024 * 1024, totalBytes: 4 * 1024 * 1024)
        #expect(text != nil)
        #expect(text?.contains("/") == true)
    }
}
