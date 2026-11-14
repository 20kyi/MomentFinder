import CoreGraphics
import Testing
@testable import MomentFinder

struct MediaLayoutTests {
    private let phonePortrait = CGSize(width: 390, height: 844)
    private let padLandscape = CGSize(width: 1194, height: 834)
    private let macWindow = CGSize(width: 1100, height: 760)

    @Test func fitsLandscapePhotoToWidth() {
        let frame = MediaLayout.frame(for: CGSize(width: 4032, height: 3024), in: phonePortrait)
        #expect(frame.width == 390)
        #expect(abs(frame.height - 292.5) < 0.01)
    }

    @Test func fillsWhenRatioIsAlmostTheScreen() {
        let screenshot = CGSize(width: 1179, height: 2556)
        #expect(MediaLayout.frame(for: screenshot, in: phonePortrait) == phonePortrait)
    }

    @Test func keepsPortraitPhotoWholeOnWideScreens() {
        let portrait = CGSize(width: 3024, height: 4032)
        for container in [padLandscape, macWindow] {
            let frame = MediaLayout.frame(for: portrait, in: container)
            #expect(frame.height == container.height)
            #expect(abs(frame.width - container.height * 0.75) < 0.01)
        }
    }

    @Test func keepsVerticalVideoWholeInPhoneLandscape() {
        let frame = MediaLayout.frame(for: CGSize(width: 1080, height: 1920), in: CGSize(width: 844, height: 390))
        #expect(frame.height == 390)
        #expect(abs(frame.width - 219.375) < 0.01)
    }

    @Test func fitsWidePanoramaInsideWindow() {
        let frame = MediaLayout.frame(for: CGSize(width: 8000, height: 2000), in: macWindow)
        #expect(frame.width == 1100)
        #expect(frame.height == 275)
    }

    @Test func returnsContainerWhenSizeUnknown() {
        #expect(MediaLayout.frame(for: .zero, in: macWindow) == macWindow)
    }
}
