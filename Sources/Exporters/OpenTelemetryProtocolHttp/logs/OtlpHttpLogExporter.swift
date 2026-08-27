//
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public func defaultOltpHttpLoggingEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/logs")!
}

public class OtlpHttpLogExporter: OtlpHttpExporterBase<ReadableLogRecord>, LogRecordExporter, @unchecked Sendable {
  var pendingLogRecords: [ReadableLogRecord] { pendingSnapshot }
  
  override public init(endpoint: URL = defaultOltpHttpLoggingEndpoint(),
                       config: OtlpConfiguration = OtlpConfiguration(),
                       httpClient: HTTPClient = BaseHTTPClient(),
                       envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                       requeueOnFailure: Bool = true) {
    super.init(endpoint: endpoint,
               config: config,
               httpClient: httpClient,
               envVarHeaders: envVarHeaders,
               requeueOnFailure: requeueOnFailure)
  }
  
  /// A `convenience` constructor to provide support for exporter metric using`StableMeterProvider` type
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - meterProvider: Injected `StableMeterProvider` for metric
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  public convenience init(endpoint: URL = defaultOltpHttpLoggingEndpoint(),
                          config: OtlpConfiguration = OtlpConfiguration(),
                          meterProvider: any MeterProvider,
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true) {
    self.init(endpoint: endpoint,
              config: config,
              httpClient: httpClient,
              envVarHeaders: envVarHeaders,
              requeueOnFailure: requeueOnFailure)
    configureExporterMetrics(signalType: "log", meterProvider: meterProvider)
  }
  
  public func export(logRecords: [OpenTelemetrySdk.ReadableLogRecord],
                     explicitTimeout: TimeInterval? = nil) -> OpenTelemetrySdk.ExportResult {
    let sendingLogRecords = pendingExport.drain(adding: logRecords)
    let request = makeLogExportRequest(for: sendingLogRecords, explicitTimeout: explicitTimeout)
    
    exporterMetrics?.addSeen(value: sendingLogRecords.count)
    httpClient.send(request: request) { [weak self] result in
      guard let self else { return }
      self.handleExportSendResult(
        result,
        sending: sendingLogRecords,
        skipRequeueOnTimeout: false)
    }
    
    return .success
  }
  
  public func forceFlush(explicitTimeout: TimeInterval? = nil) -> ExportResult {
    performPendingFlushSync(
      explicitTimeout: explicitTimeout,
      makeRequest: { makeLogExportRequest(for: $0, explicitTimeout: explicitTimeout) })
    ? .success
    : .failure
  }
  
  public func export(logRecords: [OpenTelemetrySdk.ReadableLogRecord],
                     explicitTimeout: TimeInterval? = nil) async -> OpenTelemetrySdk.ExportResult {
    let sendingLogRecords = pendingExport.drain(adding: logRecords)
    let request = makeLogExportRequest(for: sendingLogRecords, explicitTimeout: explicitTimeout)
    
    exporterMetrics?.addSeen(value: sendingLogRecords.count)
    switch await httpClient.sendReturningResult(request: request) {
    case .success:
      exporterMetrics?.addSuccess(value: sendingLogRecords.count)
      return .success
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sendingLogRecords,
        skipRequeueOnTimeout: true)
      return .failure
    }
  }
  
  public func forceFlush(explicitTimeout: TimeInterval? = nil) async -> ExportResult {
    await performPendingFlushAsync(
      explicitTimeout: explicitTimeout,
      makeRequest: { makeLogExportRequest(for: $0, explicitTimeout: explicitTimeout) })
    ? .success
    : .failure
  }
  
  public func shutdown(explicitTimeout: TimeInterval? = nil) async {
    super.shutdown(explicitTimeout: explicitTimeout)
  }
}

private extension OtlpHttpLogExporter {
  func makeLogExportRequest(for logRecords: [ReadableLogRecord],
                            explicitTimeout: TimeInterval?) -> URLRequest {
    let body =
    Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.with { request in
      request.resourceLogs = LogRecordAdapter.toProtoResourceRecordLog(logRecordList: logRecords)
    }
    var request = createRequest(body: body, endpoint: endpoint)
    request.timeoutInterval = exportTimeout(explicitTimeout: explicitTimeout)
    return request
  }
}
