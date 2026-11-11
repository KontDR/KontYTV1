import Foundation

enum YouTubeHTTP {
    static func retrySeconds(_ response: HTTPURLResponse, now: Date = Date()) -> Double {
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let value = Double(raw), value.isFinite, value > 0 { return value }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) { return max(1, date.timeIntervalSince(now)) }
        }
        return 60
    }
    static func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 { throw YouTubeWebError.rateLimited(retrySeconds(response)) }
        if response.url?.host?.lowercased().hasPrefix("consent.") == true { throw YouTubeWebError.consent }
        if response.statusCode == 403 { throw YouTubeWebError.forbidden }
        guard (200...299).contains(response.statusCode) else { throw YouTubeWebError.http(response.statusCode) }
    }
}
