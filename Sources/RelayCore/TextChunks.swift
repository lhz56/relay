import Foundation

public enum TextChunks {
    public static func unicode(_ text: String, limit: Int = 20) -> [[UInt16]] {
        var result: [[UInt16]] = [], chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if !chunk.isEmpty, chunk.count + units.count > max(2, limit) { result.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
