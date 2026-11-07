import Foundation

// MARK: - Gold standard

struct GoldStandard {
    var event: [Int: String] = [:]          // corpus index -> same-event cluster
    var groups: [Int: Set<String>] = [:]    // corpus index -> related-story groups
    init(path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var members: [String: [Int]] = [:]
        var groupLines: [(String, [String])] = []
        for raw in text.split(separator: "\n") where !raw.hasPrefix("#") {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].split(separator: " ").map(String.init)
            let tokens = line[line.index(after: colon)...].split(separator: " ").map(String.init)
            guard head.count == 2 else { continue }
            if head[0] == "E" {
                let indices = tokens.compactMap(Int.init)
                members[head[1]] = indices
                for i in indices { event[i] = head[1] }
            } else if head[0] == "G" { groupLines.append((head[1], tokens)) }
        }
        for (name, tokens) in groupLines {
            for token in tokens {
                if let i = Int(token) { groups[i, default: []].insert(name) }
                else if let indices = members[token] { for i in indices { groups[i, default: []].insert(name) } }
                else { print("warning: unknown token \(token) in group \(name)") }
            }
        }
    }
}

enum Relation: UInt8 { case different = 0, related = 1, same = 2 }

// MARK: - Units (the app already merges identical titles / URLs, so those collapse into one unit)

struct EvalSet {
    let corpus: Corpus
    let units: [Int]                 // representative corpus index per unit
    let members: [[Int]]             // corpus indices per unit
    let relation: [Relation]         // flat upper-triangular by unit pair
    let signals: [PairSignals]       // same layout
    let n: Int
    let gold: GoldStandard
    func pairIndex(_ a: Int, _ b: Int) -> Int {
        let (i, j) = a < b ? (a, b) : (b, a)
        return i * n - i * (i + 1) / 2 + (j - i - 1)
    }
    func outlets(_ unit: Int) -> Set<String> { Set(members[unit].map { corpus.items[$0].outlet }) }

    init(corpusPath: String, goldPath: String, pairLabelsPath: String) throws {
        corpus = try Corpus(corpusPath)
        let items = corpus.items
        var dup = duplicateGroups(items)
        var rootToUnit: [Int: Int] = [:]
        var units: [Int] = [], members: [[Int]] = []
        var unitOf = [Int](repeating: 0, count: items.count)
        for i in items.indices {
            let root = dup.find(i)
            if let u = rootToUnit[root] { members[u].append(i); unitOf[i] = u }
            else { rootToUnit[root] = units.count; unitOf[i] = units.count; units.append(i); members.append([i]) }
        }
        self.units = units; self.members = members; n = units.count
        let gold = try GoldStandard(path: goldPath)
        let events: [String?] = members.map { m in m.compactMap { gold.event[$0] }.first }
        for (u, m) in members.enumerated() where Set(m.compactMap { gold.event[$0] }).count > 1 { print("warning: unit \(u) spans gold events") }
        let groups: [Set<String>] = members.map { m in m.reduce(into: Set<String>()) { $0.formUnion(gold.groups[$1] ?? []) } }
        // Pair labels, mapped to unit pairs.
        let index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        var pairLabel: [[Int]: String] = [:]
        for p in readPairLabels(pairLabelsPath) {
            guard let a = index[p.a], let b = index[p.b] else { continue }
            let (u, v) = (unitOf[a], unitOf[b])
            if u != v { pairLabel[[min(u, v), max(u, v)]] = p.label }
        }
        var relation = [Relation](repeating: .different, count: n * (n - 1) / 2)
        var signals: [PairSignals] = []
        signals.reserveCapacity(relation.count)
        var inconsistent = 0
        for u in 0..<n { for v in (u + 1)..<n {
            var r: Relation = .different
            if let e = events[u], e == events[v] { r = .same }
            else if pairLabel[[u, v]] == "S" { r = .same; inconsistent += 1
                print("note: labeled S but not in one gold event: \(items[units[u]].title) ‖ \(items[units[v]].title)") }
            else if pairLabel[[u, v]] == "R" || !groups[u].isDisjoint(with: groups[v]) { r = .related }
            relation[u * n - u * (u + 1) / 2 + (v - u - 1)] = r
            signals.append(corpus.signals(units[u], units[v]))
        } }
        self.relation = relation; self.signals = signals; self.gold = gold
        let same = relation.filter { $0 == .same }.count, related = relation.filter { $0 == .related }.count
        print("units: \(n) (from \(items.count) items), gold same-event pairs: \(same), related pairs: \(related), label/gold conflicts: \(inconsistent)")
    }
}

// MARK: - Rules and clustering

struct Rule {
    let name: String
    let score: (PairSignals) -> Double
    let gate: (PairSignals) -> Bool
    let thresholds: [Double]
}

func anchored(_ p: PairSignals) -> Bool { p.countryIDF >= 3.0 || p.nameIDF >= 3.0 || p.gramIDF >= 4.5 }
func hybrid(_ p: PairSignals) -> Double {
    0.5 * p.semantic + p.lexical + (anchored(p) ? 0.3 : 0) - ((p.hours ?? 0) > 48 ? 0.3 : 0)
}
func stride(_ from: Double, _ to: Double, _ by: Double) -> [Double] { Array(Swift.stride(from: from, through: to + 1e-9, by: by)) }

let rules: [Rule] = [
    Rule(name: "lexical only", score: { $0.lexical }, gate: { _ in true }, thresholds: stride(0.15, 0.8, 0.025)),
    Rule(name: "zh contextual only", score: { $0.zh }, gate: { _ in true }, thresholds: stride(0.70, 0.97, 0.01)),
    Rule(name: "semantic (zh ctx | en sentence)", score: { $0.semantic }, gate: { _ in true }, thresholds: stride(0.3, 1.8, 0.05)),
    Rule(name: "semantic + entity anchor", score: { $0.semantic }, gate: anchored, thresholds: stride(0.0, 1.6, 0.05)),
    Rule(name: "hybrid (sem + lex + anchor - age)", score: hybrid, gate: { _ in true }, thresholds: stride(0.3, 1.8, 0.05)),
    Rule(name: "hybrid + anchor required", score: hybrid, gate: anchored, thresholds: stride(0.3, 1.8, 0.05)),
]

enum Method: String { case single = "single-link", average = "average-link", online = "online (time order)" }

func cluster(_ set: EvalSet, _ rule: Rule, _ t: Double, _ method: Method) -> [Int] {
    let n = set.n
    func s(_ a: Int, _ b: Int) -> Double {
        let p = set.signals[set.pairIndex(a, b)]
        return rule.gate(p) ? rule.score(p) : rule.score(p) - 1.0
    }
    switch method {
    case .single:
        var uf = UnionFind(n)
        for u in 0..<n { for v in (u + 1)..<n where s(u, v) >= t { uf.union(u, v) } }
        return (0..<n).map { uf.find($0) }
    case .average:
        var edges: [(Double, Int, Int)] = []
        for u in 0..<n { for v in (u + 1)..<n { let x = s(u, v); if x >= t { edges.append((x, u, v)) } } }
        edges.sort { $0.0 > $1.0 }
        var uf = UnionFind(n)
        var members: [Int: [Int]] = Dictionary(uniqueKeysWithValues: (0..<n).map { ($0, [$0]) })
        for (_, u, v) in edges {
            let a = uf.find(u), b = uf.find(v)
            guard a != b else { continue }
            let ma = members[a]!, mb = members[b]!
            var total = 0.0
            for x in ma { for y in mb { total += s(x, y) } }
            if total / Double(ma.count * mb.count) >= t {
                uf.union(a, b)
                let root = uf.find(a)
                members[root] = ma + mb
                members[root == a ? b : a] = nil
            }
        }
        return (0..<n).map { uf.find($0) }
    case .online:
        let order = (0..<n).sorted { (set.corpus.items[set.units[$0]].date ?? .distantFuture) < (set.corpus.items[set.units[$1]].date ?? .distantFuture) }
        var clusterOf = [Int](repeating: -1, count: n)
        var clusters: [[Int]] = []
        for u in order {
            var best = -1, bestScore = -Double.infinity
            for (c, m) in clusters.enumerated() {
                let avg = m.reduce(0.0) { $0 + s(u, $1) } / Double(m.count)
                if avg > bestScore { bestScore = avg; best = c }
            }
            if best >= 0, bestScore >= t { clusters[best].append(u); clusterOf[u] = best }
            else { clusterOf[u] = clusters.count; clusters.append([u]) }
        }
        return clusterOf
    }
}

struct Score { var tp = 0, related = 0, fp = 0, fn = 0
    var strictP: Double { Double(tp) / Double(max(tp + related + fp, 1)) }
    var tolerantP: Double { Double(tp + related) / Double(max(tp + related + fp, 1)) }
    var recall: Double { Double(tp) / Double(max(tp + fn, 1)) }
    var f1: Double { let p = tolerantP, r = recall; return p + r > 0 ? 2 * p * r / (p + r) : 0 }
}

func score(_ set: EvalSet, _ clusterOf: [Int]) -> Score {
    var result = Score()
    var k = 0
    for u in 0..<set.n { for v in (u + 1)..<set.n {
        let together = clusterOf[u] == clusterOf[v]
        switch set.relation[k] {
        case .same: if together { result.tp += 1 } else { result.fn += 1 }
        case .related: if together { result.related += 1 }
        case .different: if together { result.fp += 1 }
        }
        k += 1
    } }
    return result
}

func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

/// Baselines: single signals and simple combinations, pairwise metrics.
func baseline(corpusPath: String, goldPath: String, pairLabelsPath: String) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    print("\nrule | method | threshold | strict P | tolerant P | recall | F1 | wrong pairs")
    for rule in rules {
        for method in [Method.single, .average, .online] {
            var rows: [(Double, Score)] = []
            for t in rule.thresholds { rows.append((t, score(set, cluster(set, rule, t, method)))) }
            guard let top = rows.max(by: { $0.1.f1 < $1.1.f1 }) else { continue }
            let safe = rows.filter { $0.1.tolerantP >= 0.95 }.max { $0.1.recall < $1.1.recall }
            for (label, row) in [("best F1", top), ("P≥0.95", safe)] {
                guard let row else { print("\(rule.name) | \(method.rawValue) | \(label): none reaches tolerant P 0.95"); continue }
                print("\(rule.name) | \(method.rawValue) | \(label) t=\(fmt(row.0)) | \(fmt(row.1.strictP)) | \(fmt(row.1.tolerantP)) | \(fmt(row.1.recall)) | \(fmt(row.1.f1)) | \(row.1.fp)")
            }
        }
    }
}

// MARK: - Feature diagnostics

func auc(_ pos: [Double], _ neg: [Double]) -> Double {
    guard !pos.isEmpty, !neg.isEmpty else { return .nan }
    let all = (pos.map { ($0, 1) } + neg.map { ($0, 0) }).sorted { $0.0 < $1.0 }
    var rankSum = 0.0, i = 0
    while i < all.count {
        var j = i
        while j + 1 < all.count && all[j + 1].0 == all[i].0 { j += 1 }
        let avgRank = Double(i + j + 2) / 2
        for k in i...j where all[k].1 == 1 { rankSum += avgRank }
        i = j + 1
    }
    let np = Double(pos.count), nn = Double(neg.count)
    return (rankSum - np * (np + 1) / 2) / (np * nn)
}

func percentile(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
}

func diagnose(corpusPath: String, goldPath: String, pairLabelsPath: String) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    let features: [(String, (PairSignals) -> Double?)] = [
        ("zh ctx", { $0.zh }), ("en sentence", { $0.enSent }), ("en ctx", { $0.enCtx }),
        ("lex zh bigram", { $0.lexZh }), ("lex en word", { $0.lexEn }), ("country idf", { $0.countryIDF }),
        ("name idf", { $0.nameIDF }), ("rare bigram idf", { $0.gramIDF }), ("hybrid", { hybrid($0) })]
    for type in ["zh-zh", "zh-en", "en-en"] {
        var pos: [PairSignals] = [], neg: [PairSignals] = []
        var k = 0
        for u in 0..<set.n { for v in (u + 1)..<set.n {
            let a = set.corpus.items[set.units[u]].lang, b = set.corpus.items[set.units[v]].lang
            let t = a == b ? "\(a)-\(b)" : "zh-en"
            if t == type {
                if set.relation[k] == .same { pos.append(set.signals[k]) } else if set.relation[k] == .different { neg.append(set.signals[k]) }
            }
            k += 1
        } }
        print("\n[\(type)] same-event pairs: \(pos.count), different pairs: \(neg.count)")
        print("feature | AUC | same p10/p50/p90 | different p50/p99/p99.9")
        for (name, f) in features {
            let p = pos.compactMap(f), n = neg.compactMap(f)
            guard !p.isEmpty else { continue }
            print("\(name) | \(fmt(auc(p, n))) | \(fmt(percentile(p, 0.1)))/\(fmt(percentile(p, 0.5)))/\(fmt(percentile(p, 0.9))) | \(fmt(percentile(n, 0.5)))/\(fmt(percentile(n, 0.99)))/\(fmt(percentile(n, 0.999)))")
        }
    }
}
