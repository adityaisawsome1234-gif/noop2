import Foundation
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore

extension AppModel {
    /// Runs the read-only compatibility test: connects, observes data paths for up to `seconds`, optionally
    /// performs one history sync (only if the user enabled history), and validates decoded fields against
    /// independent evidence. Records a raw capture while running.
    public func runCompatibilityTest(seconds: Int = 60) async {
        guard !isDemo, selectedDevice != nil, !isRunningCompatibilityTest else { return }
        isRunningCompatibilityTest = true
        defer { isRunningCompatibilityTest = false }
        diagnostics.checks = CompatibilityCheck.plan.map {
            var c = $0
            c.status = .running
            return c
        }
        let wasCapturing = diagnostics.captureEnabled
        setCaptureEnabled(true)
        if connection.link != .connected { central.connectSelected(profile: Self.connectionProfile) }
        let startCounters = diagnostics.counters
        let deadline = timeSource.now() + Int64(seconds) * 1_000
        var requestedHistory = false
        while timeSource.now() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
            if connection.link == .connected, historySyncMode != .off, !requestedHistory, timeSource.now() > deadline - Int64(seconds) * 1_000 + 10_000 {
                requestedHistory = true
                await syncNow()
            }
            let c = diagnostics.counters
            if c.standardHRNotifications > startCounters.standardHRNotifications, c.framesValid > startCounters.framesValid { break }
        }
        finishChecks(startCounters: startCounters, requestedHistory: requestedHistory)
        await validateHistoryHeartRate()
        if !wasCapturing { setCaptureEnabled(false) }
        await refreshNow()
    }

    func finishChecks(startCounters: DiagnosticsCounters, requestedHistory: Bool) {
        let c = diagnostics.counters
        if diagnostics.checks.first(where: { $0.id == "connect" })?.status == .running {
            updateCheck("connect", .failed, "No connection within the test window. Keep the band close and charged.")
        }
        if diagnostics.checks.first(where: { $0.id == "gatt" })?.status == .running {
            updateCheck("gatt", .failed, "Services were not discovered.")
        }
        let hr = c.standardHRNotifications - startCounters.standardHRNotifications
        if diagnostics.checks.first(where: { $0.id == "standardHR" })?.status == .running {
            updateCheck("standardHR", hr > 0 ? .passed : .unverified,
                        hr > 0 ? "\(hr) measurements received; \(c.standardHRWithRR - startCounters.standardHRWithRR) contained beat-to-beat intervals."
                               : "No standard heart-rate measurements arrived. The band may need heart-rate broadcast enabled.")
        }
        let frames = c.framesValid - startCounters.framesValid
        let malformed = c.framesMalformed - startCounters.framesMalformed
        updateCheck("vendorFrames", frames > 0 && malformed == 0 ? .passed : (malformed > 0 ? .failed : .unverified),
                    frames > 0 ? "\(frames) checksum-valid frames, \(malformed) malformed, \(c.unknownPackets) of unknown type."
                               : "No vendor frames were received.")
        updateCheck("hello", c.commandsSent > startCounters.commandsSent ? .unverified : .notApplicable,
                    "The identification request was sent; its response layout is not documented, so it is recorded in the capture for review.")
        updateCheck("liveHR", hr > 0 ? .passed : .unverified,
                    hr > 0 ? "Plausible live heart rate received." : "No live heart rate observed during the test.")
        if !requestedHistory {
            updateCheck("history", .notApplicable, historySyncMode == .off ? "History sync is off (your choice)." : "Not run in this test.")
        } else if diagnostics.checks.first(where: { $0.id == "history" })?.status == .running {
            updateCheck("history", .unverified, "History was requested but did not complete within the test window.")
        }
        if diagnostics.checks.first(where: { $0.id == "clock" })?.status == .running {
            updateCheck("clock", .notApplicable, "Reading the band clock is not supported yet for this band; band timestamps are checked for plausibility instead.")
        }
    }

    /// Validates band-history heart rate against overlapping standard heart rate and records the result
    /// per adapter and firmware. Only a pass makes history heart rate eligible for metrics.
    public func validateHistoryHeartRate() async {
        guard let store = liveStore, let device = selectedDevice, let adapter = currentAdapter else {
            updateCheck("fieldAgreement", .notApplicable, "No band connected.")
            return
        }
        let window = TimeRange(start: timeSource.now() - 7 * EpochMillis.millisPerDay, end: timeSource.now())
        let samples = (try? store.heartRates(in: window, deviceID: device.id)) ?? []
        let result = FieldValidator.historyHeartRateAgreement(history: samples, live: samples)
        updateCheck("fieldAgreement", result.status, result.detail)
        let key = FieldValidator.historyHeartRateKey(adapterID: adapter.adapterID, firmware: device.firmwareVersion)
        if result.status == .passed || result.status == .failed {
            setStoreSetting(result.status == .passed ? "passed" : "failed", key)
            invalidateAllDerived()
        }
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
