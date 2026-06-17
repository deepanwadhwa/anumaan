import Foundation
import AnumaanCore

/// Downloads the drivable road network for a bbox from the Overpass API and
/// parses it into a routable `RoadGraph` (parsing is the tested code in
/// AnumaanCore; this just does the `URLSession` fetch). One online step — routing
/// afterwards is fully offline.
enum OverpassService {
    enum DownloadError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self { case .http(let c): return "Overpass returned HTTP \(c)" }
        }
    }

    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]

    static func downloadGraph(south: Double, west: Double,
                              north: Double, east: Double) async throws -> RoadGraph {
        let query = Overpass.query(south: south, west: west, north: north, east: east)
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)
        var lastError: Error = DownloadError.http(0)
        for endpoint in endpoints {
            do {
                var req = URLRequest(url: URL(string: endpoint)!)
                req.httpMethod = "POST"
                req.timeoutInterval = 90
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = body.data(using: .utf8)
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw DownloadError.http(code) }
                return try Overpass.buildGraph(from: data)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
