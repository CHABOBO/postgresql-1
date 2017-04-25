import CPostgreSQL

// This structure represents a handle to one database connection.
// It is used for almost all PostgreSQL functions.
// Do not try to make a copy of a PostgreSQL structure.
// There is no guarantee that such a copy will be usable.
public final class Connection: ConnInfoInitializable {
    public let cConnection: OpaquePointer
    public var configuration: Configuration?
    public var isConnected: Bool {
        if PQstatus(cConnection) == CONNECTION_OK {
            return true
        }
        return false
    }

    public init(conninfo: ConnInfo) throws {
        let string: String

        switch conninfo {
        case .raw(let info):
            string = info
        case .params(let params):
            string = params.map({ "\($0)='\($1)'" }).joined()
        case .basic(let hostname, let port, let database, let user, let password):
            string = "host='\(hostname)' port='\(port)' dbname='\(database)' user='\(user)' password='\(password)' client_encoding='UTF8'"
        }

        self.cConnection = PQconnectdb(string)
        if isConnected == false {
            throw DatabaseError.cannotEstablishConnection(lastError)
        }
    }

    @discardableResult
    public func execute(_ query: String, _ values: [Node]? = []) throws -> [[String: Node]] {
        guard !query.isEmpty else {
            throw DatabaseError.noQuery
        }

        let values = values ?? []

        var types: [Oid] = []
        types.reserveCapacity(values.count)

        var paramValues: [[Int8]?] = []
        paramValues.reserveCapacity(values.count)

        var lengths: [Int32] = []
        lengths.reserveCapacity(values.count)

        var formats: [Int32] = []
        formats.reserveCapacity(values.count)

        for value in values {
            let (bytes, oid, format) = value.postgresBindingData
            paramValues.append(bytes)
            types.append(oid?.rawValue ?? 0)
            lengths.append(Int32(bytes?.count ?? 0))
            formats.append(format.rawValue)
        }

        let res: Result.Pointer = PQexecParams(
            cConnection, query,
            Int32(values.count),
            types, paramValues.map {
                UnsafePointer<Int8>($0)
            },
            lengths,
            formats,
            DataFormat.binary.rawValue
        )

        defer {
            PQclear(res)
        }

        switch Database.Status(result: res) {
        case .nonFatalError, .fatalError, .unknown:
            throw DatabaseError.invalidSQL(message: String(cString: PQresultErrorMessage(res)))
        case .tuplesOk:
            let configuration = try getConfiguration()
            return Result(configuration: configuration, pointer: res).parsed
        default:
            return []
        }
    }

    public func status() -> ConnStatusType {
        return PQstatus(cConnection)
    }

    public func reset() throws {
        guard self.isConnected else {
            throw PostgreSQLError(.connection_failure, reason: lastError)
        }

        PQreset(cConnection)
    }

    public func close() throws {
        guard self.isConnected else {
            throw PostgreSQLError(.connection_does_not_exist, reason: lastError)
        }

        PQfinish(cConnection)
    }

    // Contains the last error message generated by the PostgreSQL connection.
    public var lastError: String {
        guard let errorMessage = PQerrorMessage(cConnection) else {
            return ""
        }
        return String(cString: errorMessage)
    }

    deinit {
        try? close()
    }

    // MARK: - Load Configuration
    private func getConfiguration() throws -> Configuration {
        if let configuration = self.configuration {
            return configuration
        }

        let hasIntegerDatetimes = getBooleanParameterStatus(key: "integer_datetimes", default: true)

        let configuration = Configuration(hasIntegerDatetimes: hasIntegerDatetimes)
        self.configuration = configuration

        return configuration
    }

    private func getBooleanParameterStatus(key: String, `default` defaultValue: Bool = false) -> Bool {
        guard let value = PQparameterStatus(cConnection, "integer_datetimes") else {
            return defaultValue
        }
        return String(cString: value) == "on"
    }
}

extension Connection {
    @discardableResult
    public func execute(_ query: String, _ representable: [NodeRepresentable]) throws -> Node {
        let values = try representable.map {
            return try $0.makeNode(in: PostgreSQLContext.shared)
        }

        let result: [[String: Node]] = try execute(query, values)
        return try Node.array(result.map { try $0.makeNode(in: PostgreSQLContext.shared) })
    }
}
