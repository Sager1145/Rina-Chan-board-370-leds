import Foundation

/// Shared factory hotspot address and editable private /24 gateway policy.
public enum BoardAPAddress {
    public static func defaultAddress(boardID: String) -> String? {
        guard boardID.utf8.count == 12,
              boardID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let suffix = UInt32(boardID.suffix(6), radix: 16) else { return nil }
        let a = Int((suffix >> 16) & 255)
        let b = Int((suffix >> 8) & 255)
        let c = Int(suffix & 255)
        if (1...254).contains(c) { return "10.\(a).\(b).\(c)" }
        let index = Int(suffix >> 8) * 2 + (c == 255 ? 1 : 0)
        let subnet = index / 254
        return "172.\(16 + subnet / 256).\(subnet % 256).\(index % 254 + 1)"
    }

    /// Accept decimal octets only and return their canonical spelling.
    /// A private gateway must also be a usable host in its /24 subnet.
    public static func canonicalPrivateAddress(_ address: String) -> String? {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var octets: [Int] = []
        for field in fields {
            guard (1...3).contains(field.utf8.count),
                  field.utf8.allSatisfy({ (48...57).contains($0) }),
                  (field.count == 1 || field.first != "0"),
                  let value = Int(field), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        let isPrivate = octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
        guard isPrivate, (1...254).contains(octets[3]) else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }
}
