import Foundation

/// Finder-compatible "natural" name ordering (case-insensitive, numbers
/// compared by value: "File 2" < "File 10").
///
/// `localizedStandardCompare` is correct but costs about a microsecond per
/// comparison. Names are pre-folded once into a compact key so sorting tens of
/// thousands of entries takes a few milliseconds; names with non-ASCII
/// characters fall back to the localized comparison.
struct NameSortKey {
    let name: String
    /// Lower-cased ASCII bytes, or nil when the name needs Unicode-aware comparison.
    let folded: [UInt8]?

    init(_ name: String) {
        self.name = name
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.utf8.count)
        var ascii = true
        for b in name.utf8 {
            if b >= 0x80 { ascii = false; break }
            bytes.append(b >= 65 && b <= 90 ? b + 32 : b)
        }
        folded = ascii ? bytes : nil
    }

    static func compare(_ a: NameSortKey, _ b: NameSortKey) -> ComparisonResult {
        guard let x = a.folded, let y = b.folded else {
            return a.name.localizedStandardCompare(b.name)
        }
        let result = x.withUnsafeBufferPointer { xs in y.withUnsafeBufferPointer { ys in compareFolded(xs, ys) } }
        if result != .orderedSame { return result }
        // Equal ignoring case: fall back to a stable, case-sensitive order.
        return a.name < b.name ? .orderedAscending : (a.name == b.name ? .orderedSame : .orderedDescending)
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// Natural order of two folded names (see `folded`), without bounds checks.
    static func compareFolded(_ x: UnsafeBufferPointer<UInt8>, _ y: UnsafeBufferPointer<UInt8>) -> ComparisonResult {
        var i = 0, j = 0
        let n = x.count, m = y.count
        while i < n && j < m {
            let c = x[i], d = y[j]
            if isDigit(c) && isDigit(d) {
                // Compare digit runs numerically: skip leading zeros, then by length, then lexically.
                var si = i; while si < n && x[si] == 48 { si += 1 }
                var sj = j; while sj < m && y[sj] == 48 { sj += 1 }
                var ei = si; while ei < n && isDigit(x[ei]) { ei += 1 }
                var ej = sj; while ej < m && isDigit(y[ej]) { ej += 1 }
                let li = ei - si, lj = ej - sj
                if li != lj { return li < lj ? .orderedAscending : .orderedDescending }
                var k = 0
                while k < li {
                    if x[si + k] != y[sj + k] { return x[si + k] < y[sj + k] ? .orderedAscending : .orderedDescending }
                    k += 1
                }
                // Same value; more leading zeros sorts later.
                let zi = si - i, zj = sj - j
                if zi != zj { return zi < zj ? .orderedAscending : .orderedDescending }
                i = ei; j = ej
                continue
            }
            if c != d {
                // Punctuation and spaces sort before letters and digits, like Finder.
                let rc = rank(c), rd = rank(d)
                if rc != rd { return rc < rd ? .orderedAscending : .orderedDescending }
                return c < d ? .orderedAscending : .orderedDescending
            }
            i += 1; j += 1
        }
        if i < n { return .orderedDescending }
        if j < m { return .orderedAscending }
        return .orderedSame
    }

    @inline(__always)
    private static func rank(_ c: UInt8) -> Int {
        if isDigit(c) { return 1 }
        if c >= 97 && c <= 122 { return 2 }
        return 0
    }
}
