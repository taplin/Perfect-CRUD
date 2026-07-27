//
//  Pool.swift
//  PerfectCRUD
//
//  Phase 1 (ADR-0001): a pool of DatabaseConfigurationProtocol connections,
//  checked out exclusively via withConnection(_:). Lives in PerfectCRUD
//  itself (zero dependencies, connector packages already depend on it, not
//  the reverse) so pooling is available to any consumer -- NIO routes, CLI
//  tools, plain scripts -- not just PerfectNIOCRUD callers.
//

import Dispatch

public actor DatabaseConnectionPool<C: DatabaseConfigurationProtocol & Sendable> {
	public struct Configuration: Sendable {
		public var minConnections: Int
		public var maxConnections: Int
		public init(minConnections: Int = 1, maxConnections: Int = 5) {
			self.minConnections = minConnections
			self.maxConnections = maxConnections
		}
	}

	// Waiter state is tracked explicitly (not just "is there a continuation")
	// so registration and cancellation are commutative regardless of which
	// happens first -- `onCancel` fires synchronously and non-isolated, so it
	// can't touch actor state directly; it hops via `Task { await ... }`,
	// which can race ahead of or behind the waiter's own registration.
	private enum WaiterState {
		case pending(CheckedContinuation<C, Error>)
		case cancelled
	}

	private let configuration: Configuration
	private let makeConnection: @Sendable () throws -> C

	private var available: [C] = []
	private var createdCount: Int = 0
	private var waiterOrder: [Int] = []
	private var waiters: [Int: WaiterState] = [:]
	private var nextWaiterID: Int = 0

	public init(configuration: Configuration = .init(), makeConnection: @escaping @Sendable () throws -> C) throws {
		self.configuration = configuration
		self.makeConnection = makeConnection
	}

	/// Pre-warms `configuration.minConnections` connections. Separate from
	/// `init` because connection creation is blocking work and must go
	/// through the same executor-hop as every other connection creation --
	/// `init` itself can't be async.
	public func prewarm() async throws {
		while createdCount < configuration.minConnections {
			let connection = try await createConnection()
			available.append(connection)
		}
	}

	/// Checks a connection out, runs `body`, always checks it back in --
	/// even on throw or task cancellation. This is the only supported
	/// access pattern; nothing in the type system stops a caller from
	/// capturing `db` out of `body` and using it after this returns, since
	/// `Database<C>` must itself be `Sendable` to cross the actor boundary
	/// -- that's a documented convention, not an enforced guarantee.
	public func withConnection<T: Sendable>(_ body: @Sendable (Database<C>) async throws -> T) async throws -> T {
		let connection = try await acquire()
		do {
			let result = try await body(Database(configuration: connection))
			await release(connection)
			return result
		} catch {
			await release(connection)
			throw error
		}
	}

	public var currentSize: Int { createdCount }
	public var availableCount: Int { available.count }

	/// Internal-only testability seam: lets tests poll for "N callers are
	/// genuinely blocked waiting" via `Task.yield()` rather than guessing a
	/// sleep duration, so queueing/FIFO-order tests are deterministic.
	var waitingCount: Int { waiterOrder.count }

	// MARK: - Internals

	// `createdCount` is incremented *before* the suspension below, not after
	// it succeeds -- the actor is reentrant across `await`, so a concurrent
	// `acquire()` call during that suspension must already see this as a
	// reserved slot, or two callers could each independently decide they're
	// allowed to create a connection and jointly exceed `maxConnections`.
	//
	// Known v1 limitation: if creation fails here, `createdCount` is
	// decremented (freeing the slot for a future attempt) but any callers
	// already queued in `waiters` are not woken to retry -- they keep
	// waiting for a `release()`. No deadlock (a later successful `acquire()`
	// or an actual release still serves them eventually), just a rare
	// capacity-tracking suboptimality on creation failure. Connection
	// liveness/retry is explicitly out of scope for v1 (see the ADR
	// implementation plan's Phase 1 risks).
	private func createConnection() async throws -> C {
		createdCount += 1
		do {
			return try await withCRUDExecutor { [makeConnection] in try makeConnection() }
		} catch {
			createdCount -= 1
			throw error
		}
	}

	private func acquire() async throws -> C {
		if let existing = available.popLast() {
			return existing
		}
		if createdCount < configuration.maxConnections {
			return try await createConnection()
		}
		let id = nextWaiterID
		nextWaiterID += 1
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<C, Error>) in
				// A cancel that raced ahead of registration (onCancel can fire
				// before this closure runs, for an already-cancelled task)
				// leaves a `.cancelled` marker here -- honor it immediately
				// instead of queueing a waiter nothing will ever cancel again.
				if case .cancelled = waiters[id] {
					waiters[id] = nil
					continuation.resume(throwing: CancellationError())
					return
				}
				waiters[id] = .pending(continuation)
				waiterOrder.append(id)
			}
		} onCancel: {
			Task { await self.cancelWaiter(id) }
		}
	}

	private func release(_ connection: C) {
		while let id = waiterOrder.first {
			waiterOrder.removeFirst()
			guard case .pending(let continuation) = waiters[id] else {
				// A stale id that cancelWaiter() already resolved (and removed
				// its own entry for) before release() got here -- skip it.
				continue
			}
			waiters[id] = nil
			continuation.resume(returning: connection)
			return
		}
		available.append(connection)
	}

	private func cancelWaiter(_ id: Int) {
		switch waiters[id] {
		case .pending(let continuation):
			waiters[id] = nil
			// Remove from waiterOrder too, not just the state dictionary --
			// `waitingCount` (and any future pool-introspection API built on
			// it) must reflect callers actually still waiting, not ones that
			// already gave up. Pool sizes/waiter counts are small (this is a
			// DB connection pool), so the O(n) removal cost is negligible.
			waiterOrder.removeAll { $0 == id }
			continuation.resume(throwing: CancellationError())
		case .cancelled:
			break // already handled
		case .none:
			// Registration hasn't run yet; mark so it resumes immediately
			// instead of queueing when it does.
			waiters[id] = .cancelled
		}
	}
}
