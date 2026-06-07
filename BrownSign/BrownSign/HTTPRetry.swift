//
//  HTTPRetry.swift
//  BrownSign
//
//  Shared retry helper for HTTP fetches against external services
//  (Wikidata Query Service, Wikipedia API/REST). All of these can
//  occasionally hiccup with 502/503 or brief network failures —
//  retrying once or twice with backoff is enough to ride out the
//  vast majority. Single source of truth so SPARQL and Wikipedia
//  hydration apply the same policy.
//

import Foundation

/// Descriptive User-Agent sent on every outbound API request. Wikimedia's
/// API etiquette *requires* a non-generic User-Agent that identifies the
/// app and gives a contact URL; requests with a missing or generic UA can
/// be throttled or 403'd. Built from the bundle version at runtime so it
/// can never drift out of sync with the shipped release (it previously
/// hard-coded "1.2" while the app was at 1.4.x). NPS and Google don't
/// require it, but identifying ourselves there is good manners too.
nonisolated let brownSignUserAgent: String = {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    return "BrownSign-iOS/\(version) (https://github.com/smandable/brown-sign)"
}()

/// Builds a `URLRequest` carrying the shared `brownSignUserAgent` and a
/// sane per-request timeout. Use for every outbound API call so the
/// User-Agent and timeout policy live in one place instead of being
/// re-specified — or, as was the case, silently omitted — at each call
/// site. Without an explicit timeout, requests inherit URLSession's 60 s
/// default and can hang that long on a stalled connection.
nonisolated func apiRequest(_ url: URL, timeout: TimeInterval = 15) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(brownSignUserAgent, forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = timeout
    return request
}

/// Parse `data` as a top-level JSON object. Shared so the search providers
/// don't each repeat the `JSONSerialization` + cast dance. Returns nil on
/// malformed input or a non-object root.
nonisolated func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// HTTP status codes worth retrying. 502/503/504 are the canonical
/// transient backend failures; 429 (rate-limited) gets the same
/// backoff — strictly we'd honor Retry-After, but our request
/// volume is low enough that the fixed ladder is fine.
nonisolated func isTransientHTTPStatus(_ code: Int) -> Bool {
    return code == 429 || code == 502 || code == 503 || code == 504
}

/// Fetches `request` with retry on transient errors (5xx in the
/// retryable set + 429 + URL-level errors). Returns response data
/// on 2xx success, or nil on 4xx client errors (no point retrying
/// a broken query) and on retry exhaustion. Honors Task
/// cancellation: if the parent task is cancelled mid-retry — user
/// panned the map again, hit refresh a second time — bails out
/// without further attempts.
///
/// Default policy: 3 attempts with 500 ms + 1.5 s backoff. With
/// `maxAttempts = 3` the cadence is: try → wait 500 ms → try →
/// wait 1.5 s → try. Worst case for a transient hiccup is ~2 s
/// before the third attempt succeeds.
nonisolated func httpDataWithRetry(
    _ request: URLRequest,
    maxAttempts: Int = 3,
    delays: [UInt64] = [500_000_000, 1_500_000_000]
) async -> Data? {
    for attempt in 0..<maxAttempts {
        if Task.isCancelled { return nil }

        var transient = false
        var serverRetryAfter: UInt64?
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let code = http.statusCode
                if (200...299).contains(code) {
                    return data
                }
                if !isTransientHTTPStatus(code) {
                    return nil
                }
                transient = true
                // On 429, back off for as long as the server's Retry-After
                // asks (capped) instead of the fixed ladder — that's what the
                // rate-limit response is telling us to do.
                if code == 429,
                   let header = http.value(forHTTPHeaderField: "Retry-After") {
                    serverRetryAfter = parseRetryAfter(header)
                }
            } else {
                transient = true
            }
        } catch is CancellationError {
            return nil
        } catch {
            transient = true
        }

        if transient, attempt < maxAttempts - 1 {
            // Prefer Retry-After; otherwise walk the backoff ladder, reusing
            // its last entry if maxAttempts runs past the ladder length so a
            // late attempt still waits instead of spinning.
            let fallback = delays.isEmpty
                ? 1_000_000_000
                : delays[min(attempt, delays.count - 1)]
            do {
                try await Task.sleep(nanoseconds: serverRetryAfter ?? fallback)
            } catch {
                return nil
            }
        }
    }
    return nil
}

/// Parses a `Retry-After` header value. Handles the integer-seconds form
/// (what Wikimedia and most APIs send for 429); the HTTP-date form returns
/// nil so the caller falls back to its backoff ladder. Clamped to a small
/// ceiling so a misbehaving server can't stall a foreground fetch for
/// minutes.
nonisolated private func parseRetryAfter(_ value: String) -> UInt64? {
    guard let seconds = Int(value.trimmingCharacters(in: .whitespaces)),
          seconds > 0 else { return nil }
    return UInt64(min(seconds, 8)) * 1_000_000_000
}
