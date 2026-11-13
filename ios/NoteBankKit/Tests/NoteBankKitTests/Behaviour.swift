import Foundation

struct Behaviour {
    struct Action: Decodable, Equatable {
        let id: String
        let label: String
    }
    struct Expectation: Decodable {
        var message: String?
        var buttons: [String]?
        var duration_seconds: Double?
        var menu: [Action]?
        var row: Bool?
        var batch: [Action]?
        var offered: Bool?
        var label: String?

        func message(_ values: [String: String] = [:]) -> String {
            values.reduce(message!) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
    }
    static func rule(_ id: String) throws -> Expectation {
        var repo = URL(filePath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let data = try Data(contentsOf: repo.appending(path: "behaviour/behaviour.json"))
        let file = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rules = file["rules"] as! [String: [String: Any]]
        let rule = rules[id]!
        var expected = rule["expect"] as! [String: Any]
        if let differs = rule["differs"] as? [String: [String: Any]], let ios = differs["ios"], let override = ios["expect"] as? [String: Any] {
            expected.merge(override) { _, new in new }
        }
        return try JSONDecoder().decode(Expectation.self, from: JSONSerialization.data(withJSONObject: expected))
    }
}
