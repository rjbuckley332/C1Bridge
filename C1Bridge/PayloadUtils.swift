import Foundation

public enum PayloadError: Error {
    case invalidHex
}

public struct PayloadUtils {
    public static func dataFromHexString(_ hex: String) -> Data? {
        let s = hex.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            let byteStr = s[idx..<next]
            guard let b = UInt8(byteStr, radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }
}
