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

public func defaultOtlpHttpMetricsEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/metrics")!
}

@available(*, deprecated, renamed: "defaultOtlpHttpMetricsEndpoint")
public func defaultStableOtlpHTTPMetricsEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/metrics")!
}

@available(*, deprecated, renamed: "OtlpHttpMetricExporter")
public typealias StableOtlpHTTPMetricExporter = OtlpHttpMetricExporter

@available(*, deprecated, renamed: "OtlpHttpMetricExporter")
public typealias OtlpHTTPMetricExporter = OtlpHttpMetricExporter

public class OtlpHttpMetricExporter: OtlpHttpExporterBase<MetricData>, MetricExporter, @unchecked Sendable {
  var aggregationTemporalitySelector: AggregationTemporalitySelector
  var defaultAggregationSelector: DefaultAggregationSelector
  
  var pendingMetrics: [MetricData] { pendingSnapshot }
  
  // MARK: - Init
  
  public init(endpoint: URL, config: OtlpConfiguration = OtlpConfiguration(),
              aggregationTemporalitySelector: AggregationTemporalitySelector =
              AggregationTemporality.alwaysCumulative(),
              defaultAggregationSelector: DefaultAggregationSelector = AggregationSelector.instance,
              httpClient: HTTPClient = BaseHTTPClient(),
              envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
              requeueOnFailure: Bool = true) {
    self.aggregationTemporalitySelector = aggregationTemporalitySelector
    self.defaultAggregationSelector = defaultAggregationSelector
    
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
  ///    - aggregationTemporalitySelector: aggregator
  ///    - defaultAggregationSelector: default aggregator
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  public convenience init(endpoint: URL,
                          config: OtlpConfiguration = OtlpConfiguration(),
                          meterProvider: any MeterProvider,
                          aggregationTemporalitySelector: AggregationTemporalitySelector =
                          AggregationTemporality.alwaysCumulative(),
                          defaultAggregationSelector: DefaultAggregationSelector = AggregationSelector
    .instance,
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true) {
    self.init(endpoint: endpoint,
              config: config,
              aggregationTemporalitySelector: aggregationTemporalitySelector,
              defaultAggregationSelector: defaultAggregationSelector,
              httpClient: httpClient,
              envVarHeaders: envVarHeaders,
              requeueOnFailure: requeueOnFailure)
    configureExporterMetrics(signalType: "metric", meterProvider: meterProvider)
  }
  
  // MARK: - StableMetricsExporter
  
  public func export(metrics: [MetricData]) -> ExportResult {
    let sendingMetrics = pendingExport.drain(adding: metrics)
    let request = makeMetricExportRequest(for: sendingMetrics, explicitTimeout: nil)
    
    exporterMetrics?.addSeen(value: sendingMetrics.count)
    httpClient.send(request: request) { [weak self] result in
      guard let self else { return }
      self.handleExportSendResult(
        result,
        sending: sendingMetrics,
        skipRequeueOnTimeout: false)
    }
    
    return .success
  }
  
  public func flush() -> ExportResult {
    performPendingFlushSync(
      explicitTimeout: nil,
      makeRequest: { makeMetricExportRequest(for: $0, explicitTimeout: nil) })
    ? .success
    : .failure
  }
  
  public func shutdown() -> ExportResult {
    return .success
  }
  
  public func export(metrics: [MetricData]) async -> ExportResult {
    let sendingMetrics = pendingExport.drain(adding: metrics)
    let request = makeMetricExportRequest(for: sendingMetrics, explicitTimeout: nil)
    
    exporterMetrics?.addSeen(value: sendingMetrics.count)
    switch await httpClient.sendReturningResult(request: request) {
    case .success:
      exporterMetrics?.addSuccess(value: sendingMetrics.count)
      return .success
    case let .failure(error):
      recordExportSendFailure(
        error,
        sending: sendingMetrics,
        skipRequeueOnTimeout: true)
      return .failure
    }
  }
  
  public func flush() async -> ExportResult {
    await performPendingFlushAsync(
      explicitTimeout: nil,
      makeRequest: { makeMetricExportRequest(for: $0, explicitTimeout: nil) })
    ? .success
    : .failure
  }
  
  public func shutdown() async -> ExportResult {
    return .success
  }
  
  // MARK: - AggregationTemporalitySelectorProtocol
  
  public func getAggregationTemporality(
    for instrument: OpenTelemetrySdk.InstrumentType
  ) -> OpenTelemetrySdk.AggregationTemporality {
    return aggregationTemporalitySelector.getAggregationTemporality(
      for: instrument)
  }
  
  // MARK: - DefaultAggregationSelector
  
  public func getDefaultAggregation(
    for instrument: OpenTelemetrySdk.InstrumentType
  ) -> OpenTelemetrySdk.Aggregation {
    return defaultAggregationSelector.getDefaultAggregation(for: instrument)
  }
}

private extension OtlpHttpMetricExporter {
  func makeMetricExportRequest(for metrics: [MetricData],
                               explicitTimeout: TimeInterval? = nil) -> URLRequest {
    let body =
    Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest.with {
      $0.resourceMetrics = MetricsAdapter.toProtoResourceMetrics(metricData: metrics)
    }
    var request = createRequest(body: body, endpoint: endpoint)
    request.timeoutInterval = exportTimeout(explicitTimeout: explicitTimeout)
    return request
  }
}
