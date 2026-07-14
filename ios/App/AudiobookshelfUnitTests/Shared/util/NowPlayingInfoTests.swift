import XCTest
import MediaPlayer
@testable import Audiobookshelf

final class NowPlayingInfoTests: XCTestCase {
    override func tearDown() {
        NowPlayingInfo.shared.reset()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    /// The system expects `MPNowPlayingInfoPropertyMediaType` to be an `MPNowPlayingInfoMediaType`
    /// raw value (a number). A string value is type-mismatched and is treated as `.none`, which can
    /// change how CarPlay / the lock screen lay out the Now Playing template. This guards against the
    /// regression where the media type was published as the string "hls".
    func testMediaTypeIsPublishedAsAudioNumberNotString() {
        let metadata = NowPlayingMetadata(
            id: "id-1", itemId: "item-1", title: "Chapter 1", author: "Author", series: nil, isLocal: false
        )

        NowPlayingInfo.shared.setMetadata(artwork: nil, metadata: metadata)

        // setMetadata publishes to MPNowPlayingInfoCenter via DispatchQueue.main.async. The main queue
        // is serial FIFO, so a block enqueued now runs after the publish; wait for it, then read back.
        let published = expectation(description: "now playing info published")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 2.0)

        let mediaType = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType]
        XCTAssertEqual(
            (mediaType as? NSNumber)?.uintValue,
            MPNowPlayingInfoMediaType.audio.rawValue,
            #"MediaType must be MPNowPlayingInfoMediaType.audio, not the string "hls""#
        )
    }
}
