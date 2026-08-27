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

public func defaultOltpHttpTracesEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/traces")!
}

public class OtlpHttpTraceExporter: OtlpHttpExporterBase<SpanData>, SpanExporter, @unchecked Sendable {
  var pendingSpans: [SpanData] { pendingSnapshot }

  override public init(endpoint: URL = defaultOltpHttpTracesEndpoint(),
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
  public convenience init(endpoint: URL,
                          config: OtlpConfiguration,
                          meterProvider: any MeterProvider,
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true) {
    self.init(endpoint: endpoint,
              config: config,
              httpClient: httpClient,
              envVarHeaders: envVarHeaders,
              requeueOnFailure: requeueOnFailure)
    configureExporterMetrics(signalType: "span", meterProvider: meterProvider)
  }

  public func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil)
  -> SpanExporterResultCode {
    let sendingSpans = pendingExport.drain(adding: spans)
    let request = makeTraceExportRequest(for: sendingSpans, explicitTimeout: explicitTimeout)
    let timeout = exportTimeout(explicitTimeout: explicitTimeout)

    exporterMetrics?.addSeen(value: sendingSpans.count)
    switch httpClient.sendReturningResultSync(request: request, timeout: timeout) {
    case .success:
      exporterMetrics?.addSuccess(value: sendingSpans.count)
      return .success
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sendingSpans,
        skipRequeueOnTimeout: false)
      return .failure
    case .timedOut:
      recordSendTimedOut(sentCount: sendingSpans.count)
      return .failure
    }
  }

  public func flush(explicitTimeout: TimeInterval? = nil)
  -> SpanExporterResultCode {
    performPendingFlushSync(
      explicitTimeout: explicitTimeout,
      makeRequest: { makeTraceExportRequest(for: $0, explicitTimeout: explicitTimeout) })
    ? .success
    : .failure
  }

  public func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) async
  -> SpanExporterResultCode {
    let sendingSpans = pendingExport.drain(adding: spans)
    let request = makeTraceExportRequest(for: sendingSpans, explicitTimeout: explicitTimeout)

    exporterMetrics?.addSeen(value: sendingSpans.count)
    switch await httpClient.sendReturningResult(request: request) {
    case .success:
      exporterMetrics?.addSuccess(value: sendingSpans.count)
      return .success
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sendingSpans,
        skipRequeueOnTimeout: true)
      return .failure
    }
  }

  public func flush(explicitTimeout: TimeInterval? = nil) async -> SpanExporterResultCode {
    await performPendingFlushAsync(
      explicitTimeout: explicitTimeout,
      makeRequest: { makeTraceExportRequest(for: $0, explicitTimeout: explicitTimeout) })
    ? .success
    : .failure
  }

  public func shutdown(explicitTimeout: TimeInterval? = nil) async {
    super.shutdown(explicitTimeout: explicitTimeout)
  }
}

private extension OtlpHttpTraceExporter {
  func makeTraceExportRequest(for spans: [SpanData], explicitTimeout: TimeInterval?) -> URLRequest {
    let body =
    Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
      $0.resourceSpans = SpanAdapter.toProtoResourceSpans(spanDataList: spans)
    }
    var request = createRequest(body: body, endpoint: endpoint)
    request.timeoutInterval = exportTimeout(explicitTimeout: explicitTimeout)
    return request
  }
}
