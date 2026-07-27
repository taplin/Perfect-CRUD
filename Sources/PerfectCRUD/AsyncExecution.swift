//
//  AsyncExecution.swift
//  PerfectCRUD
//
//  Shared blocking-dispatch primitive for moving synchronous, blocking
//  connector work (opening a connection, running a query) off whatever
//  executor called into PerfectCRUD -- critically, off Swift's default
//  cooperative thread pool, which must never block on C-library I/O
//  (libmysqlclient/libpq/sqlite3 have no async story of their own).
//
//  Introduced in Phase 1 (ADR-0001) for DatabaseConnectionPool's connection
//  creation, and reused as-is by Phase 2's async Database/Table/Selectable
//  overloads. Continuation-based dispatch, not a custom TaskExecutor: per
//  ADR-0001's implementation-plan review, the two approaches are equally
//  safe here, and this one is simpler, keeps the caller's own task
//  suspended (no extra unstructured Task per call), and gets the Swift
//  runtime's double-resume/never-resumed detection for free.
//
//  Cancellation is best-effort only: neither this design nor a custom
//  TaskExecutor can interrupt a blocking C call already in flight -- there
//  is no suspension point inside e.g. mysql_stmt_execute() for Swift's
//  cooperative cancellation to act on. A cancelled caller's task simply
//  keeps waiting for the underlying work to finish.
//

import Dispatch

enum CRUDBlockingQueue {
	static let shared = DispatchQueue(label: "PerfectCRUD.blocking", qos: .userInitiated, attributes: .concurrent)
}

func withCRUDExecutor<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		CRUDBlockingQueue.shared.async {
			do {
				continuation.resume(returning: try body())
			} catch {
				continuation.resume(throwing: error)
			}
		}
	}
}
