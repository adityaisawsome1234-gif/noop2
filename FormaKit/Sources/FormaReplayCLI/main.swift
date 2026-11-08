import Foundation
import FormaCore
import FormaProtocol
import FormaSync

// forma-replay — decode a Forma diagnostics capture (or raw payload hex) through the same adapter and
// sync pipeline the app uses, and print what was understood. Runs offline on macOS or Linux.
//
//   swift run forma-replay capture.jsonl                 # replay an exported capture (history acks are NOT replayed)
//   swift run forma-replay --payload-hex K24.hex         # decode one bare WHOOP 5.0 payload (wrapped in a frame)
//   swift run forma-replay --json capture.jsonl          # machine-readable summary

struct Options {
    var json = false
    var payloadHex: [String] = []
    var captures: [String] = []
}

func parseArguments() -> Options? {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    while let a = args.first {
        args = args.dropFirst()
        switch a {
        case "--json": o.json = true
        case "--payload-hex":
            guard let p = args.first else { return nil }
            o.payloadHex.append(p); args = args.dropFirst()
        case "-h", "--help": return nil
        default: o.captures.append(a)
        }
    }
    return (o.payloadHex.isEmpty && o.captures.isEmpty) ? nil : o
}

/// Sink that keeps everything in memory for the report (no database needed).
final class SummarySink: IngestSink, @unchecked Sendable {
    private let lock = NSLock()
    var hr: [HeartRateSample] = []
    var beats: [BeatInterval] = []
    var motion: [MotionEpoch] = []
    var aux: [AuxMeasurement] = []
    var cursor: SyncCursor?
    var batches = 0

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        lock.withLock {
            hr += batch.heartRates; beats += batch.beatIntervals; motion += batch.motion; aux += batch.aux
            if let c = batch.cursor { cursor = c }
            batches += 1
            return IngestResult(batchID: Int64(batches), inserted: batch.heartRates.count + batch.beatIntervals.count + batch.motion.count + batch.aux.count, duplicates: 0)
        }
    }
    func syncCursor(deviceID: String) throws -> SyncCursor? { lock.withLock { cursor } }
    func upsertDevice(_ device: DeviceRecord) throws {}
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws {}
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { 1 }
    func finishSyncRun(_ run: SyncRunRecord) throws {}
}

func hexBytes(_ text: String) -> [UInt8]? {
    let clean = text.filter { $0.isHexDigit }
    guard clean.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    return out
}

func describe(_ e: DecodedEvent) -> String {
    switch e {
    case .standardHeartRate(let bpm, let contact, let rr, _, _): return "standard HR \(bpm.map(String.init) ?? "none") bpm, contact \(contact.rawValue), \(rr.count) RR"
    case .realtimeHeartRate(let bpm, _, let status, _): return "realtime HR \(bpm) (\(status.rawValue))"
    case .historyRecord(let r):
        var s = "history K\(r.kind) counter \(r.counter) t=\(r.deviceSeconds) (\(Date(timeIntervalSince1970: TimeInterval(r.deviceSeconds)))) len \(r.payloadLength)"
        if let hr = r.heartRate { s += " HR-candidate \(hr) (\(r.heartRateStatus.rawValue))" }
        if let m = r.motion { s += String(format: " motion n=%d |a|=%.1f activity=%.2f (device counts)", m.sampleCount, m.meanMagnitude, m.activity) }
        return s
    case .historyMarker(let m): return "history \(m.kind.rawValue)\(m.ackToken.map { " token \($0.map { String(format: "%02x", $0) }.joined())" } ?? "")"
    case .commandResponse(let r): return "response cmd \(r.command) seq \(r.originSequence.map(String.init) ?? "?") result \(r.resultCode.map(String.init) ?? "?") data \(r.data.count) B"
    case .deviceEvent(let ev): return "event \(ev.name) (\(ev.eventID)) \(ev.data.count) B"
    case .batteryLevel(let p, _): return "battery \(p)%"
    case .clockReading(let s, _): return "clock \(s)"
    case .deviceInformation(let f, let v): return "\(f): \(v)"
    case .unknownPacket(let t, let n, let c, _): return "unknown packet type \(t) (\(n) B) on \(c)"
    case .malformed(let r, let n, let c, _): return "MALFORMED \(r) (\(n) B) on \(c)"
    case .discarded(let n, let c, _): return "discarded \(n) B on \(c)"
    }
}

func decodePayloadFile(_ path: String, json: Bool) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8), let payload = hexBytes(text) else {
        FileHandle.standardError.write(Data("cannot read hex payload from \(path)\n".utf8))
        return false
    }
    let decoder = Whoop5Decoder()
    let events = decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: Whoop5Adapter.frame(payload: payload), receivedAt: 0)
    if json {
        let lines = events.map { describe($0) }
        if let data = try? JSONSerialization.data(withJSONObject: ["file": path, "events": lines], options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    } else {
        print("\(path): \(payload.count)-byte payload")
        for e in events { print("  " + describe(e)) }
    }
    return events.allSatisfy { if case .malformed = $0 { return false } else { return true } }
}

func replayCapture(_ path: String, json: Bool) async -> Bool {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        return false
    }
    let decoded: (file: CaptureFile, skippedLines: [Int])
    do { decoded = try CaptureFile.decode(data) } catch {
        FileHandle.standardError.write(Data("\(path): \(error)\n".utf8))
        return false
    }
    let header = decoded.file.header
    guard let adapter = AdapterRegistry.adapter(for: header.deviceFamily) ?? AdapterRegistry.adapter(forDiscoveredServices: []) ?? Optional(Whoop5Adapter()) else {
        return false
    }
    // Per-event listing (decoder only), then the full pipeline for totals.
    let decoder = adapter.makeDecoder()
    var typeCounts: [String: Int] = [:]
    var listing: [String] = []
    for e in decoded.file.entries where e.dir == .rx {
        guard let bytes = hexBytes(e.d) else { continue }
        for ev in decoder.decode(characteristic: e.c, bytes: bytes, receivedAt: e.t) {
            let d = describe(ev)
            typeCounts[String(d.split(separator: " ").first ?? "?"), default: 0] += 1
            if listing.count < 2_000 { listing.append("\(e.t) \(d)") }
        }
    }
    let sink = SummarySink()
    // History acknowledgements are never replayed: the replay link has no band to talk to.
    let link = ReplayLink(entries: decoded.file.entries, services: [:])
    let device = DeviceRecord(id: "replay", family: header.deviceFamily, name: header.deviceName ?? "replay",
                              firmwareVersion: header.firmwareVersion, firstSeen: header.createdAt)
    let engine = SyncEngine(adapter: adapter, sink: sink, device: device, timeSource: SystemTimeSource(),
                            options: SyncOptions(history: .off, liveHeartRate: false, rawCapture: false, liveFlushIntervalMillis: 0,
                                                 identifyOnConnect: false))
    _ = await engine.run(link: link)
    let counters = await engine.currentCounters
    let hrValues = sink.hr.map(\.bpm)
    let summary: [String: Any] = [
        "file": path,
        "header": ["family": header.deviceFamily.rawValue, "firmware": header.firmwareVersion ?? "", "adapter": adapter.adapterID,
                   "parserVersion": adapter.parserVersion, "entries": decoded.file.entries.count, "skippedLines": decoded.skippedLines.count],
        "counters": ["framesValid": counters.framesValid, "framesMalformed": counters.framesMalformed, "bytesDiscarded": counters.bytesDiscarded,
                     "unknownPackets": counters.unknownPackets, "standardHR": counters.standardHRNotifications,
                     "standardHRWithRR": counters.standardHRWithRR, "historyRecords": counters.historyRecords,
                     "historyRecordsUnmapped": counters.historyRecordsUnmapped],
        "heartRate": ["samples": hrValues.count, "min": hrValues.min() ?? 0, "max": hrValues.max() ?? 0,
                      "unvalidated": sink.hr.filter { $0.quality.contains(.unvalidatedField) }.count],
        "beatIntervals": sink.beats.count,
        "motionEpochs": sink.motion.count,
        "eventTypes": typeCounts,
    ]
    if json {
        if let out = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: out, as: UTF8.self))
        }
    } else {
        print("Capture \(path)")
        print("  family \(header.deviceFamily.rawValue), firmware \(header.firmwareVersion ?? "unknown"), adapter \(adapter.adapterID) \(adapter.parserVersion)")
        print("  entries \(decoded.file.entries.count) (skipped lines: \(decoded.skippedLines.count))")
        print("  frames valid \(counters.framesValid), malformed \(counters.framesMalformed), discarded bytes \(counters.bytesDiscarded), unknown packets \(counters.unknownPackets)")
        print("  standard HR notifications \(counters.standardHRNotifications) (with RR: \(counters.standardHRWithRR))")
        print("  history records \(counters.historyRecords) (unmapped clock: \(counters.historyRecordsUnmapped))")
        print("  heart-rate samples \(hrValues.count)" + (hrValues.isEmpty ? "" : " range \(hrValues.min()!)–\(hrValues.max()!) bpm; unvalidated \(sink.hr.filter { $0.quality.contains(.unvalidatedField) }.count)"))
        print("  beat intervals \(sink.beats.count), motion epochs \(sink.motion.count)")
        print("  decoded events:")
        for line in listing.prefix(200) { print("    " + line) }
        if listing.count > 200 { print("    … \(listing.count - 200) more (use --json for totals)") }
    }
    return counters.framesMalformed == 0
}

guard let options = parseArguments() else {
    print("""
    usage: forma-replay [--json] <capture.jsonl>...
           forma-replay [--json] --payload-hex <file.hex>...
    Decodes Forma diagnostics captures (or bare WHOOP 5.0 payloads) offline through Forma's adapter.
    """)
    exit(2)
}

var allOK = true
for p in options.payloadHex { allOK = decodePayloadFile(p, json: options.json) && allOK }
for c in options.captures { allOK = await replayCapture(c, json: options.json) && allOK }
exit(allOK ? 0 : 1)
