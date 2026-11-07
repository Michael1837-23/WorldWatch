import Foundation

// Second evaluation pass: per-language-pair normalization, a cross-validated linear model,
// and B-cubed metrics (less dominated by the few very large events than pairwise counts).

/// The predicted story holding most of an event's units; ties go to more outlets, then the lower id (deterministic).
func mainCluster(_ set: EvalSet, _ units: [Int], _ clusterOf: [Int]) -> (key: Int, value: [Int]) {
    let groups = Dictionary(grouping: units, by: { clusterOf[$0] })
    func outletCount(_ m: [Int]) -> Int { m.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }.count }
    let best = groups.sorted { a, b in
        if a.value.count != b.value.count { return a.value.count > b.value.count }
        let oa = outletCount(a.value), ob = outletCount(b.value)
        return oa != ob ? oa > ob : a.key < b.key
    }.first!
    return (best.key, best.value)
}

enum PairType: Int { case zhzh = 0, zhen = 1, enen = 2 }

func pairType(_ set: EvalSet, _ u: Int, _ v: Int) -> PairType {
    let a = set.corpus.items[set.units[u]].lang, b = set.corpus.items[set.units[v]].lang
    if a != b { return .zhen }
    return a == "zh" ? .zhzh : .enen
}

/// Hand rule: lexical overlap scaled by the typical same-event value for the language pair,
/// plus a bonus for a rare shared entity and a penalty for stories more than 48 hours apart.
func typedLexical(_ p: PairSignals, _ type: PairType) -> Double {
    let lex: Double
    switch type {
    case .enen: lex = max((p.lexEn ?? 0) / 0.26, p.lexZh / 0.16)
    case .zhen: lex = p.lexZh / 0.07
    case .zhzh: lex = p.lexZh / 0.13
    }
    let rare = p.gramIDF >= 4.5 || p.countryIDF >= 3.5 || p.nameIDF >= 3.5
    return lex + (rare ? 0.3 : 0) - ((p.hours ?? 0) > 48 ? 0.4 : 0)
}

func featureVector(_ p: PairSignals, _ type: PairType) -> [Double] {
    let t = [type == .zhzh, type == .zhen, type == .enen].map { $0 ? 1.0 : 0.0 }
    let enen = t[2]
    return [1, t[0], t[1],
            p.lexZh * t[0] * 5, p.lexZh * t[1] * 10, p.lexZh * enen * 5,
            (p.lexEn ?? 0) * 4,
            (p.zh - 0.7) * 5 * t[0], (p.zh - 0.7) * 5 * t[1], (p.zh - 0.7) * 5 * enen,
            ((p.enCtx ?? 0.9) - 0.9) * 10 * enen, ((p.enSent ?? 0.3) - 0.3) * 3 * enen,
            p.gramIDF / 6, p.countryIDF / 5, p.nameIDF / 5,
            (p.hours ?? 0) > 48 ? 1 : 0]
}

func trainLogistic(_ xs: [[Double]], _ ys: [Double], epochs: Int = 400, lr: Double = 0.5, l2: Double = 1e-3) -> [Double] {
    let d = xs[0].count
    var w = [Double](repeating: 0, count: d)
    let pos = ys.filter { $0 > 0.5 }.count, neg = ys.count - pos
    let posWeight = min(Double(neg) / Double(max(pos, 1)), 50)
    for _ in 0..<epochs {
        var grad = [Double](repeating: 0, count: d)
        var totalWeight = 0.0
        for (x, y) in zip(xs, ys) {
            var z = 0.0
            for i in 0..<d { z += w[i] * x[i] }
            let p = 1 / (1 + exp(-z))
            let weight = y > 0.5 ? posWeight : 1
            totalWeight += weight
            for i in 0..<d { grad[i] += weight * (p - y) * x[i] }
        }
        for i in 0..<d { w[i] -= lr * (grad[i] / totalWeight + l2 * w[i]) }
    }
    return w
}

func dotw(_ w: [Double], _ x: [Double]) -> Double { zip(w, x).reduce(0) { $0 + $1.0 * $1.1 } }

func clusterWith(_ set: EvalSet, _ s: (Int) -> Double, _ t: Double, _ method: Method) -> [Int] {
    let n = set.n
    func pair(_ a: Int, _ b: Int) -> Double { s(set.pairIndex(a, b)) }
    switch method {
    case .single:
        var uf = UnionFind(n)
        for u in 0..<n { for v in (u + 1)..<n where pair(u, v) >= t { uf.union(u, v) } }
        return (0..<n).map { uf.find($0) }
    case .average:
        var edges: [(Double, Int, Int)] = []
        for u in 0..<n { for v in (u + 1)..<n { let x = pair(u, v); if x >= t { edges.append((x, u, v)) } } }
        edges.sort { $0.0 > $1.0 }
        var uf = UnionFind(n)
        var members: [Int: [Int]] = Dictionary(uniqueKeysWithValues: (0..<n).map { ($0, [$0]) })
        for (_, u, v) in edges {
            let a = uf.find(u), b = uf.find(v)
            guard a != b, let ma = members[a], let mb = members[b] else { continue }
            var total = 0.0
            for x in ma { for y in mb { total += pair(x, y) } }
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
                let avg = m.reduce(0.0) { $0 + pair(u, $1) } / Double(m.count)
                if avg > bestScore { bestScore = avg; best = c }
            }
            if best >= 0, bestScore >= t { clusters[best].append(u); clusterOf[u] = best }
            else { clusterOf[u] = clusters.count; clusters.append([u]) }
        }
        return clusterOf
    }
}

/// B-cubed over units that belong to a gold event or to a predicted cluster of size > 1.
struct BCubed { var precision = 0.0, recall = 0.0
    var f1: Double { precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0 } }

func bcubed(_ set: EvalSet, _ clusterOf: [Int]) -> BCubed {
    var byCluster: [Int: [Int]] = [:]
    for u in 0..<set.n { byCluster[clusterOf[u], default: []].append(u) }
    var pSum = 0.0, pCount = 0.0, rSum = 0.0, rCount = 0.0
    for u in 0..<set.n {
        let mates = byCluster[clusterOf[u]]!.filter { $0 != u }
        if !mates.isEmpty {
            let ok = mates.filter { set.relation[set.pairIndex(u, $0)] != .different }.count
            pSum += Double(ok) / Double(mates.count); pCount += 1
        }
        let eventMates = (0..<set.n).filter { $0 != u && set.relation[set.pairIndex(u, $0)] == .same }
        if !eventMates.isEmpty {
            let found = eventMates.filter { clusterOf[$0] == clusterOf[u] }.count
            rSum += Double(found) / Double(eventMates.count); rCount += 1
        }
    }
    return BCubed(precision: pCount > 0 ? pSum / pCount : 1, recall: rCount > 0 ? rSum / rCount : 0)
}

func compare(corpusPath: String, goldPath: String, pairLabelsPath: String, detail: String?) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    var types: [PairType] = []
    types.reserveCapacity(set.signals.count)
    for u in 0..<set.n { for v in (u + 1)..<set.n { types.append(pairType(set, u, v)) } }

    // Two folds split by gold event (non-event units by index), so no event is in both train and test.
    var fold = [Int](repeating: 0, count: set.n)
    let gold = set.gold
    let eventNames = Array(Set(gold.event.values)).sorted()
    let eventFold = Dictionary(uniqueKeysWithValues: eventNames.enumerated().map { ($1, $0 % 2) })
    for u in 0..<set.n {
        if let e = set.members[u].compactMap({ gold.event[$0] }).first { fold[u] = eventFold[e]! } else { fold[u] = u % 2 }
    }
    var trainX: [[[Double]]] = [[], []], trainY: [[Double]] = [[], []]
    var k = 0
    for u in 0..<set.n { for v in (u + 1)..<set.n {
        if fold[u] == fold[v], set.relation[k] != .related {
            trainX[fold[u]].append(featureVector(set.signals[k], types[k]))
            trainY[fold[u]].append(set.relation[k] == .same ? 1 : 0)
        }
        k += 1
    } }
    let w0 = trainLogistic(trainX[0], trainY[0]), w1 = trainLogistic(trainX[1], trainY[1])
    let wAll = trainLogistic(trainX[0] + trainX[1], trainY[0] + trainY[1])
    print("learned weights (all data): \(wAll.map { String(format: "%.2f", $0) }.joined(separator: " "))")
    var learned = [Double](repeating: 0, count: set.signals.count)
    k = 0
    for u in 0..<set.n { for v in (u + 1)..<set.n {
        let x = featureVector(set.signals[k], types[k])
        // Out-of-fold score: a pair inside fold 0 is scored by the model trained on fold 1, and vice versa.
        learned[k] = fold[u] == fold[v] ? dotw(fold[u] == 0 ? w1 : w0, x) : (dotw(w0, x) + dotw(w1, x)) / 2
        k += 1
    } }
    let typed = (0..<set.signals.count).map { typedLexical(set.signals[$0], types[$0]) }
    let hybridScores = set.signals.map(hybrid)
    let lexical = set.signals.map(\.lexical)

    func anchorA(_ p: PairSignals) -> Bool { p.countryIDF >= 2.0 || p.nameIDF >= 2.5 }
    func anchorB(_ p: PairSignals) -> Bool { anchorA(p) || p.gramIDF >= 4.5 }
    let lexAnchorA = set.signals.map { anchorA($0) ? $0.lexical : $0.lexical - 1 }
    let lexAnchorB = set.signals.map { anchorB($0) ? $0.lexical : $0.lexical - 1 }
    let lexAnchorBonus = set.signals.map { $0.lexical + (anchorA($0) ? 0.08 : 0) - (($0.hours ?? 0) > 48 ? 0.08 : 0) }
    let candidates: [(String, [Double], [Double])] = [
        ("lexical only", lexical, stride(0.15, 0.6, 0.025)),
        ("lexical + entity anchor (country/name)", lexAnchorA, stride(0.1, 0.6, 0.025)),
        ("lexical + anchor (country/name/rare word)", lexAnchorB, stride(0.1, 0.6, 0.025)),
        ("lexical + anchor bonus - age", lexAnchorBonus, stride(0.15, 0.7, 0.025)),
        ("hybrid v1", hybridScores, stride(0.6, 1.6, 0.05)),
        ("typed lexical + rare entity", typed, stride(0.6, 3.0, 0.1)),
        ("learned linear (out-of-fold)", learned, stride(-2, 6, 0.25)),
    ]
    print("\nrule | method | threshold | pair strict P | pair tolerant P | pair R | B³ P | B³ R | B³ F1 | wrong pairs")
    for (name, scores, thresholds) in candidates {
        for method in [Method.single, .average, .online] {
            var rows: [(Double, Score, BCubed)] = []
            for t in thresholds {
                let c = clusterWith(set, { scores[$0] }, t, method)
                rows.append((t, score(set, c), bcubed(set, c)))
            }
            let top = rows.max { $0.2.f1 < $1.2.f1 }!
            let safe = rows.filter { $0.2.precision >= 0.97 }.max { $0.2.recall < $1.2.recall }
            for (label, row) in [("best B³F1", top), ("B³P≥0.97", safe)] {
                guard let row else { print("\(name) | \(method.rawValue) | \(label): none"); continue }
                print("\(name) | \(method.rawValue) | \(label) t=\(fmt(row.0)) | \(fmt(row.1.strictP)) | \(fmt(row.1.tolerantP)) | \(fmt(row.1.recall)) | \(fmt(row.2.precision)) | \(fmt(row.2.recall)) | \(fmt(row.2.f1)) | \(row.1.fp)")
            }
        }
    }
    if let detail {
        let parts = detail.split(separator: ":").map(String.init)   // "<candidate index>:<single|average|online>:<threshold>"
        let (name, scores, _) = candidates[Int(parts[0])!]
        let method: Method = parts[1] == "single" ? .single : parts[1] == "average" ? .average : .online
        reportWith(set, name, { scores[$0] }, Double(parts[2])!, method)
    }
}

func reportWith(_ set: EvalSet, _ name: String, _ s: (Int) -> Double, _ t: Double, _ method: Method) {
    let clusterOf = clusterWith(set, s, t, method)
    let items = set.corpus.items
    print("\n==== Detail: \(name), \(method.rawValue), t=\(fmt(t))")
    var byCluster: [Int: [Int]] = [:]
    for u in 0..<set.n { byCluster[clusterOf[u], default: []].append(u) }
    var impure = 0
    for (_, members) in byCluster.sorted(by: { $0.value.count > $1.value.count }) where members.count > 1 {
        var badPairs: [(Int, Int)] = []
        for a in members { for b in members where a < b && set.relation[set.pairIndex(a, b)] == .different { badPairs.append((a, b)) } }
        guard !badPairs.isEmpty else { continue }
        impure += 1
        print("\n  ✗ wrong merge in a \(members.count)-unit cluster, e.g.:")
        for (a, b) in badPairs.prefix(2) {
            print("     \(items[set.units[a]].source): \(items[set.units[a]].title)\n       ↔ \(items[set.units[b]].source): \(items[set.units[b]].title)")
        }
    }
    let multi = byCluster.values.filter { $0.count > 1 }
    print("\n  predicted clusters with >1 unit: \(multi.count), with a wrong merge: \(impure)")
    let gold = set.gold
    var events: [String: [Int]] = [:]
    for u in 0..<set.n { if let e = set.members[u].compactMap({ gold.event[$0] }).first { events[e, default: []].append(u) } }
    print("\n  gold event | units | outlets | units in best cluster | outlets found | intruders")
    for (event, eventUnits) in events.sorted(by: { $0.value.count > $1.value.count }) where eventUnits.count >= 2 {
        let (bestCluster, inBest) = mainCluster(set, eventUnits, clusterOf)
        let outlets = eventUnits.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
        let found = inBest.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
        let intruders = byCluster[bestCluster]!.filter { u in !eventUnits.contains(u) && eventUnits.contains { set.relation[set.pairIndex($0, u)] == .different } }
        print("  \(event) | \(eventUnits.count) | \(outlets.count) | \(inBest.count) | \(found.count) | \(intruders.count)")
    }
}

/// Pool adjudication: direct links that strong rules make but the gold calls "different".
func adjudicate(corpusPath: String, goldPath: String, pairLabelsPath: String) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    var flagged: [Int: Double] = [:]
    let lexical = set.signals.map(\.lexical), hy = set.signals.map(hybrid)
    for (scores, t) in [(lexical, 0.22), (hy, 0.95)] {
        for k in 0..<set.signals.count where scores[k] >= t && set.relation[k] == .different { flagged[k] = max(flagged[k] ?? 0, scores[k]) }
    }
    var pairs: [(Int, Int, Int)] = []
    for u in 0..<set.n { for v in (u + 1)..<set.n { let k = set.pairIndex(u, v); if flagged[k] != nil { pairs.append((k, u, v)) } } }
    pairs.sort { set.signals[$0.0].lexical > set.signals[$1.0].lexical }
    print("flagged pairs: \(pairs.count)")
    for (n, (_, u, v)) in pairs.enumerated() {
        let a = set.corpus.items[set.units[u]], b = set.corpus.items[set.units[v]]
        print(String(format: "A%03d", n + 1) + " | \(set.units[u]) \(a.source): \(a.title) ‖ \(set.units[v]) \(b.source): \(b.title)")
    }
}

/// Grid search: separate thresholds per language pair; cross-language links also need a shared entity.
func grid(corpusPath: String, goldPath: String, pairLabelsPath: String) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    var types: [PairType] = []
    for u in 0..<set.n { for v in (u + 1)..<set.n { types.append(pairType(set, u, v)) } }
    func anchorA(_ p: PairSignals) -> Bool { p.countryIDF >= 2.0 || p.nameIDF >= 2.5 }
    var results: [(Double, Double, Double, String, BCubed, Score, [Int])] = []
    for tEn in stride(0.30, 0.46, 0.04) { for tZz in stride(0.22, 0.46, 0.06) { for tZe in stride(0.06, 0.18, 0.02) { for age in [false, true] {
        let linkScore: (Int) -> Double = { k in
            let p = set.signals[k]
            let old = age && (p.hours ?? 0) > 48
            switch types[k] {
            case .enen: return p.lexical - tEn - (old ? 0.08 : 0)
            case .zhzh: return p.lexZh - tZz - (old ? 0.08 : 0)
            case .zhen: return anchorA(p) ? p.lexZh - tZe - (old ? 0.04 : 0) : -1
            }
        }
        let c = clusterWith(set, linkScore, 0, .single)
        results.append((tEn, tZz, tZe, age ? "age" : "-", bcubed(set, c), score(set, c), c))
    } } } }
    let safe = results.filter { $0.4.precision >= 0.97 }.sorted { $0.4.f1 > $1.4.f1 }
    print("top configs with B³ precision ≥ 0.97 (single-link):")
    print("en-en | zh-zh | zh-en(+anchor) | age | B³ P | B³ R | B³ F1 | pair tol P | pair R | wrong pairs")
    for r in safe.prefix(8) {
        print("\(fmt(r.0)) | \(fmt(r.1)) | \(fmt(r.2)) | \(r.3) | \(fmt(r.4.precision)) | \(fmt(r.4.recall)) | \(fmt(r.4.f1)) | \(fmt(r.5.tolerantP)) | \(fmt(r.5.recall)) | \(r.5.fp)")
    }
    let best = results.sorted { $0.4.f1 > $1.4.f1 }.first!
    print("best overall: en \(fmt(best.0)) zz \(fmt(best.1)) ze \(fmt(best.2)) \(best.3) → B³ P \(fmt(best.4.precision)) R \(fmt(best.4.recall)) F1 \(fmt(best.4.f1)), wrong pairs \(best.5.fp)")
    if let top = safe.first {
        // Which gold-event members does the chosen config still miss? (cross-language recall check)
        let gold = set.gold
        var events: [String: [Int]] = [:]
        for u in 0..<set.n { if let e = set.members[u].compactMap({ gold.event[$0] }).first { events[e, default: []].append(u) } }
        print("\nmissed members of the 8 largest events at en \(fmt(top.0)) zz \(fmt(top.1)) ze \(fmt(top.2)) \(top.3):")
        for (event, units) in events.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
            let main = mainCluster(set, units, top.6).key
            let missed = units.filter { top.6[$0] != main }
            let zhMissed = missed.filter { set.corpus.items[set.units[$0]].lang == "zh" }.count
            let zhTotal = units.filter { set.corpus.items[set.units[$0]].lang == "zh" }.count
            print("  \(event): main cluster \(units.count - missed.count)/\(units.count), Chinese-language in main \(zhTotal - zhMissed)/\(zhTotal)")
            for u in missed.prefix(4) { print("     missed: \(set.corpus.items[set.units[u]].source): \(set.corpus.items[set.units[u]].title)") }
        }
    }
}

// MARK: - Single-pass clustering against a story centroid (TF-IDF over Chinese bigrams + English words)

func unitVector(_ set: EvalSet, _ u: Int) -> [String: Double] {
    let f = set.corpus.features[set.units[u]]
    var v: [String: Double] = [:]
    for g in f.zhGrams { v["z" + g] = set.corpus.gramIDF[g] ?? 0 }
    for w in f.enWords { v["e" + w] = set.corpus.wordIDF[w] ?? 0 }
    let norm = sqrt(v.keys.sorted().reduce(0) { $0 + v[$1]! * v[$1]! })
    return norm > 0 ? v.mapValues { $0 / norm } : v
}

func centroidOnline(_ set: EvalSet, threshold t: Double, anchorBonus: Double, agePenalty: Double) -> [Int] {
    struct Story { var centroid: [String: Double] = [:]; var countries = Set<String>(); var names = Set<String>(); var last = Date.distantPast }
    let order = (0..<set.n).sorted { (set.corpus.items[set.units[$0]].date ?? .distantFuture) < (set.corpus.items[set.units[$1]].date ?? .distantFuture) }
    var stories: [Story] = []
    var clusterOf = [Int](repeating: -1, count: set.n)
    for u in order {
        let v = unitVector(set, u)
        let f = set.corpus.features[set.units[u]]
        let date = set.corpus.items[set.units[u]].date ?? Date()
        let rareCountries = f.countries.filter { (set.corpus.countryIDF[$0] ?? 0) >= 2.0 }
        let rareNames = f.names.filter { (set.corpus.nameIDF[$0] ?? 0) >= 2.5 }
        var best = -1, bestScore = -Double.infinity
        for (c, s) in stories.enumerated() {
            let norm = sqrt(s.centroid.keys.sorted().reduce(0) { $0 + s.centroid[$1]! * s.centroid[$1]! })
            guard norm > 0 else { continue }
            var dot = 0.0
            for k in v.keys.sorted() { if let y = s.centroid[k] { dot += v[k]! * y } }
            var score = dot / norm
            if !rareCountries.isDisjoint(with: s.countries) || !rareNames.isDisjoint(with: s.names) { score += anchorBonus }
            if date.timeIntervalSince(s.last) > 36 * 3600 { score -= agePenalty }
            if score > bestScore { bestScore = score; best = c }
        }
        if best >= 0, bestScore >= t {
            for (k, x) in v { stories[best].centroid[k, default: 0] += x }
            stories[best].countries.formUnion(rareCountries); stories[best].names.formUnion(rareNames)
            stories[best].last = max(stories[best].last, date)
            clusterOf[u] = best
        } else {
            stories.append(Story(centroid: v, countries: rareCountries, names: rareNames, last: date))
            clusterOf[u] = stories.count - 1
        }
    }
    return clusterOf
}

func centroidEval(corpusPath: String, goldPath: String, pairLabelsPath: String, detail: Double?) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    print("centroid single-pass | threshold | anchor bonus | age penalty | pair tol P | pair R | B³ P | B³ R | B³ F1 | wrong pairs")
    var rows: [(Double, Double, Double, Score, BCubed)] = []
    for t in stride(0.20, 0.60, 0.025) { for bonus in [0.0, 0.05, 0.1] { for age in [0.0, 0.1] {
        let c = centroidOnline(set, threshold: t, anchorBonus: bonus, agePenalty: age)
        rows.append((t, bonus, age, score(set, c), bcubed(set, c)))
    } } }
    let best = rows.max { $0.4.f1 < $1.4.f1 }!
    let safe = rows.filter { $0.4.precision >= 0.97 }.sorted { $0.4.recall > $1.4.recall }.prefix(3)
    for r in [best] + safe {
        print("  | \(fmt(r.0)) | \(fmt(r.1)) | \(fmt(r.2)) | \(fmt(r.3.tolerantP)) | \(fmt(r.3.recall)) | \(fmt(r.4.precision)) | \(fmt(r.4.recall)) | \(fmt(r.4.f1)) | \(r.3.fp)")
    }
    if let t = detail {
        let c = centroidOnline(set, threshold: t, anchorBonus: 0.1, agePenalty: 0.1)
        let gold = set.gold
        var events: [String: [Int]] = [:]
        for u in 0..<set.n { if let e = set.members[u].compactMap({ gold.event[$0] }).first { events[e, default: []].append(u) } }
        var byCluster: [Int: [Int]] = [:]
        for u in 0..<set.n { byCluster[c[u], default: []].append(u) }
        print("\n  t=\(fmt(t)) bonus 0.10 age 0.10 | gold event | units | outlets | units in main | outlets found | Chinese-language in main | intruders")
        for (event, units) in events.sorted(by: { $0.value.count > $1.value.count }).prefix(14) {
            let main = mainCluster(set, units, c)
            let outlets = units.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
            let found = main.value.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
            let zhTotal = units.filter { set.corpus.items[set.units[$0]].lang == "zh" }.count
            let zhIn = main.value.filter { set.corpus.items[set.units[$0]].lang == "zh" }.count
            let intruders = byCluster[main.key]!.filter { u in !units.contains(u) && units.contains { set.relation[set.pairIndex($0, u)] == .different } }.count
            print("  | \(event) | \(units.count) | \(outlets.count) | \(main.value.count) | \(found.count) | \(zhIn)/\(zhTotal) | \(intruders)")
        }
        var impure = 0
        for (_, m) in byCluster where m.count > 1 {
            var bad: (Int, Int)? = nil
            for a in m { for b in m where a < b && set.relation[set.pairIndex(a, b)] == .different { bad = (a, b) } }
            if let (a, b) = bad { impure += 1; print("  ✗ \(set.corpus.items[set.units[a]].title) ↔ \(set.corpus.items[set.units[b]].title)") }
        }
        print("  clusters with a wrong merge: \(impure) of \(byCluster.values.filter { $0.count > 1 }.count)")
    }
}

/// Product view: what a "🔥 N outlets" badge would show. Only distinct outlets count, so a junk merge
/// inside one outlet does not inflate heat; a story is "hot" with ≥3 outlets.
func hotness(corpusPath: String, goldPath: String, pairLabelsPath: String, detail: Double? = nil) throws {
    let set = try EvalSet(corpusPath: corpusPath, goldPath: goldPath, pairLabelsPath: pairLabelsPath)
    let gold = set.gold
    var events: [String: [Int]] = [:]
    for u in 0..<set.n { if let e = set.members[u].compactMap({ gold.event[$0] }).first { events[e, default: []].append(u) } }
    let bigEvents = events.filter { $0.value.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }.count >= 3 }
    func summarize(_ name: String, _ c: [Int]) {
        var byCluster: [Int: [Int]] = [:]
        for u in 0..<set.n { byCluster[c[u], default: []].append(u) }
        var multi = 0, multiImpure = 0, hot = 0, hotImpure = 0, inflated = 0
        for (_, m) in byCluster where m.count > 1 {
            let outlets = m.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
            guard outlets.count >= 2 else { continue }
            // Outlets that only belong through a wrong merge inflate the count.
            var bad = false
            for a in m { for b in m where a < b && set.relation[set.pairIndex(a, b)] == .different { bad = true } }
            multi += 1; if bad { multiImpure += 1 }
            if bad, name.hasSuffix("t=\(fmt(detail ?? -1))") {
                print("  ✗ \(outlets.sorted().joined(separator: ",")):")
                for u in m { print("      \(set.corpus.items[set.units[u]].source): \(set.corpus.items[set.units[u]].title)") }
            }
            if outlets.count >= 3 { hot += 1; if bad { hotImpure += 1 } }
            if bad {
                // Largest consistent core: the biggest group of units that are all mutually not "different".
                let core = m.max { a, b in m.filter { set.relation[set.pairIndex(a, $0)] != .different || $0 == a }.count < m.filter { set.relation[set.pairIndex(b, $0)] != .different || $0 == b }.count }!
                let coreUnits = m.filter { $0 == core || set.relation[set.pairIndex(core, $0)] != .different }
                let coreOutlets = coreUnits.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
                if outlets.count > coreOutlets.count { inflated += 1 }
            }
        }
        var outletRecall = 0.0
        for (_, units) in bigEvents {
            let main = mainCluster(set, units, c).value
            let all = units.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
            let found = main.reduce(into: Set<String>()) { $0.formUnion(set.outlets($1)) }
            outletRecall += Double(found.count) / Double(all.count)
        }
        print("\(name) | stories \(byCluster.count) from \(set.n) headlines | multi-outlet stories \(multi) (\(multiImpure) contain a wrong merge, \(inflated) with an inflated outlet count) | hot ≥3 outlets \(hot) (\(hotImpure) impure) | outlet recall of \(bigEvents.count) big events \(fmt(outletRecall / Double(bigEvents.count)))")
    }
    for t in [0.22, 0.25, 0.28, 0.30] { summarize("centroid t=\(fmt(t))", centroidOnline(set, threshold: t, anchorBonus: 0.1, agePenalty: 0.1)) }
    let bonus = set.signals.map { $0.lexical + (($0.countryIDF >= 2.0 || $0.nameIDF >= 2.5) ? 0.08 : 0) - (($0.hours ?? 0) > 48 ? 0.08 : 0) }
    for t in [0.33, 0.38, 0.42] { summarize("pairwise single-link t=\(fmt(t))", clusterWith(set, { bonus[$0] }, t, .single)) }
    summarize("pairwise average-link t=0.25", clusterWith(set, { bonus[$0] }, 0.25, .average))
}
