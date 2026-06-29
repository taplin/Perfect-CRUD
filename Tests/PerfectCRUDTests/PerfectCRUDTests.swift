import Testing
import Foundation
@testable import PerfectCRUD

// MARK: - Test models

private struct User: Codable {
	var id: Int
	var name: String
	var email: String?
}

private struct Post: Codable, TableNameProvider {
	static let tableName = "posts"
	var id: Int
	var title: String
}

// MARK: - Stub infrastructure

private final class StubGenDelegate: SQLGenDelegate, @unchecked Sendable {
	var bindings: Bindings = []

	func getBinding(for expr: CRUDExpression) throws -> String {
		bindings.append(("?", expr))
		return "?"
	}

	func quote(identifier: String) throws -> String { "\"\(identifier)\"" }

	func getCreateTableSQL(forTable: TableStructure, policy: TableCreatePolicy) throws -> [String] { [] }
	func getCreateIndexSQL(forTable name: String, on columns: [String], unique: Bool) throws -> [String] { [] }
}

private struct StubExeDelegate: SQLExeDelegate {
	func bind(_ bindings: Bindings, skip: Int) throws {}
	func hasNext() throws -> Bool { false }
	func next<A: CodingKey>() throws -> KeyedDecodingContainer<A>? { nil }
}

private final class StubConfig: DatabaseConfigurationProtocol, @unchecked Sendable {
	var capturedSQL: [String] = []

	var sqlGenDelegate: SQLGenDelegate { StubGenDelegate() }

	func sqlExeDelegate(forSQL sql: String) throws -> SQLExeDelegate {
		capturedSQL.append(sql)
		return StubExeDelegate()
	}

	required init(url: String? = nil, name: String? = nil, host: String? = nil,
				  port: Int? = nil, user: String? = nil, pass: String? = nil) throws {}
}

private func makeDB() throws -> (Database<StubConfig>, StubConfig) {
	let config = try StubConfig()
	return (Database(configuration: config), config)
}

// MARK: - Test suite

@Suite("PerfectCRUD SQL generation", .serialized)
struct PerfectCRUDTests {

	// MARK: Table name

	@Test func tableNameFromType() {
		#expect(User.CRUDTableName == "User")
	}

	@Test func tableNameFromProvider() {
		#expect(Post.CRUDTableName == "posts")
	}

	// MARK: Table structure

	@Test func columnNames() throws {
		CRUDClearTableStructureCache()
		let s = try User.CRUDTableStructure()
		let names = Set(s.columns.map { $0.name })
		#expect(names == ["id", "name", "email"])
	}

	@Test func optionalColumn() throws {
		CRUDClearTableStructureCache()
		let s = try User.CRUDTableStructure()
		#expect(s.columns.first { $0.name == "email" }?.optional == true)
		#expect(s.columns.first { $0.name == "name" }?.optional == false)
	}

	@Test func primaryKeyByConvention() throws {
		CRUDClearTableStructureCache()
		#expect(try User.CRUDTableStructure().primaryKeyName == "id")
	}

	// MARK: SELECT SQL
	// SELECT SQL is generated eagerly in Select.init and available in sqlGenState.statements
	// without triggering the lazy iterator (which only fires sqlExeDelegate on makeIterator()).

	@Test func selectSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("SELECT"))
		#expect(sql.contains("\"User\""))
	}

	@Test func whereEqualitySQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.name == "Alice").select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("WHERE"))
		#expect(sql.contains("\"name\""))
		#expect(sql.contains("?"))
	}

	@Test func whereNullSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.email == nil).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("IS NULL"))
	}

	@Test func whereNotNullSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.email != nil).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("IS NOT NULL"))
	}

	@Test func whereAndSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.id == 1 && \User.name == "Alice").select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("AND"))
	}

	@Test func whereOrSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.name == "Alice" || \User.name == "Bob").select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("OR"))
	}

	@Test func whereLikeSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.name %=% "ali").select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("LIKE"))
	}

	@Test func whereInSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).where(\User.id ~ [1, 2, 3]).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("IN"))
	}

	@Test func orderBySQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).order(by: \User.name).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("ORDER BY"))
		#expect(sql.contains("\"name\""))
	}

	@Test func orderByDescSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).order(descending: \User.name).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("DESC"))
	}

	@Test func limitSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).limit(5).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("LIMIT"))
		#expect(sql.contains("5"))
	}

	@Test func limitWithOffsetSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(User.self).limit(10, skip: 3).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("LIMIT"))
		#expect(sql.contains("OFFSET"))
	}

	@Test func customTableNameInSQL() throws {
		CRUDClearTableStructureCache()
		let (database, _) = try makeDB()
		let select = try database.table(Post.self).select()
		let sql = try #require(select.sqlGenState.statements.first?.sql)
		#expect(sql.contains("\"posts\""))
		#expect(!sql.contains("\"Post\""))
	}

	// MARK: INSERT SQL

	@Test func insertSQL() throws {
		CRUDClearTableStructureCache()
		let (database, config) = try makeDB()
		_ = try database.table(User.self).insert(User(id: 1, name: "Alice", email: nil))
		let sql = try #require(config.capturedSQL.first)
		#expect(sql.contains("INSERT"))
		#expect(sql.contains("\"User\""))
		#expect(sql.contains("\"name\""))
	}

	@Test func insertIgnoreKeySQL() throws {
		CRUDClearTableStructureCache()
		let (database, config) = try makeDB()
		_ = try database.table(User.self).insert(
			User(id: 1, name: "Alice", email: "a@b.com"),
			ignoreKeys: \User.email
		)
		let sql = try #require(config.capturedSQL.first)
		#expect(sql.contains("INSERT"))
		#expect(!sql.contains("\"email\""))
	}

	// MARK: UPDATE SQL

	@Test func updateWhereSQL() throws {
		CRUDClearTableStructureCache()
		let (database, config) = try makeDB()
		_ = try database.table(User.self)
			.where(\User.id == 1)
			.update(User(id: 1, name: "Bob", email: nil), setKeys: \.name)
		let sql = try #require(config.capturedSQL.first)
		#expect(sql.contains("UPDATE"))
		#expect(sql.contains("\"User\""))
		#expect(sql.contains("SET"))
	}

	// MARK: DELETE SQL

	@Test func deleteWhereSQL() throws {
		CRUDClearTableStructureCache()
		let (database, config) = try makeDB()
		try database.table(User.self).where(\User.id == 99).delete()
		let sql = try #require(config.capturedSQL.first)
		#expect(sql.contains("DELETE"))
		#expect(sql.contains("\"User\""))
		#expect(sql.contains("WHERE"))
	}
}
