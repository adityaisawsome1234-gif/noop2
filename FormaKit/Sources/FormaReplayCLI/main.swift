import Foundation
import FormaCore
import FormaProtocol
import FormaSync

// forma-replay — decode a Forma diagnostics capture (or raw payload hex) through the same adapter and
// sync pipeline the app uses, and print what was understood. Runs offline on macOS or Linux.
//
//   swift run forma-replay capture.jsonl                 # replay an exported capture (history acks are NOT replayed;
//                                                        # records re-sent in later connections are counted once)
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

/// Sink that keeps everything in memory for the report (no database needed). It skips duplicates with the
/// same keys as the app's store (schema v2) — HR: (device, source, time) or (device, source, raw band
/// time) · beat intervals: device, source, record, index · motion: (device, source, time, epoch) or
/// (device, source, raw band time) · aux: device, source, kind, time — so a capture whose connections
/// each re-send the same history reports what the app would hold, not a multiple of it.
final class SummarySink: IngestSink, @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()
    var hr: [HeartRateSample] = []
    var beats: [BeatInterval] = []
    var motion: [MotionEpoch] = []
    var aux: [AuxMeasurement] = []
    var cursor: SyncCursor?
    var batches = 0
    var duplicates = 0

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        lock.withLock {
            var inserted = 0
            var skipped = 0
            /// Kept when none of its keys was seen; then all of them are remembered.
            func keep(_ key: String, or alternative: String? = nil) -> Bool {
                if keys.contains(key) || alternative.map(keys.contains) == true {
                    skipped += 1
                    return false
                }
                keys.insert(key)
                if let alternative { keys.insert(alternative) }
                inserted += 1
                return true
            }
            for s in batch.heartRates where keep("hr|\(s.deviceID)|\(s.source.rawValue)|\(s.timestamp)",
                                                 or: s.deviceTimeRaw.map { "hr-raw|\(s.deviceID)|\(s.source.rawValue)|\($0)" }) {
                hr.append(s)
            }
            for b in batch.beatIntervals where keep("rr|\(b.deviceID)|\(b.source.rawValue)|\(b.recordKey)|\(b.indexInRecord)") { beats.append(b) }
            for m in batch.motion where keep("m|\(m.deviceID)|\(m.source.rawValue)|\(m.timestamp)|\(m.epochMillis)",
                                             or: m.deviceTimeRaw.map { "m-raw|\(m.deviceID)|\(m.source.rawValue)|\($0)" }) {
                motion.append(m)
            }
            for a in batch.aux where keep("a|\(a.deviceID)|\(a.source.rawValue)|\(a.kind.rawValue)|\(a.timestamp)") { aux.append(a) }
            if let c = batch.cursor { cursor = c }
            batches += 1
            duplicates += skipped
            return IngestResult(batchID: Int64(batches), inserted: inserted, duplicates: skipped)
        }
    }
    func syncCursor(deviceID: String) throws -> SyncCursor? { lock.withLock { cursor } }
    func upsertDevice(_ device: DeviceRecord) throws {}
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws {}
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { 1 }
    func finishSyncRun(_ run: SyncRunRecord) throws {}
    /// In memory only: nothing survives the process, and replay never acknowledges anything.
    func ensureDurable() throws {}
}

func describe(_ e: DecodedEvent) -> String {
    switch e {
    case .standardHeartRate(let bpm, let contact, let rr, _, _): return "standard HR \(bpm.map(String.init) ?? "none") bpm, contact \(contact.rawValue), \(rr.count) RR"
    case .realtimeHeartRate(let bpm, _, let status, _): return "realtime HR \(bpm) (\(status.rawValue))"
    case .historyRecord(let r):
        var s = "history K\(r.kind) counter \(r.counter) t=\(r.deviceSeconds) (\(Date(timeIntervalSince1970: TimeInterval(r.deviceSeconds)))) len \(r.payloadLength)"
        if let hr = r.heartRate { s += " HR-candidate \(hr) (\(r.heartRateStatus.rawValue))" }
        if let m = r.motion { s += String(format: " motion n=%d |a|=%.1f activity=%.2f (device counts)", m.sampleCount, m.meanMagnitude, m.activity) }
        if !r.contentDecoded { s += " (content not decoded by Forma)" }
        return s
    case .historyMarker(let m): return "history \(m.kind.rawValue)\(m.ackToken.map { " token \($0.map { String(format: "%02x", $0) }.joined())" } ?? "")"
    case .commandResponse(let r): return "response cmd \(r.command) seq \(r.originSequence.map(String.init) ?? "?") result \(r.resultCode.map(String.init) ?? "?") data \(r.data.count) B"
    case .deviceEvent(let ev): return "event \(ev.name) (\(ev.eventID)) \(ev.data.count) B"
    case .batteryLevel(let p, _): return "battery \(p)%"
    case .clockReading(let s, let ms, _): return "clock \(s)\(ms.map { String(format: ".%03d", $0) } ?? "") (\(Date(timeIntervalSince1970: TimeInterval(s))))"
    case .deviceInformation(let f, let v): return "\(f): \(v)"
    case .unknownPacket(let t, let n, let c, _): return "unknown packet type \(t) (\(n) B) on \(c)"
    case .malformed(let r, let n, let c, _): return "MALFORMED \(r) (\(n) B) on \(c)"
    case .discarded(let n, let c, _): return "discarded \(n) B on \(c)"
    }
}

func decodePayloadFile(_ path: String, json: Bool) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        return false
    }
    guard let payload = HexCodec.decodeLoose(text), !payload.isEmpty else {
        FileHandle.standardError.write(Data("\(path): not hex (allowed: hex digits, whitespace, commas, colons, dashes, 0x prefixes)\n".utf8))
        return false
    }
    let framed: [UInt8]
    do { framed = try Whoop5Adapter.frame(payload: payload) } catch {
        FileHandle.standardError.write(Data("\(path): \(error)\n".utf8))
        return false
    }
    let decoder = Whoop5Decoder()
    let events = decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: framed, receivedAt: 0)
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
    // Per-event listing (decoder only, one decoder per connection), then the full pipeline for totals.
    let segments = ReplayLink.segments(of: decoded.file.entries)
    var typeCounts: [String: Int] = [:]
    var listing: [String] = []
    // The band's own outcome: history start, end-of-chunk and completion markers, whatever Forma made of them.
    var markers: [String: Int] = ["start": 0, "end": 0, "complete": 0]
    for segment in segments {
        let decoder = adapter.makeDecoder()
        for e in segment where e.dir == .rx {
            guard let bytes = HexCodec.decode(e.d) else { continue }
            for ev in decoder.decode(characteristic: e.c, bytes: bytes, receivedAt: e.t) {
                if case .historyMarker(let m) = ev { markers[m.kind.rawValue, default: 0] += 1 }
                let d = describe(ev)
                typeCounts[String(d.split(separator: " ").first ?? "?"), default: 0] += 1
                if listing.count < 2_000 { listing.append("\(e.t) \(d)") }
            }
        }
    }
    let sink = SummarySink()
    // One engine per recorded connection. The policy lets history that arrives be decoded and stored,
    // but nothing is ever requested or acknowledged: the replay link has no band to talk to.
    var counters = SyncCounters()
    for segment in segments {
        let link = ReplayLink(entries: segment, services: [:])
        let device = DeviceRecord(id: "replay", family: header.deviceFamily, name: header.deviceName ?? "replay",
                                  firmwareVersion: header.firmwareVersion, firstSeen: header.createdAt)
        let engine = SyncEngine(adapter: adapter, sink: sink, device: device, timeSource: SystemTimeSource(),
                                options: SyncOptions(history: .manual, acknowledgeHistory: false, liveHeartRate: false, rawCapture: false,
                                                     liveFlushIntervalMillis: 0, identifyOnConnect: false, readClockOnConnect: false,
                                                     timerIntervalMillis: 0))
        _ = await engine.run(link: link)
        let c = await engine.currentCounters
        counters.framesValid += c.framesValid
        counters.framesMalformed += c.framesMalformed
        counters.bytesDiscarded += c.bytesDiscarded
        counters.unknownPackets += c.unknownPackets
        counters.standardHRNotifications += c.standardHRNotifications
        counters.standardHRWithRR += c.standardHRWithRR
        counters.historyRecords += c.historyRecords
        counters.historyRecordsUnmapped += c.historyRecordsUnmapped
        counters.historyRecordsUndecoded += c.historyRecordsUndecoded
        counters.historyRecordsUnsolicited += c.historyRecordsUnsolicited
        counters.historyTimeCollisions += c.historyTimeCollisions
        counters.notificationGaps += c.notificationGaps
        counters.realtimeHRPackets += c.realtimeHRPackets
        counters.deviceEvents += c.deviceEvents
    }
    let hrValues = sink.hr.map(\.bpm)
    let summary: [String: Any] = [
        "file": path,
        "header": ["family": header.deviceFamily.rawValue, "firmware": header.firmwareVersion ?? "", "adapter": adapter.adapterID,
                   "parserVersion": adapter.parserVersion, "entries": decoded.file.entries.count, "skippedLines": decoded.skippedLines.count,
                   "connections": segments.count],
        "counters": ["framesValid": counters.framesValid, "framesMalformed": counters.framesMalformed, "bytesDiscarded": counters.bytesDiscarded,
                     "unknownPackets": counters.unknownPackets, "standardHR": counters.standardHRNotifications,
                     "standardHRWithRR": counters.standardHRWithRR, "historyRecords": counters.historyRecords,
                     "historyRecordsUnmapped": counters.historyRecordsUnmapped, "historyRecordsUndecoded": counters.historyRecordsUndecoded,
                     "historyTimeCollisions": counters.historyTimeCollisions, "notificationGaps": counters.notificationGaps,
                     "deviceEvents": counters.deviceEvents, "realtimeHRPackets": counters.realtimeHRPackets,
                     "duplicateRecordsSkipped": sink.duplicates],
        // No samples → null, never a fabricated 0.
        "heartRate": ["samples": hrValues.count, "min": hrValues.min().map { $0 as Any } ?? NSNull(),
                      "max": hrValues.max().map { $0 as Any } ?? NSNull(),
                      "unvalidated": sink.hr.filter { $0.quality.contains(.unvalidatedField) }.count],
        "beatIntervals": sink.beats.count,
        "motionEpochs": sink.motion.count,
        "eventTypes": typeCounts,
        "historyMarkers": markers,
    ]
    if json {
        if let out = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: out, as: UTF8.self))
        }
    } else {
        print("Capture \(path)")
        print("  family \(header.deviceFamily.rawValue), firmware \(header.firmwareVersion ?? "unknown"), adapter \(adapter.adapterID) \(adapter.parserVersion)")
        print("  entries \(decoded.file.entries.count) in \(segments.count) connection(s) (skipped lines: \(decoded.skippedLines.count))")
        print("  frames valid \(counters.framesValid), malformed \(counters.framesMalformed), discarded bytes \(counters.bytesDiscarded), unknown packets \(counters.unknownPackets)")
        print("  standard HR notifications \(counters.standardHRNotifications) (with RR: \(counters.standardHRWithRR))")
        print("  history records \(counters.historyRecords) (unmapped clock: \(counters.historyRecordsUnmapped); content not decoded: \(counters.historyRecordsUndecoded); same-time collisions: \(counters.historyTimeCollisions))")
        if counters.notificationGaps > 0 { print("  notifications lost by the link: \(counters.notificationGaps)") }
        print("  history markers from the band: start \(markers["start"] ?? 0), chunk end \(markers["end"] ?? 0), transfer complete \(markers["complete"] ?? 0)")
        print("  records already seen in an earlier connection (skipped, as the app's store would): \(sink.duplicates)")
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
