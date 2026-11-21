/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import Foundation

enum EdgeObjectAPIError: Error, Equatable, LocalizedError {
    case unauthorized
    case notFound
    case badStatus(Int)
    case badURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Session expired, go back and authenticate again"
        case .notFound: return "Not found"
        case .badStatus(let status): return "The server answered \(status)"
        case .badURL: return "Bad URL"
        case .invalidResponse: return "Unexpected response"
        }
    }
}

/// The calls an edge object needs, with the SDK's token read at the point of each request.
/// None of them carries `X-Client-Source`; a 401 is reported, never retried.
struct EdgeObjectAPI {
    private let baseURL: String
    private let token: @MainActor () -> String?
    private let session: URLSession

    init(baseURL: String, token: @escaping @MainActor () -> String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func details(code: String) async throws -> EdgeObject {
        try Self.decode(try await detailsJSON(code: code))
    }

    /// The object's JSON as the server sent it, for saving beside the download and for DEBUG logs.
    func detailsJSON(code: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/v1/vps/object/\(code)") else { throw EdgeObjectAPIError.badURL }
        return try await authorizedGet(url)
    }

    static func decode(_ data: Data) throws -> EdgeObject {
        do {
            return try EdgeObject.decode(data)
        } catch {
            throw EdgeObjectAPIError.invalidResponse
        }
    }

    func signedURL(forKey key: String) async throws -> URL {
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/v1/file?key=\(encodedKey)") else { throw EdgeObjectAPIError.badURL }
        let data = try await authorizedGet(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = object["url"] as? String, let signed = URL(string: link) else {
            throw EdgeObjectAPIError.invalidResponse
        }
        return signed
    }

    /// A plain GET of a signed link, written next to `destination` and moved into place when complete.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        try Self.require200(response)
        let expected = response.expectedContentLength
        let partial = destination.appendingPathExtension("part")
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var chunk = Data(capacity: 64 * 1024)
        var received: Int64 = 0
        var lastPercent = -1
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    if expected > 0 {
                        let percent = Int(received * 100 / expected)
                        if percent != lastPercent && percent < 100 {
                            lastPercent = percent
                            progress(Double(percent) / 100)
                        }
                    }
                }
            }
            try handle.write(contentsOf: chunk)
            try handle.close()
        } catch {
            try? handle.close()
            try? files.removeItem(at: partial)
            throw error
        }
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: partial, to: destination)
        progress(1)
    }

    /// A stalled search request holds up the next picture, so it gives up long before URLSession's 60 s.
    static let startPoseTimeout: TimeInterval = 10

    /// Asks the server where the object is in one camera picture (`startMode` "auto").
    func startPose(code: String, frame: EdgeStartFrame) async throws -> EdgeStartResponse {
        guard let url = URL(string: "\(baseURL)/v1/vps/object/query") else { throw EdgeObjectAPIError.badURL }
        guard let token = await token(), !token.isEmpty else { throw EdgeObjectAPIError.unauthorized }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: Self.startPoseTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = EdgeStartQuery.body(objectCode: code, frame: frame, boundary: boundary)
        let (data, response) = try await session.data(for: request)
        try Self.require200(response)
        do {
            return try JSONDecoder().decode(EdgeStartResponse.self, from: data)
        } catch {
            throw EdgeObjectAPIError.invalidResponse
        }
    }

    /// A plain GET of a signed link, for small files such as thumbnails.
    func data(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: URLRequest(url: url))
        try Self.require200(response)
        return data
    }

    private func authorizedGet(_ url: URL) async throws -> Data {
        guard let token = await token(), !token.isEmpty else { throw EdgeObjectAPIError.unauthorized }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.require200(response)
        return data
    }

    private static func require200(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw EdgeObjectAPIError.invalidResponse }
        switch http.statusCode {
        case 200: return
        case 401: throw EdgeObjectAPIError.unauthorized
        case 404: throw EdgeObjectAPIError.notFound
        default: throw EdgeObjectAPIError.badStatus(http.statusCode)
        }
    }
}
