import Foundation
import Testing
@testable import MediaEngine
@testable import RondoKit

/// Regressions from the P7 code review.
@Suite struct ReviewRegressionTests {
    private func info(rotation: Double?) -> MediaInfo {
        MediaInfo(duration: 2, bitRate: nil, formatName: "mov,mp4", fileSize: 1000, streams: [
            .init(index: 0, type: "video", codec: "h264", width: 320, height: 180, pixFmt: "yuv420p",
                  sampleRate: nil, channels: nil, channelLayout: nil, bitRate: nil, duration: 2, frameRate: 30,
                  bitsPerRawSample: nil, sampleFmt: nil, rotation: rotation, isAttachedPic: false),
        ])
    }

    @Test func concatCopyRequiresMatchingRotation() throws {
        let mp4 = try #require(VideoContainer.all.first { $0.id == "mp4" })
        #expect(FFmpegEngine.canConcatCopy([info(rotation: nil), info(rotation: 0)], container: mp4))
        #expect(FFmpegEngine.canConcatCopy([info(rotation: -90), info(rotation: 270)], container: mp4))
        #expect(!FFmpegEngine.canConcatCopy([info(rotation: nil), info(rotation: 90)], container: mp4))
    }

    @Test func rotationNormalization() {
        #expect(FFmpegEngine.normalizedRotation(nil) == 0)
        #expect(FFmpegEngine.normalizedRotation(-90) == 270)
        #expect(FFmpegEngine.normalizedRotation(450) == 90)
        #expect(FFmpegEngine.normalizedRotation(.infinity) == 0)
    }
}
