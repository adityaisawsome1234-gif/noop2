import Foundation
import Testing
import FormaCore
import FormaAnalytics

@Suite("Zones and maximum heart rate")
struct ZonesTests {
    /// 2026-11-08T12:00:00Z, supplied through a manual time source as the app would.
    let clock = ManualTimeSource(1_794_139_200_000)

    @Test func percentMaxLowerBoundsAreInclusive() throws {
        let zones = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 200, basis: .userOverride))
        let thresholds = try #require(zones.thresholds().value)
        #expect(thresholds.lowerBoundsBPM == [100, 120, 140, 160, 180])
        let expectations: [(Double, Int)] = [(99, 0), (99.999, 0), (100, 1), (119, 1), (120, 2), (139.999, 2), (140, 3),
                                             (160, 4), (179, 4), (180, 5), (200, 5), (230, 5)]
        for (bpm, zone) in expectations {
            #expect(zones.zone(forBPM: bpm) == zone, "bpm \(bpm)")
        }
        #expect(HeartRateZones.label(forZone: 0) == "below zones")
        #expect(HeartRateZones.label(forZone: 3) == "Zone 3")
    }

    @Test func boundaryValuesSurviveFloatingPointProducts() {
        // 0.6 × 190 and 0.7 × 190 are not exactly representable products; the bound must still be inclusive.
        let z190 = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 190, basis: .userOverride))
        #expect(z190.zone(forBPM: 113) == 1)
        #expect(z190.zone(forBPM: 114) == 2)
        #expect(z190.zone(forBPM: 133) == 3)
        #expect(z190.zone(forBPM: 171) == 5)
        let z187 = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 187, basis: .userOverride))
        #expect(z187.zone(forBPM: 93) == 0)   // 93.5 is the zone-1 bound
        #expect(z187.zone(forBPM: 94) == 1)
    }

    @Test func heartRateReserveUsesKarvonen() throws {
        let zones = HeartRateZones(model: .heartRateReserve, maxHeartRate: MaxHeartRate(bpm: 200, basis: .userOverride),
                                   restingHeartRate: 60)
        let thresholds = try #require(zones.thresholds().value)
        #expect(thresholds.lowerBoundsBPM == [130, 144, 158, 172, 186])
        #expect(zones.zone(forBPM: 129) == 0)
        #expect(zones.zone(forBPM: 130) == 1)
        #expect(zones.zone(forBPM: 186) == 5)

        let noRest = HeartRateZones(model: .heartRateReserve, maxHeartRate: MaxHeartRate(bpm: 200, basis: .userOverride))
        let unavailable = noRest.thresholds()
        expectInvariants(unavailable)
        #expect(unavailable.availability == .insufficientData(detail: HeartRateZones.missingRestingDetail))
        #expect(noRest.zone(forBPM: 150) == nil)

        let implausibleRest = HeartRateZones(model: .heartRateReserve, maxHeartRate: MaxHeartRate(bpm: 200, basis: .userOverride),
                                             restingHeartRate: 150)
        #expect(implausibleRest.thresholds().value == nil)
    }

    @Test func maxHeartRatePrecedenceOverrideThenAgeThenUnavailable() throws {
        let now = clock.now()
        let override = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990, maxHeartRateOverride: 195),
                                                    asOf: now, calendar: Fixture.utc)
        expectInvariants(override)
        #expect(override.value == MaxHeartRate(bpm: 195, basis: .userOverride))
        #expect(override.value?.label == "set by you")
        #expect(override.confidence == .high)

        let age = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: now, calendar: Fixture.utc)
        expectInvariants(age)
        let estimate = try #require(age.value)
        #expect(estimate.bpm == 182.8)          // 208 − 0.7 × 36
        #expect(estimate.ageYears == 36)
        #expect(estimate.basis == .estimatedFromAge)
        #expect(estimate.label == "estimated from age")
        #expect(age.confidence == .low)

        let none = MaxHeartRateResolver.resolve(profile: UserProfile(), asOf: now, calendar: Fixture.utc)
        expectInvariants(none)
        #expect(none.value == nil)
        #expect(none.confidence == .none)
        #expect(none.availability == .insufficientData(detail: "Set your max heart rate or birth year"))
    }

    @Test func invalidProfileInputsAreIgnoredNotTrusted() {
        let now = clock.now()
        let badOverride = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990, maxHeartRateOverride: 300),
                                                       asOf: now, calendar: Fixture.utc)
        #expect(badOverride.value?.basis == .estimatedFromAge)
        #expect(badOverride.inputs["ignoredOverride"] != nil)

        for year in [1900, 2030, Int.min, Int.max] {
            let r = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: year), asOf: now, calendar: Fixture.utc)
            expectInvariants(r)
            #expect(r.value == nil, "birth year \(year)")
        }
        let badDate = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: .max, calendar: Fixture.utc)
        #expect(badDate.value == nil)
    }

    @Test func ageIsTakenInTheCalendarsTimeZone() throws {
        // 2026-12-31T23:30:00Z is already 2027 in Tokyo.
        let instant: EpochMillis = 1_798_759_800_000
        let tokyo = try #require(Fixture.calendar("Asia/Tokyo"))
        let inUTC = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: instant, calendar: Fixture.utc)
        let inTokyo = MaxHeartRateResolver.resolve(profile: UserProfile(birthYear: 1990), asOf: instant, calendar: tokyo)
        #expect(inUTC.value?.ageYears == 36)
        #expect(inTokyo.value?.ageYears == 37)
    }

    @Test func invalidBoundariesDisableZones() {
        let hrMax = MaxHeartRate(bpm: 190, basis: .userOverride)
        for boundaries in [[], [0.6, 0.5], [0.5, 0.5], [0.5, 1.2], [0, 0.5], [Double.nan], [0.5, .infinity]] {
            let zones = HeartRateZones(boundaries: boundaries, maxHeartRate: hrMax)
            let t = zones.thresholds()
            expectInvariants(t)
            #expect(t.value == nil, "boundaries \(boundaries)")
        }
        #expect(HeartRateZones(maxHeartRate: nil).thresholds().availability
            == .insufficientData(detail: MaxHeartRateResolver.missingInputDetail))
    }

    @Test func resolveTakesRestingHeartRateFromProfileThenOvernightEstimate() {
        let now = clock.now()
        let withOverride = HeartRateZones.resolve(profile: UserProfile(maxHeartRateOverride: 190, restingHeartRateOverride: 55),
                                                  asOf: now, calendar: Fixture.utc, model: .heartRateReserve,
                                                  overnightRestingHeartRate: 48.5)
        #expect(withOverride.restingHeartRate == 55)
        let withEstimate = HeartRateZones.resolve(profile: UserProfile(maxHeartRateOverride: 190), asOf: now,
                                                  calendar: Fixture.utc, model: .heartRateReserve, overnightRestingHeartRate: 48.5)
        #expect(withEstimate.restingHeartRate == 48.5)
        #expect(withEstimate.thresholds().value?.lowerBoundsBPM.first == 48.5 + 0.5 * (190 - 48.5))
        #expect(withEstimate.maxHeartRate?.bpm == 190)
    }

    @Test func ageEstimatedHRmaxCapsZoneConfidence() {
        let zones = HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 182.8, basis: .estimatedFromAge, ageYears: 36))
        #expect(zones.thresholds().confidence == .moderate)
        #expect(HeartRateZones(maxHeartRate: MaxHeartRate(bpm: 190, basis: .userOverride)).thresholds().confidence == .high)
    }
}
