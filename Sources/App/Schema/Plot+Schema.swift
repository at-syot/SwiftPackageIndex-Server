import Foundation
import Plot

protocol Schema: Encodable {
    var context: String { get }
    var type: String { get }
}

extension Node where Context == HTML.BodyContext {
    
    static func structuredData<T>(_ model: T) -> Node<HTML.BodyContext> where T: Schema {
        let encoder = JSONEncoder()
        
        do {
            let data = try encoder.encode(model)
            let rawScript = String(decoding: data, as: UTF8.self)
            
            return .script(
                .attribute(named: "type", value: "application/ld+json"),
                .raw(rawScript)
            )
        } catch {
            AppEnvironment.logger?.error("Failed to encode structured data model: \(error)")
            return .empty
        }
    }
    
}
