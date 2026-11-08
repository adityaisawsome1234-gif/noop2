import Foundation
import Testing
import FormaCore
@testable import FormaStore

private let hour = EpochMillis.millisPerHour

private func session(_ kind: SessionKind, _ start: EpochMillis, _ end: EpochMillis, origin: SessionOrigin = .manual,
                     label: String? = nil) -> Session {
    Session(kind: kind, range: TimeRange(start: start, end: end), origin: origin, label: label, deviceID: deviceA,
            detector: origin == .detectedCandidate ? "sleep-detector/1" : nil,
            confidence: origin == .detectedCandidate ? 0.8 : nil, createdAt: t0, updatedAt: t0)
}

private func derivedRecord(_ metricID: String, _ start: EpochMillis, _ end: EpochMillis, value: Double?,
                           version: Int = 1, coverage: Double? = 0.95, computedAt: EpochMillis = t0) -> DerivedMetricRecord {
    DerivedMetricRecord(metricID: metricID, specVersion: version, window: TimeRange(start: start, end: end), value: value,
                        unit: "ms", availability: value == nil ? "insufficientData" : "available", coverage: coverage,
                        confidence: value == nil ? .none : .high, inputsJSON: "{\"beats\":\"512\"}", computedAt: computedAt)
}

@Suite("Sessions and corrections")
struct SessionTests {
    @Test func insertAndQuerySessions() throws {
        let store = try makeStore()
        let sleep = try store.insertSession(session(.sleep, t0, t0 + 8 * hour, label: "Night"))
        let workout = try store.insertSession(session(.workout, t0 + 10 * hour, t0 + 11 * hour, label: "Run"))
        let candidate = try store.insertSession(session(.workout, t0 + 12 * hour, t0 + 13 * hour, origin: .detectedCandidate))
        let deleted = try store.insertSession(session(.workout, t0 + 14 * hour, t0 + 15 * hour))
        try store.softDeleteSession(id: deleted)

        #expect(try store.sessions().compactMap(\.id) == [sleep, workout, candidate])
        #expect(try store.sessions(kind: .workout).compactMap(\.id) == [workout, candidate])
        #expect(try store.sessions(kind: .workout, includeCandidates: false).compactMap(\.id) == [workout])
        #expect(try store.sessions(includeDeleted: true).compactMap(\.id) == [sleep, workout, candidate, deleted])
        #expect(try store.sessions(in: TimeRange(start: t0 + 7 * hour, end: t0 + 10 * hour + 1)).compactMap(\.id)
                    == [sleep, workout])
        // Half-open ranges: a session ending exactly at the query start does not overlap it.
        #expect(try store.sessions(in: TimeRange(start: t0 + 8 * hour, end: t0 + 9 * hour)).isEmpty)

        let stored = try #require(try store.session(id: sleep))
        #expect(stored == Session(id: sleep, kind: .sleep, range: TimeRange(start: t0, end: t0 + 8 * hour), origin: .manual,
                                  label: "Night", deviceID: deviceA, createdAt: t0, updatedAt: t0))
        let storedCandidate = try #require(try store.session(id: candidate))
        #expect(storedCandidate.confidence == 0.8)
        #expect(!storedCandidate.isConfirmed)
        #expect(try store.session(id: 12_345) == nil)
    }

    @Test func zeroLengthSessionsMatchAsInstants() throws {
        let store = try makeStore()
        let id = try store.insertSession(session(.workout, t0 + 5, t0 + 5))
        #expect(try store.sessions(in: TimeRange(start: t0, end: t0 + 10)).compactMap(\.id) == [id])
        #expect(try store.sessions(in: TimeRange(start: t0 + 5, end: t0 + 6)).compactMap(\.id) == [id])
        #expect(try store.sessions(in: TimeRange(start: t0 + 6, end: t0 + 10)).isEmpty)
        #expect(try store.sessions(in: TimeRange(start: t0, end: t0 + 5)).isEmpty)
    }

    @Test func editWritesOneCorrectionPerChangedFieldAndReturnsTheAffectedRange() throws {
        let time = ManualTimeSource(t0 + 20 * hour)
        let store = try makeStore(time: time)
        let id = try store.insertSession(session(.sleep, t0, t0 + 8 * hour, origin: .detectedCandidate))
        var edited = try #require(try store.session(id: id))
        edited.range = TimeRange(start: t0 - hour, end: t0 + 7 * hour)
        edited.origin = .userEdited
        edited.label = "Long night"
        let affected = try store.updateSession(edited)
        #expect(affected == TimeRange(start: t0 - hour, end: t0 + 8 * hour))

        let corrections = try store.corrections(sessionID: id)
        #expect(corrections.map(\.field) == ["start", "end", "label", "origin"])
        #expect(corrections.map(\.oldValue) == [String(t0), String(t0 + 8 * hour), nil, "detectedCandidate"])
        #expect(corrections.map(\.newValue) == [String(t0 - hour), String(t0 + 7 * hour), "Long night", "userEdited"])
        #expect(corrections.allSatisfy { $0.createdAt == t0 + 20 * hour && $0.sessionID == id && $0.id != nil })

        let stored = try #require(try store.session(id: id))
        #expect(stored.range == edited.range)
        #expect(stored.origin == .userEdited)
        #expect(stored.updatedAt == t0 + 20 * hour)
        #expect(stored.createdAt == t0)
        #expect(stored.isConfirmed)

        // Moving the session to a disjoint window affects both windows (the covering range).
        time.advance(byMillis: 1_000)
        edited.range = TimeRange(start: t0 + 30 * hour, end: t0 + 31 * hour)
        edited.kind = .workout
        #expect(try store.updateSession(edited) == TimeRange(start: t0 - hour, end: t0 + 31 * hour))
        #expect(try store.corrections(sessionID: id).map(\.field).suffix(3) == ["kind", "start", "end"])
    }

    @Test func unchangedEditWritesNothing() throws {
        let store = try makeStore()
        let id = try store.insertSession(session(.workout, t0, t0 + hour, label: "Ride"))
        let current = try #require(try store.session(id: id))
        #expect(try store.updateSession(current) == current.range)
        #expect(try store.corrections().isEmpty)
        #expect(try store.session(id: id) == current)
    }

    @Test func metadataChangesAreSavedWithoutCorrections() throws {
        let store = try makeStore(time: ManualTimeSource(t0 + 99))
        let id = try store.insertSession(session(.sleep, t0, t0 + hour, origin: .detectedCandidate))
        var current = try #require(try store.session(id: id))
        current.confidence = 0.5
        current.detector = "sleep-detector/2"
        try store.updateSession(current)
        #expect(try store.corrections().isEmpty)
        #expect(try store.session(id: id)?.confidence == 0.5)
        #expect(try store.session(id: id)?.updatedAt == t0 + 99)
    }

    @Test func softDeleteKeepsAnAuditTrail() throws {
        let store = try makeStore(time: ManualTimeSource(t0 + 5_000))
        let id = try store.insertSession(session(.workout, t0, t0 + hour))
        #expect(try store.softDeleteSession(id: id) == TimeRange(start: t0, end: t0 + hour))
        #expect(try store.sessions().isEmpty)
        let stored = try #require(try store.session(id: id))
        #expect(stored.deleted)
        #expect(!stored.isConfirmed)
        #expect(try store.corrections(sessionID: id).map { [$0.field, $0.oldValue, $0.newValue] }
                    == [["deleted", "false", "true"]])
        // Deleting again changes nothing; editing a deleted session is refused.
        try store.softDeleteSession(id: id)
        #expect(try store.corrections(sessionID: id).count == 1)
        #expect(throws: StoreError.notFound("session \(id) is deleted")) { try store.updateSession(stored) }
    }

    @Test func missingSessionsAndBadValuesAreRejected() throws {
        let store = try makeStore()
        #expect(throws: StoreError.invalidArgument("updateSession requires a session id")) {
            try store.updateSession(session(.sleep, t0, t0 + 1))
        }
        var ghost = session(.sleep, t0, t0 + 1)
        ghost.id = 77
        #expect(throws: StoreError.notFound("session 77")) { try store.updateSession(ghost) }
        #expect(throws: StoreError.notFound("session 78")) { try store.softDeleteSession(id: 78) }
        var overconfident = session(.sleep, t0, t0 + 1)
        overconfident.confidence = 1.5
        #expect(throws: StoreError.self) { try store.insertSession(overconfident) }
        overconfident.confidence = .nan
        #expect(throws: StoreError.self) { try store.insertSession(overconfident) }
        #expect(try store.sessions(includeDeleted: true).isEmpty)
    }
}

@Suite("Derived metrics")
struct DerivedTests {
    @Test func putDerivedUpsertsAndPreservesNilAsNil() throws {
        let store = try makeStore()
        let day = EpochMillis.millisPerDay
        let unavailable = derivedRecord("rmssd", t0, t0 + day, value: nil, coverage: nil)
        try store.putDerived([derivedRecord("rmssd", t0 - day, t0, value: 41.5), unavailable])
        #expect(try store.derived(metricID: "rmssd", in: everything) == [derivedRecord("rmssd", t0 - day, t0, value: 41.5),
                                                                           unavailable])
        let raw = try store.withConnectionForTesting { db in
            try db.query("SELECT typeof(value), typeof(coverage) FROM derived_metric WHERE start_ms = ?", [t0]) {
                [$0.string(0), $0.string(1)]
            }
        }
        #expect(raw == [["null", "null"]])

        // Same key: replaced, not duplicated.
        let recomputed = derivedRecord("rmssd", t0, t0 + day, value: 44, computedAt: t0 + 1)
        try store.putDerived([recomputed])
        #expect(try store.derived(metricID: "rmssd", in: TimeRange(start: t0, end: t0 + day)) == [recomputed])
        #expect(try store.tableCounts()["derived_metric"] == 2)
    }

    @Test func derivedQueriesUseOverlapAndOptionalSpecVersion() throws {
        let store = try makeStore()
        try store.putDerived([
            derivedRecord("resting_hr", t0, t0 + 100, value: 52),
            derivedRecord("resting_hr", t0, t0 + 100, value: 53, version: 2),
            derivedRecord("resting_hr", t0 + 100, t0 + 200, value: 51),
            derivedRecord("resting_hr", t0 + 150, t0 + 150, value: 50),
            derivedRecord("strain", t0, t0 + 100, value: 9.1),
        ])
        #expect(try store.derived(metricID: "resting_hr", in: TimeRange(start: t0 + 99, end: t0 + 101)).map(\.value)
                    == [52, 53, 51])
        #expect(try store.derived(metricID: "resting_hr", in: TimeRange(start: t0, end: t0 + 1000), specVersion: 2)
                    .map(\.value) == [53])
        #expect(try store.derived(metricID: "resting_hr", in: TimeRange(start: t0 + 150, end: t0 + 151)).map(\.value)
                    == [51, 50])
        #expect(try store.derived(metricID: "resting_hr", in: TimeRange(start: t0 + 200, end: t0 + 300)).isEmpty)
        #expect(try store.derived(metricID: "unknown", in: everything).isEmpty)
    }

    @Test func invalidationDeletesOverlappingWindowsOnly() throws {
        let store = try makeStore()
        try store.putDerived([
            derivedRecord("a", t0, t0 + 100, value: 1),
            derivedRecord("a", t0 + 100, t0 + 200, value: 2),
            derivedRecord("b", t0 + 50, t0 + 150, value: 3),
            derivedRecord("b", t0 + 300, t0 + 300, value: 4),
        ])
        #expect(try store.invalidateDerived(overlapping: TimeRange(start: t0 + 100, end: t0 + 120), metricID: "a") == 1)
        #expect(try store.derived(metricID: "a", in: everything).map(\.value) == [1])
        #expect(try store.invalidateDerived(overlapping: TimeRange(start: t0 + 90, end: t0 + 301)) == 3)
        #expect(try store.tableCounts()["derived_metric"] == 0)
        #expect(try store.invalidateDerived(overlapping: everything) == 0)
    }

    @Test func invalidDerivedRecordsAreRejectedAtomically() throws {
        let store = try makeStore()
        for bad in [derivedRecord("x", t0, t0 + 1, value: .infinity), derivedRecord("x", t0, t0 + 1, value: 1, coverage: 1.2),
                    derivedRecord("", t0, t0 + 1, value: 1)] {
            #expect(throws: StoreError.self) { try store.putDerived([derivedRecord("ok", t0, t0 + 1, value: 1), bad]) }
        }
        #expect(try store.tableCounts()["derived_metric"] == 0)
        try store.putDerived([])
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func stringSettingsRoundTrip() throws {
        let store = try makeStore()
        #expect(try store.setting(forKey: "units") == nil)
        try store.setSetting("metric", forKey: "units")
        try store.setSetting("imperial", forKey: "units")
        try store.setSetting("", forKey: "empty")
        #expect(try store.setting(forKey: "units") == "imperial")
        #expect(try store.setting(forKey: "empty") == "")
        #expect(try store.allSettings() == ["units": "imperial", "empty": ""])
        #expect(try store.removeSetting(forKey: "units"))
        #expect(try !store.removeSetting(forKey: "units"))
        #expect(try store.setting(forKey: "units") == nil)
        #expect(throws: StoreError.invalidArgument("setting key is empty")) { try store.setSetting("x", forKey: "") }
    }

    @Test func codableSettingsAndUserProfileRoundTrip() throws {
        let store = try makeStore()
        struct Preferences: Codable, Equatable {
            var zones: [Int]
            var showExperimental: Bool
        }
        try store.setCodableSetting(Preferences(zones: [50, 60, 70], showExperimental: false), forKey: "prefs")
        #expect(try store.codableSetting(Preferences.self, forKey: "prefs") == Preferences(zones: [50, 60, 70],
                                                                                         showExperimental: false))
        #expect(try store.codableSetting(Preferences.self, forKey: "absent") == nil)

        #expect(try store.userProfile() == nil)
        let profile = UserProfile(birthYear: 1988, sex: .female, maxHeartRateOverride: 188, restingHeartRateOverride: nil)
        try store.setUserProfile(profile)
        #expect(try store.userProfile() == profile)
        #expect(try store.setting(forKey: "user_profile")?.contains("\"birthYear\":1988") == true)
    }

    @Test func corruptStoredJSONThrowsInsteadOfReturningDefaults() throws {
        let store = try makeStore()
        try store.setSetting("{not json", forKey: StoreSettingKey.userProfile)
        #expect(throws: StoreError.self) { _ = try store.userProfile() }
    }

    @Test func rawCaptureFlagSurvivesReopen() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("settings.sqlite")
        do {
            let store = try FormaStore(path: path)
            try store.setRawCaptureEnabled(true)
        }
        let reopened = try FormaStore(path: path)
        #expect(try reopened.rawCaptureEnabled())
        try reopened.removeSetting(forKey: StoreSettingKey.rawCaptureEnabled)
        #expect(try reopened.rawCaptureEnabled() == false)
    }
}
