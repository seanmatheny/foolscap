import Testing
import Foundation
@testable import FoolscapScribe

@Suite struct ScribeZoomTests {
    /// A Scribe page is 1860 × 2480: taller than wide.
    let aspect: CGFloat = 2480.0 / 1860.0

    @Test func fitsTheHeightInANotebookArea() {
        let fit = ScribeZoomLayout.fitSize(area: CGSize(width: 850, height: 700), aspect: aspect)
        #expect(fit.height == 700 - ScribeZoomLayout.topInset - ScribeZoomLayout.bottomInset)
        #expect(abs(fit.width - fit.height / aspect) <= 1)
        #expect(fit.width + 2 * ScribeZoomLayout.sideInset < 850)
    }

    @Test func fitsTheWidthWhenTheAreaIsNarrow() {
        let fit = ScribeZoomLayout.fitSize(area: CGSize(width: 300, height: 1000), aspect: aspect)
        #expect(fit.width == 300 - 2 * ScribeZoomLayout.sideInset)
        #expect(abs(fit.height - fit.width * aspect) <= 1)
    }

    @Test func zoomIsClamped() {
        #expect(ScribeZoomLayout.clamp(0.2) == ScribeZoomLayout.minZoom)
        #expect(ScribeZoomLayout.clamp(9) == ScribeZoomLayout.maxZoom)
        #expect(ScribeZoomLayout.clamp(2.5) == 2.5)
    }

    @Test func renderWidthStepsUpAndNeverExceedsTheScribesPixels() {
        // 455 pt at 1× rounds up to the next 100 pt step.
        #expect(ScribeZoomLayout.renderWidth(fitWidth: 455, zoom: 1, backingScale: 2) == 500)
        // At 4× the bitmap would be 3640 pixels wide; it is capped at the renderer's limit.
        let capped = ScribeZoomLayout.renderWidth(fitWidth: 455, zoom: 4, backingScale: 2)
        #expect(Int(capped * 2) <= ScribePageRenderer.maxPixelWidth)
        #expect(capped == CGFloat(ScribePageRenderer.maxPixelWidth) / 2)
        // A 1× display is allowed twice the points for the same pixels: 1820 rounds up to the next step.
        #expect(ScribeZoomLayout.renderWidth(fitWidth: 455, zoom: 4, backingScale: 1) == 1900)
    }
}
