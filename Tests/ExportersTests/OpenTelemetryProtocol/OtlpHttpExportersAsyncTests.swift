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

private final class AsyncStubHTTPClient: HTTPClient {
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

private struct AsyncTransientNetworkError: Error {}

private final class AsyncHangingAfterFirstFailureHTTPClient: HTTPClient {
  private var sendCount = 0

  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sendCount += 1
    if sendCount == 1 {
      completion(.failure(AsyncTransientNetworkError()))
    }
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sendCount += 1
    if sendCount == 1 {
      throw AsyncTransientNetworkError()
    }
    try await Task.sleep(nanoseconds: UInt64(request.timeoutInterval * 1_000_000_000))
    throw URLError(.timedOut)
  }
}

private func asyncSampleLogRecord() -> ReadableLogRecord {
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

private func asyncSampleSpanData() -> SpanData {
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

final class OtlpHttpTraceExporterAsyncTests: XCTestCase {
  func testAsyncExportSuccessSendsRequest() async {
    let client = AsyncStubHTTPClient(outcomes: [.success])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    let result = await exporter.export(spans: [asyncSampleSpanData()])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureReturnsFailure() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError())])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    let result = await exporter.export(spans: [asyncSampleSpanData()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(exporter.pendingSpans.count, 1)
  }

  func testAsyncExportFailureWithRequeueDisabledLeavesPendingEmpty() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError())])
    let exporter = OtlpHttpTraceExporter(httpClient: client, requeueOnFailure: false)
    let result = await exporter.export(spans: [asyncSampleSpanData()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(exporter.pendingSpans.count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncFlushWithPendingSpans() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError()), .success])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    _ = await exporter.export(spans: [asyncSampleSpanData()])
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(exporter.pendingSpans.count, 0)
  }

  func testAsyncFlushFailureAfterRetryReturnsFailure() async {
    let client = AsyncStubHTTPClient(outcomes: [
      .failure(AsyncTransientNetworkError()),
      .failure(AsyncTransientNetworkError())
    ])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    _ = await exporter.export(spans: [asyncSampleSpanData()])
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .failure)
  }

  func testAsyncFlushTimesOutWhenResponseNeverArrives() async {
    let timeout: TimeInterval = 0.5
    let client = AsyncHangingAfterFirstFailureHTTPClient()
    let exporter = OtlpHttpTraceExporter(
      config: OtlpConfiguration(timeout: timeout),
      httpClient: client)
    _ = await exporter.export(spans: [asyncSampleSpanData()])
    XCTAssertEqual(exporter.pendingSpans.count, 1)

    let start = Date()
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .failure)
    XCTAssertLessThan(Date().timeIntervalSince(start), timeout * 4)
  }

  func testAsyncShutdownReturnsWithoutError() async {
    let client = AsyncStubHTTPClient(outcomes: [])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    await exporter.shutdown()
  }
}

final class OtlpHttpLogExporterAsyncTests: XCTestCase {
  func testAsyncExportFailureReturnsFailure() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError())])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    let result = await exporter.export(logRecords: [asyncSampleLogRecord()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(exporter.pendingLogRecords.count, 1)
  }

  func testAsyncExportSuccessReturnsSuccess() async {
    let client = AsyncStubHTTPClient(outcomes: [.success])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    let result = await exporter.export(logRecords: [asyncSampleLogRecord()])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureWithRequeueDisabledLeavesPendingEmpty() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError())])
    let exporter = OtlpHttpLogExporter(httpClient: client, requeueOnFailure: false)
    let result = await exporter.export(logRecords: [asyncSampleLogRecord()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(exporter.pendingLogRecords.count, 0)
  }

  func testAsyncFlushWithPendingLogRecordsSuccess() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError()), .success])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    _ = await exporter.export(logRecords: [asyncSampleLogRecord()])
    let flushResult = await exporter.forceFlush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(exporter.pendingLogRecords.count, 0)
  }

  func testAsyncFlushTimesOutWhenResponseNeverArrives() async {
    let timeout: TimeInterval = 0.5
    let client = AsyncHangingAfterFirstFailureHTTPClient()
    let exporter = OtlpHttpLogExporter(
      config: OtlpConfiguration(timeout: timeout),
      httpClient: client)
    _ = await exporter.export(logRecords: [asyncSampleLogRecord()])
    XCTAssertEqual(exporter.pendingLogRecords.count, 1)

    let start = Date()
    let flushResult = await exporter.forceFlush()
    XCTAssertEqual(flushResult, .failure)
    XCTAssertLessThan(Date().timeIntervalSince(start), timeout * 4)
  }

  func testAsyncShutdownReturnsWithoutError() async {
    let client = AsyncStubHTTPClient(outcomes: [])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    await exporter.shutdown()
  }
}

final class OtlpHttpMetricExporterAsyncTests: XCTestCase {
  func testAsyncExportFailureReturnsFailure() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError())])
    let exporter = OtlpHttpMetricExporter(
      endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
      httpClient: client)
    let result = await exporter.export(metrics: [.empty])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(exporter.pendingMetrics.count, 1)
  }

  func testAsyncExportSuccessReturnsSuccess() async {
    let client = AsyncStubHTTPClient(outcomes: [.success])
    let exporter = OtlpHttpMetricExporter(
      endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
      httpClient: client)
    let result = await exporter.export(metrics: [.empty])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testAsyncExportFailureWithRequeueDisabledLeavesPendingEmpty() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError())])
    let exporter = OtlpHttpMetricExporter(
      endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
      httpClient: client,
      requeueOnFailure: false)
    let result = await exporter.export(metrics: [.empty])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(exporter.pendingMetrics.count, 0)
  }

  func testAsyncFlushWithPendingMetricsSuccess() async {
    let client = AsyncStubHTTPClient(outcomes: [.failure(AsyncTransientNetworkError()), .success])
    let exporter = OtlpHttpMetricExporter(
      endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
      httpClient: client)
    _ = await exporter.export(metrics: [.empty])
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(exporter.pendingMetrics.count, 0)
  }

  func testAsyncFlushTimesOutWhenResponseNeverArrives() async {
    let timeout: TimeInterval = 0.5
    let client = AsyncHangingAfterFirstFailureHTTPClient()
    let exporter = OtlpHttpMetricExporter(
      endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
      config: OtlpConfiguration(timeout: timeout),
      httpClient: client)
    _ = await exporter.export(metrics: [.empty])
    XCTAssertEqual(exporter.pendingMetrics.count, 1)

    let start = Date()
    let flushResult = await exporter.flush()
    XCTAssertEqual(flushResult, .failure)
    XCTAssertLessThan(Date().timeIntervalSince(start), timeout * 4)
  }

  func testAsyncShutdownReturnsSuccess() async {
    let client = AsyncStubHTTPClient(outcomes: [])
    let exporter = OtlpHttpMetricExporter(
      endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
      httpClient: client)
    let shutdownResult = await exporter.shutdown()
    XCTAssertEqual(shutdownResult, .success)
  }
}
