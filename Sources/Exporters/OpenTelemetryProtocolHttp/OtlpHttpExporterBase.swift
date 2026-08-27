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

public class OtlpHttpExporterBase<Signal: Sendable>: @unchecked Sendable {
  let endpoint: URL
  let httpClient: HTTPClient
  let envVarHeaders: [(String, String)]?
  let config: OtlpConfiguration
  let requeueOnFailure: Bool
  var exporterMetrics: ExporterMetrics?
  let pendingExport = OtlpHttpPendingExportState<Signal>()

  var pendingSnapshot: [Signal] { pendingExport.snapshot() }

  // MARK: - Init

  // New initializer with HTTPClient support
  public init(endpoint: URL,
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
  public init(endpoint: URL,
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

  public func createRequest(body: Message, endpoint: URL) -> URLRequest {
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

  public func shutdown(explicitTimeout: TimeInterval? = nil) {}

  func exportTimeout(explicitTimeout: TimeInterval?) -> TimeInterval {
    min(explicitTimeout ?? TimeInterval.greatestFiniteMagnitude, config.timeout)
  }

  func configureExporterMetrics(signalType: String, meterProvider: any MeterProvider) {
    exporterMetrics = ExporterMetrics(
      type: signalType,
      meterProvider: meterProvider,
      exporterName: "otlp",
      transportName: config.exportAsJson
      ? ExporterMetrics.TransporterType.httpJson
      : ExporterMetrics.TransporterType.grpc)
  }

  func recordFlushSendFailure(_ error: Error, sending: [Signal]) {
    exporterMetrics?.addFailed(value: sending.count)
    pendingExport.requeue(sending)
    OpenTelemetry.instance.feedbackHandler?("\(error)")
  }

  func recordFlushTimedOut(sending: [Signal]) {
    exporterMetrics?.addFailed(value: sending.count)
    pendingExport.requeue(sending)
  }

  func recordSendTimedOut(sentCount: Int) {
    exporterMetrics?.addFailed(value: sentCount)
  }

  func recordExportSendFailure(_ error: Error,
                               sending: [Signal],
                               skipRequeueOnTimeout: Bool) {
    exporterMetrics?.addFailed(value: sending.count)
    if requeueOnFailure, !(skipRequeueOnTimeout && isHTTPClientTimeout(error)) {
      pendingExport.requeue(sending)
    }
    OpenTelemetry.instance.feedbackHandler?("\(error)")
  }

  func handleExportSendResult(_ result: Result<HTTPURLResponse, Error>,
                              sending: [Signal],
                              skipRequeueOnTimeout: Bool) {
    switch result {
    case .success:
      exporterMetrics?.addSuccess(value: sending.count)
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sending,
        skipRequeueOnTimeout: skipRequeueOnTimeout)
    }
  }

  func performExportSend(_ request: URLRequest) async -> Result<HTTPURLResponse, Error> {
    do {
      return .success(try await httpClient.send(request: request))
    } catch {
      return .failure(error)
    }
  }

  func performExportSendSync(_ request: URLRequest,
                             timeout: TimeInterval) -> Result<HTTPURLResponse, Error> {
    let wait = ExportSendWait()
    httpClient.send(request: request) { wait.complete(with: $0) }
    return wait.result(timeout: timeout)
  }

  func performExportFireAndForget(adding incoming: [Signal],
                                  explicitTimeout: TimeInterval?,
                                  skipRequeueOnTimeout: Bool,
                                  makeRequest: ([Signal], TimeInterval?) -> URLRequest) {
    let sending = pendingExport.drain(adding: incoming)
    let request = makeRequest(sending, explicitTimeout)
    exporterMetrics?.addSeen(value: sending.count)
    httpClient.send(request: request) { [weak self] result in
      guard let self else { return }
      self.handleExportSendResult(
        result,
        sending: sending,
        skipRequeueOnTimeout: skipRequeueOnTimeout)
    }
  }

  func performExportSync(adding incoming: [Signal],
                         explicitTimeout: TimeInterval?,
                         makeRequest: ([Signal], TimeInterval?) -> URLRequest) -> Bool {
    let sending = pendingExport.drain(adding: incoming)
    let request = makeRequest(sending, explicitTimeout)
    let timeout = exportTimeout(explicitTimeout: explicitTimeout)
    exporterMetrics?.addSeen(value: sending.count)
    switch performExportSendSync(request, timeout: timeout) {
    case .success:
      exporterMetrics?.addSuccess(value: sending.count)
      return true
    case .failure(is ExportSendWaitTimedOut):
      recordSendTimedOut(sentCount: sending.count)
      return false
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sending,
        skipRequeueOnTimeout: false)
      return false
    }
  }

  func performExportAsync(adding incoming: [Signal],
                          explicitTimeout: TimeInterval?,
                          skipRequeueOnTimeout: Bool,
                          makeRequest: ([Signal], TimeInterval?) -> URLRequest) async -> Bool {
    let sending = pendingExport.drain(adding: incoming)
    let request = makeRequest(sending, explicitTimeout)
    exporterMetrics?.addSeen(value: sending.count)
    switch await performExportSend(request) {
    case .success:
      exporterMetrics?.addSuccess(value: sending.count)
      return true
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sending,
        skipRequeueOnTimeout: skipRequeueOnTimeout)
      return false
    }
  }

  func performFlushSync(explicitTimeout: TimeInterval?,
                        makeRequest: ([Signal], TimeInterval?) -> URLRequest) -> Bool {
    performPendingFlushSync(explicitTimeout: explicitTimeout) { signals in
      makeRequest(signals, explicitTimeout)
    }
  }

  func performFlushAsync(explicitTimeout: TimeInterval?,
                         makeRequest: ([Signal], TimeInterval?) -> URLRequest) async -> Bool {
    await performPendingFlushAsync(explicitTimeout: explicitTimeout) { signals in
      makeRequest(signals, explicitTimeout)
    }
  }

  func performPendingFlushSync(explicitTimeout: TimeInterval?,
                               makeRequest: ([Signal]) -> URLRequest) -> Bool {
    let sending = pendingExport.drain(adding: [])
    guard !sending.isEmpty else { return true }

    let request = makeRequest(sending)
    let timeout = exportTimeout(explicitTimeout: explicitTimeout)
    switch performExportSendSync(request, timeout: timeout) {
    case .success:
      exporterMetrics?.addSuccess(value: sending.count)
      return true
    case .failure(is ExportSendWaitTimedOut):
      recordFlushTimedOut(sending: sending)
      return false
    case let .failure(error):
      recordFlushSendFailure(error, sending: sending)
      return false
    }
  }

  func performPendingFlushAsync(explicitTimeout: TimeInterval?,
                                makeRequest: ([Signal]) -> URLRequest) async -> Bool {
    let sending = pendingExport.drain(adding: [])
    guard !sending.isEmpty else { return true }

    let request = makeRequest(sending)
    switch await performExportSend(request) {
    case .success:
      exporterMetrics?.addSuccess(value: sending.count)
      return true
    case let .failure(error):
      recordFlushSendFailure(error, sending: sending)
      return false
    }
  }
}

/// Error returned when a blocking export send wait expires before ``HTTPClient`` invokes its completion handler.
struct ExportSendWaitTimedOut: Error {}

private final class ExportSendWait: @unchecked Sendable {
  private var sendResult: Result<HTTPURLResponse, Error>?
  private let semaphore = DispatchSemaphore(value: 0)
  private var timedOut = false

  func complete(with result: Result<HTTPURLResponse, Error>) {
    guard !timedOut else { return }
    sendResult = result
    semaphore.signal()
  }

  func result(timeout: TimeInterval) -> Result<HTTPURLResponse, Error> {
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      return .failure(ExportSendWaitTimedOut())
    }
    switch sendResult {
    case let .success(response):
      return .success(response)
    case let .failure(error):
      return .failure(error)
    case .none:
      return .failure(ExportSendWaitTimedOut())
    }
  }
}
