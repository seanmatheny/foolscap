import Foundation

/// Python's `difflib.SequenceMatcher(None, a, b).ratio()`: the Ratcliff/Obershelp
/// similarity, 2·M / (|a| + |b|), with difflib's choice of longest block (ties go
/// to the earliest position in `a`, then in `b`) and no junk heuristic, which only
/// applies to strings of 200+ characters anyway.
public enum SequenceMatcher {
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        let total = x.count + y.count
        guard total > 0 else { return 1 }
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (j, ch) in y.enumerated() { b2j[ch, default: []].append(j) }
        var matched = 0
        var queue = [(0, x.count, 0, y.count)]
        while let range = queue.popLast() {
            let (alo, ahi, blo, bhi) = range
            let (i, j, k) = longestMatch(x, b2j, alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            matched += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return 2 * Double(matched) / Double(total)
    }

    private static func longestMatch(_ a: [Unicode.Scalar], _ b2j: [Unicode.Scalar: [Int]],
                                     _ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
            }
            j2len = newj2len
        }
        return (besti, bestj, bestsize)
    }
}
