import Foundation

public enum TransferAgeUnit: String,Codable,CaseIterable {
    case minutes,hours,days,weeks
    var seconds: Int64 {
        switch self { case .minutes:return 60;case .hours:return 3600;case .days:return 86400;case .weeks:return 604800 }
    }
}

public struct TransferAgeLimit: Codable,Equatable {
    public let amount: Int64
    public let unit: TransferAgeUnit
    public init(_ amount: Int64,unit: TransferAgeUnit) { self.amount = amount;self.unit = unit }
    public func seconds() throws -> Int64 {
        let result = amount.multipliedReportingOverflow(by:unit.seconds)
        guard amount >= 0,!result.overflow,result.partialValue <= 100*365*86400 else {
            throw CommanderError.message("Altersgrenzen müssen zwischen 0 und 36.500 Tagen liegen.")
        }
        return result.partialValue
    }
    public static func parse(_ text: String,unit: TransferAgeUnit) throws -> TransferAgeLimit? {
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard text.utf8.count <= 20,text.utf8.allSatisfy({ (48...57).contains($0) }),let amount = Int64(text) else {
            throw CommanderError.message("Das Alter als ganze Zahl eingeben. Ein leeres Feld bedeutet keine Grenze.")
        }
        let value = TransferAgeLimit(amount,unit:unit);_ = try value.seconds();return value
    }
}

public struct TransferAgeRange: Codable,Equatable {
    public let minimum: TransferAgeLimit?
    public let maximum: TransferAgeLimit?
    public init(minimum: TransferAgeLimit? = nil,maximum: TransferAgeLimit? = nil) { self.minimum = minimum;self.maximum = maximum }
    public func validate() throws {
        guard minimum != nil || maximum != nil else { throw CommanderError.message("Für ein relatives Alter mindestens eine Grenze eingeben.") }
        let lower = try minimum?.seconds() ?? 0,upper = try maximum?.seconds()
        if let upper,lower > upper { throw CommanderError.message("Das Mindestalter darf nicht über dem Höchstalter liegen.") }
    }
}
