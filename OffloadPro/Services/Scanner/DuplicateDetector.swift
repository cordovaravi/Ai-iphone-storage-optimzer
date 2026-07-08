import Foundation

/// Duplicate grouping over indexed rows (§1.2.5). Pure logic — the scanner
/// feeds it records; hashing itself happens in the analysis pipeline.
enum DuplicateDetector {
    /// Pass 1: cheap candidate grouping by (bytes, pixel dims, duration).
    /// Only groups with more than one member proceed to hashing.
    static func candidateGroups(_ records: [AssetRecord]) -> [[AssetRecord]] {
        struct Key: Hashable {
            let bytes: Int64
            let width: Int?
            let height: Int?
            let duration: Int // rounded ms to avoid float identity issues
        }
        var groups: [Key: [AssetRecord]] = [:]
        for record in records {
            let key = Key(
                bytes: record.bytes,
                width: record.width,
                height: record.height,
                duration: Int(((record.duration ?? 0) * 1000).rounded())
            )
            groups[key, default: []].append(record)
        }
        return groups.values.filter { $0.count > 1 }
    }

    /// Pass 2: exact duplicates — identical SHA-256 within a candidate group.
    static func exactDuplicateClusters(_ records: [AssetRecord]) -> [[AssetRecord]] {
        var byHash: [String: [AssetRecord]] = [:]
        for record in records {
            guard let hash = record.sha256 else { continue }
            byHash[hash, default: []].append(record)
        }
        return byHash.values.filter { $0.count > 1 }.map { $0 }
    }

    /// Pass 3: near-duplicate clustering by dHash hamming distance
    /// (photos only). Single-linkage over the threshold graph.
    static func nearDuplicateClusters(_ records: [AssetRecord]) -> [[AssetRecord]] {
        let hashed: [(AssetRecord, UInt64)] = records.compactMap { record in
            guard record.mediaType == AssetClassifier.mediaTypeImage,
                  let data = record.phash, let hash = DHash.hash(from: data) else { return nil }
            return (record, hash)
        }
        guard hashed.count > 1 else { return [] }

        var parent = Array(0..<hashed.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<hashed.count {
            for j in (i + 1)..<hashed.count where DHash.isNearDuplicate(hashed[i].1, hashed[j].1) {
                union(i, j)
            }
        }

        var clusters: [Int: [AssetRecord]] = [:]
        for i in 0..<hashed.count {
            clusters[find(i), default: []].append(hashed[i].0)
        }
        return clusters.values.filter { $0.count > 1 }.map { $0 }
    }

    /// "Keep best" = highest resolution, then newest (§1.2.5).
    static func keepBest(in cluster: [AssetRecord]) -> AssetRecord? {
        cluster.max { a, b in
            let aPixels = (a.width ?? 0) * (a.height ?? 0)
            let bPixels = (b.width ?? 0) * (b.height ?? 0)
            if aPixels != bPixels { return aPixels < bPixels }
            return (a.createdAt ?? 0) < (b.createdAt ?? 0)
        }
    }
}
