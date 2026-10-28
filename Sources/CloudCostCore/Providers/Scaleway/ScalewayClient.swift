import Foundation

/// Minimal Scaleway REST client: auth header, pagination, readable errors.
struct ScalewayClient: Sendable {
    var baseURL: URL
    var secretKey: String
    var session: URLSession = .shared

    static let zones = ["fr-par-1", "fr-par-2", "fr-par-3", "nl-ams-1", "nl-ams-2", "nl-ams-3", "pl-waw-1", "pl-waw-2", "pl-waw-3"]
    static let regions = ["fr-par", "nl-ams", "pl-waw"]

    func get(_ path: String, query: [String: String] = [:]) async throws -> (JSONValue, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(secretKey, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CloudCostMap/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONValue.parse(data))?["message"].string ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw ProviderError.http(status: http.statusCode, message: message)
        }
        return (try JSONValue.parse(data), http)
    }

    /// Fetches every page of a list endpoint and returns the items under `key`.
    /// The Instance API pages with `per_page`; every other product uses `page_size`.
    func list(_ path: String, key: String, query: [String: String] = [:]) async throws -> [JSONValue] {
        let pageParam = path.hasPrefix("/instance/") ? "per_page" : "page_size"
        let size = 100
        var items: [JSONValue] = []
        for page in 1...200 {
            var q = query
            q[pageParam] = String(size)
            q["page"] = String(page)
            let (json, http) = try await get(path, query: q)
            let batch = json[key].array
            items += batch
            let total = json["total_count"].int ?? http.value(forHTTPHeaderField: "X-Total-Count").flatMap(Int.init)
            if batch.count < size || (total.map { items.count >= $0 } ?? false) { break }
        }
        return items
    }
}
