//
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//

import Foundation

final class OtlpHttpPendingExportState<Signal: Sendable>: @unchecked Sendable {
  private var pending: [Signal] = []
  private let lock = Lock()

  func drain(adding items: [Signal]) -> [Signal] {
    lock.withLock {
      pending.append(contentsOf: items)
      let sending = pending
      pending = []
      return sending
    }
  }

  func snapshot() -> [Signal] {
    lock.withLock { pending }
  }

  func requeue(_ items: [Signal]) {
    lock.withLockVoid {
      pending.append(contentsOf: items)
    }
  }
}
