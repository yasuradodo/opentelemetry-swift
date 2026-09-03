//
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenTelemetryApi
import OpenTelemetrySdk

final class OtlpHttpExporterBase<Signal: Sendable>: @unchecked Sendable {
  let endpoint: URL
  let httpClient: HTTPClient
  let envVarHeaders: [(String, String)]?
  let config: OtlpConfiguration
  let requeueOnFailure: Bool

  private let lock = Lock()
  private var pendingSignals: [Signal] = []

  // MARK: - Init

  // New initializer with HTTPClient support
  init(endpoint: URL,
       config: OtlpConfiguration = OtlpConfiguration(),
       httpClient: HTTPClient = BaseHTTPClient(),
       envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
       requeueOnFailure: Bool = true) {
    self.envVarHeaders = envVarHeaders
    self.endpoint = endpoint
    self.config = config
    self.httpClient = httpClient
    self.requeueOnFailure = requeueOnFailure
  }

  // Deprecated initializer for backward compatibility
  @available(*, deprecated, message: "Use init(endpoint:config:httpClient:envVarHeaders:requeueOnFailure:) instead")
  init(endpoint: URL,
       config: OtlpConfiguration = OtlpConfiguration(),
       useSession: URLSession? = nil,
       envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
       requeueOnFailure: Bool = true) {
    self.envVarHeaders = envVarHeaders
    self.endpoint = endpoint
    self.config = config
    self.requeueOnFailure = requeueOnFailure
    if let providedSession = useSession {
      self.httpClient = BaseHTTPClient(session: providedSession)
    } else {
      self.httpClient = BaseHTTPClient()
    }
  }

  func drainPending(adding signals: [Signal]) -> [Signal] {
    lock.withLock {
      pendingSignals.append(contentsOf: signals)
      let sending = pendingSignals
      pendingSignals = []
      return sending
    }
  }

  func requeue(_ signals: [Signal]) {
    guard requeueOnFailure else { return }
    lock.withLockVoid {
      pendingSignals.append(contentsOf: signals)
    }
  }

  func snapshotPending() -> [Signal] {
    lock.withLock { pendingSignals }
  }

  func dropFlushed(count sentCount: Int) {
    lock.withLockVoid {
      let n = min(sentCount, pendingSignals.count)
      pendingSignals.removeFirst(n)
    }
  }

  func createRequest(body: Message, endpoint: URL) -> URLRequest {
    var request = URLRequest(url: endpoint)

    if let headers = envVarHeaders ?? config.headersForExport() {
      headers.forEach { key, value in
        request.addValue(value, forHTTPHeaderField: key)
      }
    }

    do {
      let rawData = try body.serializedData()
      request.httpMethod = "POST"
      request.setValue(Headers.getUserAgentHeader(), forHTTPHeaderField: Constants.HTTP.userAgent)
      request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")

      var compressedData = rawData

      #if canImport(Compression)
        switch config.compression {
        case .gzip:
          if let data = rawData.gzip() {
            compressedData = data
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
          }

        case .deflate:
          if let data = rawData.deflate() {
            compressedData = data
            request.setValue("deflate", forHTTPHeaderField: "Content-Encoding")
          }

        case .none:
          break
        }
      #endif

      // Apply final data. Could be compressed or raw
      // but it doesn't matter here
      request.httpBody = compressedData
    } catch {
      OpenTelemetry.instance.feedbackHandler?("Error serializing body: \(error)")
    }
    return request
  }

  func exportTimeout(explicitTimeout: TimeInterval?) -> TimeInterval {
    min(explicitTimeout ?? .greatestFiniteMagnitude, config.timeout)
  }

  func performExport(adding incoming: [Signal],
                     explicitTimeout: TimeInterval?,
                     metrics: ExporterMetrics?,
                     makeRequest: ([Signal]) -> URLRequest) async -> ExportResult {
    let sending = drainPending(adding: incoming)
    metrics?.addSeen(value: sending.count)
    var request = makeRequest(sending)
    request.timeoutInterval = exportTimeout(explicitTimeout: explicitTimeout)

    do {
      _ = try await httpClient.send(request: request)
      metrics?.addSuccess(value: sending.count)
      return .success
    } catch {
      metrics?.addFailed(value: sending.count)
      if !isTimeoutError(error) {
        requeue(sending)
      }
      OpenTelemetry.instance.feedbackHandler?("\(error)")
      return .failure
    }
  }

  func performFlush(explicitTimeout: TimeInterval?,
                    metrics: ExporterMetrics?,
                    makeRequest: ([Signal]) -> URLRequest) async -> ExportResult {
    let pending = snapshotPending()
    if pending.isEmpty {
      return .success
    }
    let sentCount = pending.count
    var request = makeRequest(pending)
    request.timeoutInterval = exportTimeout(explicitTimeout: explicitTimeout)

    do {
      _ = try await httpClient.send(request: request)
      metrics?.addSuccess(value: sentCount)
      dropFlushed(count: sentCount)
      return .success
    } catch {
      metrics?.addFailed(value: sentCount)
      OpenTelemetry.instance.feedbackHandler?("\(error)")
      return .failure
    }
  }

  private func isTimeoutError(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    return urlError.code == .timedOut
  }
}
