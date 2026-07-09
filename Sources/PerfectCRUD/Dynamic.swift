import Foundation

public enum DynamicValue: Equatable, Sendable {
	case null
	case bool(Bool)
	case int(Int64)
	case uint(UInt64)
	case double(Double)
	case string(String)
	case bytes([UInt8])
	case date(Date)

	var crudExpression: CRUDExpression {
		switch self {
		case .null: .null
		case .bool(let value): .bool(value)
		case .int(let value): .integer64(value)
		case .uint(let value): .uinteger64(value)
		case .double(let value): .decimal(value)
		case .string(let value): .string(value)
		case .bytes(let value): .blob(value)
		case .date(let value): .date(value)
		}
	}
}

public struct DynamicRow: Equatable, Sendable {
	public let values: [String: DynamicValue]

	public init(_ values: [String: DynamicValue]) {
		self.values = Dictionary(uniqueKeysWithValues: values.map {
			($0.key.lowercased(), $0.value)
		})
	}

	public subscript(_ field: String) -> DynamicValue? {
		values[field.lowercased()]
	}
}

public enum DynamicComparison: Equatable, Sendable {
	case equal
	case notEqual
	case greaterThan
	case greaterThanOrEqual
	case lessThan
	case lessThanOrEqual
	case beginsWith
	case endsWith
	case contains
}

public struct DynamicPredicate: Equatable, Sendable {
	public let field: String
	public let comparison: DynamicComparison
	public let value: DynamicValue

	public init(field: String, comparison: DynamicComparison, value: DynamicValue) {
		self.field = field
		self.comparison = comparison
		self.value = value
	}
}

public struct DynamicOrdering: Equatable, Sendable {
	public let field: String
	public let descending: Bool

	public init(field: String, descending: Bool = false) {
		self.field = field
		self.descending = descending
	}
}

public struct DynamicQuery: Equatable, Sendable {
	public let table: String
	public let fields: [String]
	public let predicates: [DynamicPredicate]
	public let orderings: [DynamicOrdering]
	public let limit: Int?
	public let offset: Int?

	public init(
		table: String,
		fields: [String] = [],
		predicates: [DynamicPredicate] = [],
		orderings: [DynamicOrdering] = [],
		limit: Int? = nil,
		offset: Int? = nil
	) {
		self.table = table
		self.fields = fields
		self.predicates = predicates
		self.orderings = orderings
		self.limit = limit
		self.offset = offset
	}
}

public struct DynamicResult: Equatable, Sendable {
	public let rows: [DynamicRow]
	public let affectedRows: Int
	public let statement: String

	public init(rows: [DynamicRow], affectedRows: Int = 0, statement: String) {
		self.rows = rows
		self.affectedRows = affectedRows
		self.statement = statement
	}
}

public protocol DynamicDatabaseProtocol: DatabaseProtocol {
	func select(_ query: DynamicQuery) throws -> DynamicResult
}

extension Database: DynamicDatabaseProtocol {
	public func select(_ query: DynamicQuery) throws -> DynamicResult {
		var compiler = DynamicQueryCompiler(
			query: query,
			delegate: configuration.sqlGenDelegate
		)
		let generated = try compiler.compile()
		CRUDLogging.log(.query, generated.sql)
		let executor = try configuration.sqlExeDelegate(forSQL: generated.sql)
		try executor.bind(generated.bindings, skip: 0)
		var rows: [DynamicRow] = []
		while try executor.hasNext() {
			guard let row = try executor.nextDynamicRow() else {
				throw CRUDSQLExeError("Connector returned no dynamic row for an available result.")
			}
			rows.append(row)
		}
		return DynamicResult(rows: rows, statement: generated.sql)
	}
}

private struct DynamicQueryCompiler {
	let query: DynamicQuery
	var delegate: SQLGenDelegate

	mutating func compile() throws -> (sql: String, bindings: Bindings) {
		guard query.table.isEmpty == false else {
			throw CRUDSQLGenError("Dynamic query requires a table.")
		}
		if let limit = query.limit, limit < 0 {
			throw CRUDSQLGenError("Dynamic query limit must not be negative.")
		}
		if let offset = query.offset, offset < 0 {
			throw CRUDSQLGenError("Dynamic query offset must not be negative.")
		}

		delegate.bindings = []
		let fields = try query.fields.isEmpty
			? "*"
			: query.fields.map { try delegate.quote(identifier: $0) }.joined(separator: ", ")
		var sql = "SELECT \(fields) FROM \(try delegate.quote(identifier: query.table))"

		if query.predicates.isEmpty == false {
			var clauses: [String] = []
			for predicate in query.predicates {
				clauses.append(try compilePredicate(predicate))
			}
			sql += " WHERE " + clauses.joined(separator: " AND ")
		}
		if query.orderings.isEmpty == false {
			let clauses = try query.orderings.map {
				try delegate.quote(identifier: $0.field) + ($0.descending ? " DESC" : "")
			}
			sql += " ORDER BY " + clauses.joined(separator: ", ")
		}
		if let limit = query.limit {
			sql += " LIMIT \(limit)"
		}
		if let offset = query.offset {
			guard query.limit != nil else {
				throw CRUDSQLGenError("Dynamic query offset requires a limit.")
			}
			sql += " OFFSET \(offset)"
		}
		return (sql, delegate.bindings)
	}

	private mutating func compilePredicate(_ predicate: DynamicPredicate) throws -> String {
		let field = try delegate.quote(identifier: predicate.field)
		switch (predicate.comparison, predicate.value) {
		case (.equal, .null):
			return "\(field) IS NULL"
		case (.notEqual, .null):
			return "\(field) IS NOT NULL"
		default:
			break
		}

		let operation: String
		let value: DynamicValue
		switch predicate.comparison {
		case .equal:
			operation = "="
			value = predicate.value
		case .notEqual:
			operation = "!="
			value = predicate.value
		case .greaterThan:
			operation = ">"
			value = predicate.value
		case .greaterThanOrEqual:
			operation = ">="
			value = predicate.value
		case .lessThan:
			operation = "<"
			value = predicate.value
		case .lessThanOrEqual:
			operation = "<="
			value = predicate.value
		case .beginsWith:
			operation = "LIKE"
			value = .string(predicate.value.stringValue + "%")
		case .endsWith:
			operation = "LIKE"
			value = .string("%" + predicate.value.stringValue)
		case .contains:
			operation = "LIKE"
			value = .string("%" + predicate.value.stringValue + "%")
		}
		let placeholder = try delegate.getBinding(for: value.crudExpression)
		return "\(field) \(operation) \(placeholder)"
	}
}

private extension DynamicValue {
	var stringValue: String {
		switch self {
		case .null: ""
		case .bool(let value): value ? "true" : "false"
		case .int(let value): String(value)
		case .uint(let value): String(value)
		case .double(let value): String(value)
		case .string(let value): value
		case .bytes(let value): String(decoding: value, as: UTF8.self)
		case .date(let value): value.ISO8601Format()
		}
	}
}
