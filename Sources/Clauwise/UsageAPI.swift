import Foundation

// MARK: - Usage API

enum UsageAPIError: Error {
    case httpStatus(Int)
    case decode(Error)
}

// Not decoded from UsageResponse anymore (no field currently needs it),
// but kept: used elsewhere for notification-tier tracking and menu
// severity coloring (AppSettings.swift, Notifications.swift,
// Formatting.swift).
enum Severity: String, Codable {
    case normal, warning, critical

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Severity(rawValue: raw) ?? .normal
    }
}

struct LimitWindow: Codable {
    let utilization: Double?
    let resets_at: String?
}

// monthly_limit/used_credits are minor currency units (e.g. pence, not
// pounds) scaled by decimal_places: `"monthly_limit":10000,"decimal_places":2`
// means a 100.00 limit. Use `scaledMonthlyLimit`/`scaledUsedCredits`
// everywhere instead of the raw fields — they're the single source of truth
// for the /10^decimal_places conversion so no call site has to remember to scale.
struct ExtraUsage: Codable {
    let is_enabled: Bool?
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
    let currency: String?
    let decimal_places: Int?

    private var scale: Double { pow(10, Double(decimal_places ?? 2)) }
    var scaledMonthlyLimit: Double? { monthly_limit.map { $0 / scale } }
    var scaledUsedCredits: Double? { used_credits.map { $0 / scale } }
}

// Only the 3 top-level fields actually rendered anywhere in the app are
// modeled; unused fields would be pure decode surface with no benefit.
// `JSONDecoder` ignores unmodeled keys regardless of their JSON type, so
// omitting anything unused here is always safe and forward-compatible —
// the smaller this model, the less there is to break if the response shape
// changes. For example, an unmodeled field changing from String to object
// would, with a synthesized Codable conformance (which decodes atomically),
// take down the entire response, including the two fields (five_hour,
// seven_day) this app actually depends on. `init(from:)` below decodes each top-level
// field independently so that failure mode can't recur even for fields
// that ARE modeled: a shape regression in one field no longer cascades
// into the others.
struct UsageResponse {
    let five_hour: LimitWindow?
    let seven_day: LimitWindow?
    let extra_usage: ExtraUsage?
}

// MARK: - UsageClient
extension UsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, extra_usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.five_hour = Self.decodeLenient(LimitWindow.self, from: container, forKey: .five_hour)
        self.seven_day = Self.decodeLenient(LimitWindow.self, from: container, forKey: .seven_day)
        self.extra_usage = Self.decodeLenient(ExtraUsage.self, from: container, forKey: .extra_usage)
    }

    private static func decodeLenient<T: Decodable>(
        _ type: T.Type, from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) -> T? {
        do {
            return try container.decodeIfPresent(type, forKey: key)
        } catch {
            log("usage decode: field '\(key.stringValue)' skipped — \(error)")
            return nil
        }
    }
}

final class UsageClient {
    let store = CredentialStore()
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch() async throws -> UsageResponse {
        let token = try store.validAccessToken()
        var req = URLRequest(url: Self.usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("clauwise/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            log("usage fetch http status=\(code)")
            throw UsageAPIError.httpStatus(code)
        }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            log("usage decode error: \(type(of: error))")
            throw UsageAPIError.decode(error)
        }
    }
}
