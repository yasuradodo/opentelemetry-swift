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

public final class OtlpHttpTraceExporter: SpanExporter, @unchecked Sendable {
  private let base: OtlpHttpExporterBase<SpanData>
  private var exporterMetrics: ExporterMetrics?

  // MARK: - Init

  init(base: OtlpHttpExporterBase<SpanData>) {
    self.base = base
  }

  /// A `convenience` constructor to configure the OTLP HTTP trace exporter
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  public convenience init(endpoint: URL = defaultOltpHttpTracesEndpoint(),
                          config: OtlpConfiguration = OtlpConfiguration(),
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true) {
    self.init(base: OtlpHttpExporterBase(endpoint: endpoint,
                                         config: config,
                                         httpClient: httpClient,
                                         envVarHeaders: envVarHeaders,
                                         requeueOnFailure: requeueOnFailure))
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
    exporterMetrics = ExporterMetrics(type: "span",
                                      meterProvider: meterProvider,
                                      exporterName: "otlp",
                                      transportName: config.exportAsJson
                                        ? ExporterMetrics.TransporterType.httpJson
                                        : ExporterMetrics.TransporterType.grpc)
  }

  // MARK: - SpanExporter

  // MARK: Export

  public func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil)
    -> SpanExporterResultCode {
    var resultValue: SpanExporterResultCode = .success
    let sendingSpans = base.drainPending(adding: spans)

    let semaphore = DispatchSemaphore(value: 0)
    let request = makeTraceExportRequest(sendingSpans, explicitTimeout: explicitTimeout)
    let timeout = request.timeoutInterval

    exporterMetrics?.addSeen(value: sendingSpans.count)
    base.httpClient.send(request: request) { [weak self] result in
      switch result {
      case .success:
        self?.exporterMetrics?.addSuccess(value: sendingSpans.count)
      case let .failure(error):
        self?.exporterMetrics?.addFailed(value: sendingSpans.count)
        self?.base.requeue(sendingSpans)
        OpenTelemetry.instance.feedbackHandler?("\(error)")
        resultValue = .failure
      }
      semaphore.signal()
    }

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    if waitResult == .timedOut {
      exporterMetrics?.addFailed(value: sendingSpans.count)
      return .failure
    }
    return resultValue
  }

  public func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil) async
    -> SpanExporterResultCode {
    switch await base.performExport(adding: spans,
                                    explicitTimeout: explicitTimeout,
                                    metrics: exporterMetrics,
                                    makeRequest: { signals in
      makeTraceExportRequest(signals, explicitTimeout: explicitTimeout)
    }) {
    case .success:
      return .success
    case .failure:
      return .failure
    }
  }

  // MARK: Flush

  public func flush(explicitTimeout: TimeInterval? = nil)
    -> SpanExporterResultCode {
    var resultValue: SpanExporterResultCode = .success
    let pendingSpans = base.snapshotPending()
    if !pendingSpans.isEmpty {
      let sentCount = pendingSpans.count
      let semaphore = DispatchSemaphore(value: 0)
      let request = makeTraceExportRequest(pendingSpans, explicitTimeout: explicitTimeout)
      let timeout = request.timeoutInterval

      base.httpClient.send(request: request) { [weak self] result in
        switch result {
        case .success:
          self?.exporterMetrics?.addSuccess(value: sentCount)
          self?.base.dropFlushed(count: sentCount)
        case let .failure(error):
          self?.exporterMetrics?.addFailed(value: sentCount)
          OpenTelemetry.instance.feedbackHandler?("\(error)")
          resultValue = .failure
        }
        semaphore.signal()
      }

      let waitResult = semaphore.wait(timeout: .now() + timeout)
      if waitResult == .timedOut {
        exporterMetrics?.addFailed(value: sentCount)
        return .failure
      }
    }
    return resultValue
  }

  public func flush(explicitTimeout: TimeInterval? = nil) async -> SpanExporterResultCode {
    switch await base.performFlush(explicitTimeout: explicitTimeout,
                                   metrics: exporterMetrics,
                                   makeRequest: { signals in
      makeTraceExportRequest(signals, explicitTimeout: explicitTimeout)
    }) {
    case .success:
      return .success
    case .failure:
      return .failure
    }
  }

  // MARK: Shutdown

  public func shutdown(explicitTimeout: TimeInterval? = nil) {}

  public func shutdown(explicitTimeout: TimeInterval?) async {}

  // MARK: - Private

  private func makeTraceExportRequest(_ spans: [SpanData],
                                       explicitTimeout: TimeInterval?) -> URLRequest {
    let body =
      Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
        $0.resourceSpans = SpanAdapter.toProtoResourceSpans(spanDataList: spans)
      }
    var request = base.createRequest(body: body, endpoint: base.endpoint)
    request.timeoutInterval = base.exportTimeout(explicitTimeout: explicitTimeout)
    return request
  }
}
