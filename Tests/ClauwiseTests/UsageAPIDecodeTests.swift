import Testing
import Foundation
@testable import Clauwise

private func loadFixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

@Test func goodResponseDecodes() throws {
    let data = loadFixture("good")
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)

    #expect(usage.five_hour?.utilization == 42.0)
    #expect(usage.seven_day?.utilization == 19.0)
    #expect(usage.extra_usage?.utilization == 17.5)
}

// monthly_limit/used_credits are minor currency units (e.g. pence) scaled by
// decimal_places, not already-scaled major units. A raw monthly_limit of 2000 with decimal_places 2 must
// scale to 20.0, not display as 2000.00.
@Test func extraUsageScalesMinorUnitsToMajorUnits() throws {
    let data = loadFixture("good")
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)

    #expect(usage.extra_usage?.scaledMonthlyLimit == 20.0)
    #expect(usage.extra_usage?.scaledUsedCredits == 3.5)
}

// decimal_places is sometimes absent; must default to 2 (the common case)
// rather than leaving the raw minor-unit value unscaled.
@Test func extraUsageDefaultsToTwoDecimalPlacesWhenMissing() throws {
    let json = """
    {"extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 0}}
    """
    let usage = try JSONDecoder().decode(UsageResponse.self, from: json.data(using: .utf8)!)

    #expect(usage.extra_usage?.scaledMonthlyLimit == 100.0)
    #expect(usage.extra_usage?.scaledUsedCredits == 0.0)
}

// Covers an unmodeled field (limits[2].scope) changing from String to object, plus a type mismatch on a field this app
// DOES depend on (extra_usage.utilization). Asserts the failure stays
// contained to extra_usage instead of cascading to five_hour/seven_day —
// the blast-radius regression this test guards against.
@Test func hostileResponseContainsDamageToAffectedField() throws {
    let data = loadFixture("hostile")
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)

    #expect(usage.five_hour?.utilization == 42.0, "unrelated field must survive a shape break elsewhere")
    #expect(usage.seven_day?.utilization == 19.0, "unrelated field must survive a shape break elsewhere")
    #expect(usage.extra_usage == nil, "the field with the actual type mismatch should be nil, not throw")
}
