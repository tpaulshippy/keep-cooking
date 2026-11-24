// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/ClipModels.swift
//
// Contract types for POST /clip (openapi.yaml ClipRequest → ClipReport).
// Consumes Lane 2 Core/Models.swift + Sync/SyncEngine.swift — no duplicates.
//
// Privacy: log only { strategy, host, confidence }. Never log url query
// strings, captions, or parsed content.

import Foundation

// MARK: - ClipRequest (openapi ClipRequest)

public enum ClipSource: String, Sendable, Codable {
    case url
    case tiktok
    case instagram
    case youtube
    case ocr
    case clipboard
}

public struct ClipRequest: Sendable, Codable {
    public var url: String?
    public var caption: String?
    public var source: ClipSource?

    public init(url: String? = nil, caption: String? = nil, source: ClipSource? = nil) {
        self.url = url
        self.caption = caption
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case url, caption, source }
}

// MARK: - ClipReport (openapi ClipReport)

public enum ClipStrategy: String, Sendable, Codable {
    case jsonld
    case reader
    case caption
    case ocr
}

public struct ClipIngredientInput: Sendable, Codable {
    public var name: String
    public var quantity: Double?
    public var unit: String?
    public var display: String?
    public init(name: String, quantity: Double? = nil, unit: String? = nil, display: String? = nil) {
        self.name = name; self.quantity = quantity; self.unit = unit; self.display = display
    }
}

public struct ClipStepInput: Sendable, Codable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ClipRecipeInput: Sendable, Codable {
    public var title: String
    public var description: String?
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var source: String?
    public var sourceUrl: String?
    public var categories: [String]?
    public var ingredients: [ClipIngredientInput]?
    public var steps: [ClipStepInput]?
    public init(title: String) { self.title = title }
}

public struct ClipReport: Sendable, Codable {
    public var strategy: ClipStrategy
    public var confidence: Double?
    public var warnings: [String]?
    public var sourceUrl: String?
    public var recipe: ClipRecipeInput
}

// MARK: - Strategy log event (PII-safe)

/// What we log per clip: strategy + host + confidence only.
public struct ClipLogEvent: Sendable {
    public var strategy: ClipStrategy
    public var host: String
    public var confidence: Double
    public init(strategy: ClipStrategy, host: String, confidence: Double) {
        self.strategy = strategy; self.host = host; self.confidence = confidence
    }
    public var description: String { "clip strategy=\(strategy.rawValue) host=\(host) confidence=\(confidence)" }
}

public func clipHost(from urlString: String?) -> String {
    guard let s = urlString, let u = URL(string: s), let h = u.host else { return "caption-only" }
    return h
}

// MARK: - Friendly error + warning copy (human polish)

/// Server-error message for `.httpStatus`, else nil so callers keep their
/// context-specific generic copy ("check the address" vs "check the text").
/// Callers should still `print` the original error for diagnostics
/// (PII-safe: ClipClientError carries status codes, never content).
public func clipServerErrorMessage(for error: Error) -> String? {
    if case ClipClientError.httpStatus(let code) = error {
        return "The recipe service returned an error (\(code)). Try again later."
    }
    return nil
}

/// Human-readable text for a `ClipReport` warning code.
/// Unknown codes pass through unchanged so new server warnings stay visible.
public func clipWarningText(for warning: String) -> String {
    switch warning {
    case "jsonld-missing":
        return "No recipe card found on the page — details were read from the page text instead."
    default:
        return warning
    }
}

/// Title gating shared by the ingest Save buttons: blank-looking titles
/// (spaces *or* newlines from pastes) can never be saved.
public func isSavableTitle(_ title: String) -> Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Trims the saved title the same way `isSavableTitle` validates it, so
/// what is persisted matches what the Save button allowed.
public func cleanTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - ClipClient (POST /clip)

public enum ClipClientError: Error, Sendable {
    case badURL
    case httpStatus(Int)
    case decode(Error)
}

public struct ClipClient: Sendable {
    public var baseURL: URL
    public var session: URLSession
    public var betaToken: String?
    public var userId: String
    public var deviceId: String

    public init(baseURL: URL, session: URLSession = .shared,
                betaToken: String? = nil, userId: String = "beta-user", deviceId: String = "app") {
        self.baseURL = baseURL; self.session = session
        self.betaToken = betaToken; self.userId = userId; self.deviceId = deviceId
    }

    /// POST /clip with ClipRequest{url, caption, source}.
    /// Returns decoded ClipReport; caller logs ClipLogEvent only.
    public func clip(_ request: ClipRequest) async throws -> ClipReport {
        let url = baseURL.appendingPathComponent("/clip")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = betaToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(userId, forHTTPHeaderField: "x-user-id")
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(request)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClipClientError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let dec = JSONDecoder()
        do { return try dec.decode(ClipReport.self, from: data) }
        catch { throw ClipClientError.decode(error) }
    }

    /// PII-safe log event for a completed clip.
    public func logEvent(for report: ClipReport, requestURL: String?) -> ClipLogEvent {
        ClipLogEvent(
            strategy: report.strategy,
            host: clipHost(from: requestURL ?? report.sourceUrl),
            confidence: report.confidence ?? 0
        )
    }
}
