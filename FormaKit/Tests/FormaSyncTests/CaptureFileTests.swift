import Foundation
import Testing
import FormaCore
@testable import FormaSync

@Suite struct CaptureFileTests {
    @Test func roundTrip() throws {
        let header = CaptureHeader(createdAt: 5, deviceFamily: .whoop5, deviceName: "Band", firmwareVersion: "1.2.3")
        let file = CaptureFile(header: header, entries: [
            CaptureEntry(t: 10, dir: .rx, c: "2A37", d: "1648"),
            CaptureEntry(t: 11, dir: .event, c: "", d: "", note: "disconnected"),
        ])
        let data = try file.encoded()
        let (decoded, skipped) = try CaptureFile.decode(data)
        #expect(skipped.isEmpty)
        #expect(decoded.header == header)
        #expect(decoded.entries == file.entries)
    }

    @Test func rejectsNonCaptureAndNewerVersions() throws {
        #expect(throws: CaptureFileError.emptyFile) { _ = try CaptureFile.decode(Data()) }
        #expect(throws: CaptureFileError.notACapture) { _ = try CaptureFile.decode(Data("{\"x\":1}\n".utf8)) }
        let newer = Data("{\"format\":\"forma-capture\",\"version\":99,\"createdAt\":0,\"deviceFamily\":\"whoop5\"}\n".utf8)
        #expect(throws: CaptureFileError.unsupportedVersion(99)) { _ = try CaptureFile.decode(newer) }
    }

    @Test func skipsMalformedEntriesUnlessStrict() throws {
        let text = """
        {"format":"forma-capture","version":1,"createdAt":0,"deviceFamily":"whoop5"}
        {"t":1,"dir":"rx","c":"A","d":"zz"}
        not json
        {"t":2,"dir":"rx","c":"A","d":"0a0b"}
        """
        let (file, skipped) = try CaptureFile.decode(Data(text.utf8))
        #expect(file.entries.count == 1)
        #expect(skipped == [2, 3])
        #expect(throws: CaptureFileError.self) { _ = try CaptureFile.decode(Data(text.utf8), strict: true) }
    }

    @Test func recorderIsBounded() {
        let r = CaptureRecorder(maxEntries: 3)
        for i in 0..<5 { r.record(CaptureEntry(t: Int64(i), dir: .rx, c: "A", d: "00")) }
        let snap = r.snapshot(header: CaptureHeader(createdAt: 0, deviceFamily: .unknown))
        #expect(snap.entries.map(\.t) == [2, 3, 4])
        #expect(r.dropped == 2)
    }
}
