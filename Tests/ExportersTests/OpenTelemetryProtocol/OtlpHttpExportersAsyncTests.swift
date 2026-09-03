/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
@testable import OpenTelemetryProtocolExporterHttp
@testable import OpenTelemetrySdk
import XCTest

private final class StubHTTPClient: HTTPClient {
  enum Outcome {
    case success
    case failure(Error)
  }
  var outcomes: [Outcome]
  private(set) var sentRequests: [URLRequest] = []
  init(outcomes: [Outcome]) { self.outcomes = outcomes }
  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sentRequests.append(request)
    let next = outcomes.isEmpty ? .success : outcomes.removeFirst()
    switch next {
    case .success:
      let resp = HTTPURLResponse(url: request.url!,
                                 statusCode: 200,
                                 httpVersion: "HTTP/1.1",
                                 headerFields: nil)!
      completion(.success(resp))
    case .failure(let err):
      completion(.failure(err))
    }
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sentRequests.append(request)
    let next = outcomes.isEmpty ? .success : outcomes.removeFirst()
    switch next {
    case .success:
      return HTTPURLResponse(url: request.url!,
                             statusCode: 200,
                             httpVersion: "HTTP/1.1",
                             headerFields: nil)!
    case .failure(let err):
      throw err
    }
  }
}

private struct TransientNetworkError: Error {}

/// Fails the first async send, then sleeps for `request.timeoutInterval` and throws
/// `URLError.timedOut` — mimicking URLSession timeout without hanging the test suite.
private final class TimeoutOnSecondSendHTTPClient: HTTPClient {
  private var sendCount = 0

  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sendCount += 1
    if sendCount == 1 {
      completion(.failure(TransientNetworkError()))
    }
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sendCount += 1
    if sendCount == 1 {
      throw TransientNetworkError()
    }
    let nanoseconds = UInt64(request.timeoutInterval * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
    throw URLError(.timedOut)
  }
}

private func sampleLogRecord() -> ReadableLogRecord {
  let ctx = SpanContext.create(traceId: TraceId.random(),
                               spanId: SpanId.random(),
                               traceFlags: TraceFlags(),
                               traceState: TraceState())
  return ReadableLogRecord(resource: Resource(),
                           instrumentationScopeInfo: InstrumentationScopeInfo(name: "scope"),
                           timestamp: Date(),
                           observedTimestamp: Date(),
                           spanContext: ctx,
                           severity: .info,
                           body: .string("hello"),
                           attributes: [:])
}

private func sampleSpanData() -> SpanData {
  SpanData(traceId: TraceId.random(),
           spanId: SpanId.random(),
           traceFlags: TraceFlags(),
           traceState: TraceState(),
           resource: Resource(),
           instrumentationScope: InstrumentationScopeInfo(),
           name: "span",
           kind: .internal,
           startTime: Date(),
           endTime: Date(),
           hasRemoteParent: false)
}

private func makeMetricExporter(base: OtlpHttpExporterBase<MetricData>) -> OtlpHttpMetricExporter {
  OtlpHttpMetricExporter(base: base,
                         aggregationTemporalitySelector: AggregationTemporality.alwaysCumulative(),
                         defaultAggregationSelector: AggregationSelector.instance)
}

final class OtlpHttpTraceExporterAsyncTests: XCTestCase {
  func testAsyncExportSuccess() async {
    let client = StubHTTPClient(outcomes: [.success])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    let result = await exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureRequeues() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              httpClient: client)
    let exporter = OtlpHttpTraceExporter(base: base)
    let result = await exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 1)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureWithRequeueDisabledLeavesPendingEmpty() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              httpClient: client,
                                              requeueOnFailure: false)
    let exporter = OtlpHttpTraceExporter(base: base)
    let result = await exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncFlushDrainsPendingOnSuccess() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              httpClient: client)
    let exporter = OtlpHttpTraceExporter(base: base)
    _ = await exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testAsyncFlushTimesOutWhenResponseNeverArrives() async {
    let timeout: TimeInterval = 0.1
    let client = TimeoutOnSecondSendHTTPClient()
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              config: OtlpConfiguration(timeout: timeout),
                                              httpClient: client)
    let exporter = OtlpHttpTraceExporter(base: base)
    _ = await exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let start = Date()
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .failure)
    XCTAssertLessThan(Date().timeIntervalSince(start), timeout * 4)
  }

  func testAsyncShutdownNoOp() async {
    let client = StubHTTPClient(outcomes: [])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    await exporter.shutdown()
  }
}

final class OtlpHttpLogExporterAsyncTests: XCTestCase {
  func testAsyncExportSuccess() async {
    let client = StubHTTPClient(outcomes: [.success])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    let result = await exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureRequeues() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)
    let result = await exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 1)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureWithRequeueDisabledLeavesPendingEmpty() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client,
                                                       requeueOnFailure: false)
    let exporter = OtlpHttpLogExporter(base: base)
    let result = await exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncFlushDrainsPendingOnSuccess() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)
    _ = await exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testAsyncFlushTimesOutWhenResponseNeverArrives() async {
    let timeout: TimeInterval = 0.1
    let client = TimeoutOnSecondSendHTTPClient()
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       config: OtlpConfiguration(timeout: timeout),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)
    _ = await exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let start = Date()
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .failure)
    XCTAssertLessThan(Date().timeIntervalSince(start), timeout * 4)
  }

  func testAsyncShutdownNoOp() async {
    let client = StubHTTPClient(outcomes: [])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    await exporter.shutdown()
  }
}

final class OtlpHttpMetricExporterAsyncTests: XCTestCase {
  func testAsyncExportSuccess() async {
    let client = StubHTTPClient(outcomes: [.success])
    let exporter = makeMetricExporter(base: OtlpHttpExporterBase<MetricData>(endpoint: defaultOtlpHttpMetricsEndpoint(),
                                                                            httpClient: client))
    let result = await exporter.export(metrics: [.empty])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureRequeues() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<MetricData>(endpoint: defaultOtlpHttpMetricsEndpoint(),
                                                httpClient: client)
    let exporter = makeMetricExporter(base: base)
    let result = await exporter.export(metrics: [.empty])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 1)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureWithRequeueDisabledLeavesPendingEmpty() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<MetricData>(endpoint: defaultOtlpHttpMetricsEndpoint(),
                                                httpClient: client,
                                                requeueOnFailure: false)
    let exporter = makeMetricExporter(base: base)
    let result = await exporter.export(metrics: [.empty])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncFlushDrainsPendingOnSuccess() async {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let base = OtlpHttpExporterBase<MetricData>(endpoint: defaultOtlpHttpMetricsEndpoint(),
                                                httpClient: client)
    let exporter = makeMetricExporter(base: base)
    _ = await exporter.export(metrics: [.empty])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testAsyncFlushTimesOutWhenResponseNeverArrives() async {
    let timeout: TimeInterval = 0.1
    let client = TimeoutOnSecondSendHTTPClient()
    let endpoint = URL(string: "http://localhost:4318/v1/metrics")!
    let base = OtlpHttpExporterBase<MetricData>(endpoint: endpoint,
                                                config: OtlpConfiguration(timeout: timeout),
                                                httpClient: client)
    let exporter = makeMetricExporter(base: base)
    _ = await exporter.export(metrics: [.empty])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let start = Date()
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .failure)
    XCTAssertLessThan(Date().timeIntervalSince(start), timeout * 4)
  }

  func testAsyncShutdownNoOp() async {
    let client = StubHTTPClient(outcomes: [])
    let exporter = makeMetricExporter(base: OtlpHttpExporterBase<MetricData>(endpoint: defaultOtlpHttpMetricsEndpoint(),
                                                                            httpClient: client))
    let result = await exporter.shutdown()
    XCTAssertEqual(result, .success)
  }
}
