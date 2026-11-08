import Foundation
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore

extension AppModel {
    /// Live heart-rate values (in the plausible range, no more than `compatibilityMaxLiveGapMillis` apart)
    /// the compatibility test wants to see before it calls live heart rate working.
    static let compatibilityLiveReadings = 5
    static let compatibilityMaxLiveGapMillis: Int64 = 5_000

    /// Runs the read-only compatibility test: connects, observes data paths for up to `seconds`, optionally
    /// performs one history sync (only if the user enabled history), and validates decoded fields against
    /// independent evidence. Records a raw capture while running. With "Collect from band" off, the band is
    /// connected for the test only and released afterwards.
    public func runCompatibilityTest(seconds: Int = 60) async {
        guard !isDemo, selectedDevice != nil, !isRunningCompatibilityTest else { return }
        isRunningCompatibilityTest = true
        defer { isRunningCompatibilityTest = false }
        let collectionWasOff = !collectionEnabled
        diagnostics.checks = CompatibilityCheck.plan.map {
            var c = $0
            c.status = .running
            return c
        }
        testLiveReadingTimes = []
        testCommandNames = []
        let wasCapturing = diagnostics.captureEnabled
        setCaptureEnabled(true)
        if connection.link == .connected {
            // Already connected: the link was set up before the test started, so report what it showed.
            recordLinkChecks()
        } else {
            central.connectSelected(profile: Self.connectionProfile)
        }
        let startCounters = diagnostics.counters
        let start = timeSource.now()
        let deadline = start + Int64(seconds) * 1_000
        let wantsHistory = historySyncMode != .off
        var requestedHistory = false
        while timeSource.now() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
            if connection.link == .connected, wantsHistory, !requestedHistory, timeSource.now() >= start + 10_000 {
                requestedHistory = true
                await syncNow()
            }
            // Stop early only once every observable check has had its chance.
            let c = diagnostics.counters
            let hasVendorPath = diagnostics.services.contains { UUIDs.equal($0.uuid, Whoop5Adapter.service) }
            let vendorSeen = !hasVendorPath || c.framesValid > startCounters.framesValid
            let historyResolved = !wantsHistory || (requestedHistory && checkStatus("history") != .running)
            if checkStatus("connect") != .running, testLiveReadingTimes.count >= Self.compatibilityLiveReadings,
               vendorSeen, historyResolved { break }
        }
        finishChecks(startCounters: startCounters, requestedHistory: requestedHistory)
        await validateHistoryHeartRate()
        if !wasCapturing { setCaptureEnabled(false) }
        if collectionWasOff && !collectionEnabled {
            // The test connected only for itself: restore "Collect from band: off".
            central.disconnect()
            stopEngine()
            connection.link = .disconnected(since: timeSource.now())
        }
        await refreshNow()
    }

    func finishChecks(startCounters: DiagnosticsCounters, requestedHistory: Bool) {
        let c = diagnostics.counters
        if checkStatus("connect") == .running {
            updateCheck("connect", .failed, "No connection within the test window. Keep the band close and charged.")
        }
        if checkStatus("gatt") == .running {
            updateCheck("gatt", .failed, "Services were not discovered.")
        }
        let hr = max(0, c.standardHRNotifications - startCounters.standardHRNotifications)
        let withRR = max(0, c.standardHRWithRR - startCounters.standardHRWithRR)
        if checkStatus("standardHR") == .running {
            updateCheck("standardHR", hr > 0 ? .passed : .unverified,
                        hr > 0 ? "\(hr) measurements received; \(withRR) contained beat-to-beat intervals."
                               : "No standard heart-rate measurements arrived. The band may need heart-rate broadcast enabled.")
        }
        let frames = max(0, c.framesValid - startCounters.framesValid)
        let malformed = max(0, c.framesMalformed - startCounters.framesMalformed)
        let unknown = max(0, c.unknownPackets - startCounters.unknownPackets)
        let hasVendorPath = diagnostics.services.contains { UUIDs.equal($0.uuid, Whoop5Adapter.service) }
        if !hasVendorPath && frames == 0 && malformed == 0 && checkStatus("connect") == .passed {
            updateCheck("vendorFrames", .notApplicable, "The band does not expose the vendor data service on this connection.")
        } else {
            updateCheck("vendorFrames", frames > 0 && malformed == 0 ? .passed : (malformed > 0 ? .failed : .unverified),
                        frames > 0 ? "\(frames) checksum-valid frames, \(malformed) malformed, \(unknown) of unknown type."
                                   : (malformed > 0 ? "\(malformed) malformed frames and no valid ones." : "No vendor frames were received."))
        }
        if testCommandNames.contains(AllowedCommand.identify.name) {
            updateCheck("hello", .unverified,
                        "The identification request was sent; its response layout is not documented, so it is recorded in the capture for review.")
        } else {
            updateCheck("hello", .notApplicable,
                        "Not observed in this test: Forma sends the read-only identification request once, right after the band connects, and none went out while the test ran.")
        }
        let readings = testLiveReadingTimes
        let longestGap = zip(readings, readings.dropFirst()).map { $1 - $0 }.max() ?? 0
        let gapText = DisplayFormat.number(Double(longestGap) / 1_000, digits: 1)
        if readings.count >= Self.compatibilityLiveReadings && longestGap <= Self.compatibilityMaxLiveGapMillis {
            updateCheck("liveHR", .passed,
                        "\(readings.count) heart-rate values in the plausible range arrived, at most \(gapText) s apart. (Sensor contact is not part of this check; readings without contact are flagged when stored.)")
        } else if readings.isEmpty {
            updateCheck("liveHR", .unverified, "No live heart rate in the plausible range was observed during the test.")
        } else {
            updateCheck("liveHR", .unverified,
                        "\(readings.count) heart-rate values in the plausible range arrived, up to \(gapText) s apart; at least \(Self.compatibilityLiveReadings) values no more than \(Self.compatibilityMaxLiveGapMillis / 1_000) s apart are needed.")
        }
        if !requestedHistory {
            updateCheck("history", .notApplicable, historySyncMode == .off ? "History sync is off (your choice)." : "Not run in this test.")
        } else if checkStatus("history") == .running {
            updateCheck("history", .unverified, "History was requested but did not complete within the test window.")
        }
        if checkStatus("clock") == .running {
            updateCheck("clock", .notApplicable, "Reading the band clock is not supported yet for this band; band timestamps are checked for plausibility instead.")
        }
    }

    struct HistoryValidationOutcome {
        var key: String
        var result: FieldValidationResult
    }

    /// The validation key of the selected band's current adapter and firmware.
    func currentHistoryValidationKey() -> String? {
        guard !isDemo, let device = selectedDevice,
              let adapter = currentAdapter ?? AdapterRegistry.adapter(for: device.family) else { return nil }
        return FieldValidator.historyHeartRateKey(adapterID: adapter.adapterID, firmware: device.firmwareVersion)
    }

    /// Compares the last 7 days of band-history heart rate decoded by the current adapter on the current
    /// firmware (other firmware's values are not evidence for this one) with live standard heart rate.
    /// Runs off the main actor.
    func evaluateHistoryHeartRate() async -> HistoryValidationOutcome? {
        guard let store = liveStore, let device = selectedDevice, let key = currentHistoryValidationKey() else { return nil }
        let end = timeSource.now()
        let window = TimeRange(start: end - 7 * EpochMillis.millisPerDay, end: end)
        let keys = liveBatchKeys
        let deviceID = device.id
        let result = await Task.detached(priority: .userInitiated) { () -> FieldValidationResult in
            let samples = (try? store.heartRates(in: window, deviceID: deviceID,
                                                 sources: [.deviceHistory, .standardHeartRateService])) ?? []
            let history = samples.filter { $0.source == .deviceHistory && keys.key(for: $0.batchID, in: store) == key }
            let live = samples.filter { $0.source == .standardHeartRateService }
            return FieldValidator.historyHeartRateAgreement(history: history, live: live)
        }.value
        return HistoryValidationOutcome(key: key, result: result)
    }

    /// Records a verdict. Cached values follow automatically: their fingerprint includes which
    /// adapter-and-firmware keys passed.
    func recordHistoryValidation(_ outcome: HistoryValidationOutcome) {
        updateCheck("fieldAgreement", outcome.result.status, outcome.result.detail)
        if outcome.result.status == .passed || outcome.result.status == .failed {
            setStoreSetting(outcome.result.status == .passed ? "passed" : "failed", outcome.key)
        }
    }

    /// Validates band-history heart rate against overlapping standard heart rate and records the result
    /// per adapter and firmware. Only a pass makes history heart rate eligible for metrics.
    public func validateHistoryHeartRate() async {
        guard let outcome = await evaluateHistoryHeartRate() else {
            updateCheck("fieldAgreement", .notApplicable, "No band selected.")
            return
        }
        recordHistoryValidation(outcome)
    }

    /// After a history transfer, history heart rate is validated automatically (in the foreground, off the
    /// main actor) as long as this adapter and firmware have no verdict yet.
    func runAutoValidationIfNeeded() async {
        guard autoValidationPending, sceneActivity != .background else { return }
        autoValidationPending = false
        guard let store = liveStore, let key = currentHistoryValidationKey(),
              ((try? store.setting(forKey: key)) ?? nil) == nil,
              let outcome = await evaluateHistoryHeartRate(),
              outcome.result.status == .passed || outcome.result.status == .failed else { return }
        recordHistoryValidation(outcome)
    }

    // MARK: Capture

    public func setCaptureEnabled(_ on: Bool) {
        diagnostics.captureEnabled = on
        try? liveStore?.setRawCaptureEnabled(on)
        Task { await engine?.setOptions(syncOptions()) }
    }

    public func clearCapture() {
        recorder.clear()
        diagnostics.capturedEntries = 0
    }

    /// The capture as JSON Lines, with a header describing device, firmware, parser and phone.
    public func makeCaptureData() throws -> Data {
        let header = CaptureHeader(createdAt: timeSource.now(), deviceFamily: selectedDevice?.family ?? .unknown,
                                   deviceName: selectedDevice?.name, firmwareVersion: selectedDevice?.firmwareVersion,
                                   adapterID: currentAdapter?.adapterID, parserVersion: currentAdapter?.parserVersion,
                                   appVersion: platform.appVersion, phoneOS: platform.osVersion,
                                   note: diagnostics.advertisement.isEmpty ? nil : "advertisement: " + diagnostics.advertisement
                                    .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        return try recorder.snapshot(header: header).encoded()
    }
}
