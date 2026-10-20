import Testing
@testable import NoteBankKit

struct TimeTests {
    @Test func microsecondsRoundTrip() {
        let us: Int64 = 1_760_000_000_123_456
        #expect(Time.rfc3339(us) == "2025-10-09T08:53:20.123456Z")
        #expect(Time.micros(rfc3339: "2025-10-09T08:53:20.123456Z") == us)
    }

    @Test func goFractionsParseExactly() {
        #expect(Time.micros(rfc3339: "2025-10-09T08:53:20.5Z") == 1_760_000_000_500_000)
        #expect(Time.micros(rfc3339: "2025-10-09T08:53:20Z") == 1_760_000_000_000_000)
        #expect(Time.micros(rfc3339: "2025-10-09T08:53:20.123456789Z") == 1_760_000_000_123_456)
    }

    @Test func offsetsConvertToUTC() {
        #expect(Time.micros(rfc3339: "2025-10-09T10:53:20.123456+02:00") == 1_760_000_000_123_456)
        #expect(Time.micros(rfc3339: "2025-10-09T04:23:20.123456-04:30") == 1_760_000_000_123_456)
    }

    @Test func garbageIsNil() {
        for s in ["", "2025-10-09", "2025-10-09T08:53:20.12x456Z", "2025-10-09T08:53:20.Z",
                  "2025-10-09T08:53:20.1234567890Z", "2025-13-09T08:53:20Z", "2025-02-30T08:53:20Z",
                  "2025-10-09T24:53:20Z", "2025-10-09T08:53:20", "2025-10-09T08:53:20+0200"] {
            #expect(Time.micros(rfc3339: s) == nil, "\(s)")
        }
    }

    @Test func outputAlwaysHasSixDigitsAndZ() {
        #expect(Time.rfc3339(0) == "1970-01-01T00:00:00.000000Z")
        #expect(Time.rfc3339(-1) == "1969-12-31T23:59:59.999999Z")
        #expect(Time.micros(rfc3339: "1969-12-31T23:59:59.999999Z") == -1)
    }
}
