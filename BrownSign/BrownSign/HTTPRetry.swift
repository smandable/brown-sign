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

/// HTTP status codes worth retrying. 502/503/504 are the canonical
/// transient backend failures; 429 (rate-limited) gets the same
/// backoff — strictly we'd honor Retry-After, but our request
/// volume is low enough that the fixed ladder is fine.
func isTransientHTTPStatus(_ code: Int) -> Bool {
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
func httpDataWithRetry(
    _ request: URLRequest,
    maxAttempts: Int = 3,
    delays: [UInt64] = [500_000_000, 1_500_000_000]
) async -> Data? {
    for attempt in 0..<maxAttempts {
        if Task.isCancelled { return nil }

        var transient = false
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
            } else {
                transient = true
            }
        } catch is CancellationError {
            return nil
        } catch {
            transient = true
        }

        if transient, attempt < maxAttempts - 1, attempt < delays.count {
            do {
                try await Task.sleep(nanoseconds: delays[attempt])
            } catch {
                return nil
            }
        }
    }
    return nil
}
