import Foundation
import Testing
@testable import DocEngine

@Suite struct SubtitleTests {
    @Test func tolerantSRT() throws {
        // BOM, CRLF, missing index on cue 2, no blank line before cue 3, junk index, trailing spaces.
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\nHello <i>there</i>\r\n\r\n"
            + "00:00:03,000 --> 00:00:04,000  \r\nNo index here\r\n"
            + "3\r\n00:00:05.250 --> 00:00:06,000\r\nThird\r\nline two\r\n"
        let cues = Subtitles.parse(srt)
        try #require(cues.count == 3)
        #expect(cues[0] == .init(start: 1, end: 2.5, lines: ["Hello <i>there</i>"]))
        #expect(cues[1].lines == ["No index here"], "index line must not leak into the previous cue")
        #expect(cues[2].start == 5.25 && cues[2].lines == ["Third", "line two"])
    }

    @Test func tolerantVTT() throws {
        let vtt = """
        WEBVTT - Title
        Kind: captions
        Language: en

        NOTE this is a comment
        spanning lines

        STYLE
        ::cue { color: red }

        intro
        00:01.000 --> 00:02.000 align:start position:10%
        <v Bob>Hi &amp; bye</v>

        01:00:00.000 --> 01:00:01.500
        <c.loud>Late</c> <00:00:01.200>cue
        """
        let cues = Subtitles.parse(vtt)
        try #require(cues.count == 2)
        #expect(cues[0].start == 1 && cues[0].end == 2)
        #expect(cues[1].start == 3600 && cues[1].end == 3601.5)
        let srt = Subtitles.srt(cues)
        #expect(srt.hasPrefix("1\n00:00:01,000 --> 00:00:02,000\nHi & bye\n\n2\n01:00:00,000 --> 01:00:01,500\nLate cue\n"))
    }

    @Test func srtToVTTEscapesAndKeepsBasicTags() {
        let cues = [Subtitles.Cue(start: 0.5, end: 1, lines: ["<i>a</i> & <font color=\"red\">b</font> < c --> d"])]
        let vtt = Subtitles.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:01.000\n"))
        #expect(vtt.contains("<i>a</i> &amp; b &lt; c -&gt; d"))
    }

    @Test func plainTextStripsTimingAndTags() {
        let cues = Subtitles.parse("1\n00:00:01,000 --> 00:00:02,000\n<b>Hello</b>\nworld\n\n2\n00:00:02,000 --> 00:00:03,000\n<b>Hello</b>\nworld\n\n3\n00:00:03,000 --> 00:00:04,000\nBye &amp; thanks\n")
        #expect(Subtitles.plainText(cues) == "Hello world\nBye & thanks\n")
    }

    @Test func roundTripThroughEngine() async throws {
        let dir = try W5.dir("subs")
        let srt = try W5.write("1\n00:00:01,000 --> 00:00:02,000\nFirst\n\n2\n00:01:02,345 --> 00:01:04,000\nSecond <b>bold</b>\n", to: dir, name: "movie.srt")
        let vtt = try await W5.one(srt, to: "vtt")
        let vttText = try W5.text(vtt)
        #expect(vttText.hasPrefix("WEBVTT"))
        #expect(vttText.contains("00:01:02.345 --> 00:01:04.000"))
        let back = try await W5.one(vtt, to: "srt", out: dir.appendingPathComponent("back"))
        let backText = try W5.text(back)
        #expect(backText.contains("-->"))
        #expect(Subtitles.parse(backText) == Subtitles.parse(try W5.text(srt)))
        let txt = try W5.text(try await W5.one(srt, to: "txt"))
        #expect(txt == "First\nSecond bold\n")
    }

    @Test func emptyInputFails() async throws {
        let dir = try W5.dir("subs-empty")
        let srt = try W5.write("just some text\n", to: dir, name: "empty.srt")
        await #expect(throws: (any Error).self) { try await W5.one(srt, to: "vtt") }
    }

    @Test func timestamps() {
        #expect(Subtitles.timestamp("00:00:01,5") == 1.5)
        #expect(Subtitles.timestamp("1:02:03.004") == 3723.004)
        #expect(Subtitles.timestamp("02:03.004") == 123.004)
        #expect(Subtitles.timestamp("abc") == nil)
        #expect(Subtitles.stamp(3723.004, sep: ",") == "01:02:03,004")
    }
}
