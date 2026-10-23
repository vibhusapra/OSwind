import Foundation
import CSQLite
import Darwin

public enum StatisticsEvaluation {
    /// Only an explicitly marked synthetic vector archive is accepted. Reports
    /// contain no source text, real application names or local paths.
    public static func run(archive: URL, repetitions: Int = 5) throws -> [String:Any] {
        guard (1...20).contains(repetitions),
              let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:archive.appendingPathComponent("benchmark-fixture.json"))) as? [String:Any],
              marker["kind"] as? String == "OSwind synthetic vectors v1", let expected = marker["count"] as? Int, (100...1_000_000).contains(expected) else { throw OSwindError.invalid("Choose an existing synthetic vector benchmark archive and 1–20 repetitions") }
        let opened = Date(), store = try MemoryStore(root:archive), openSeconds = Date().timeIntervalSince(opened)
        let initial = try store.stats(includeDiskUsage:false)
        guard initial.count == expected, Set(initial.apps.keys).isSubset(of:["Synthetic A","Synthetic B"]) else { throw OSwindError.invalid("Archive no longer matches the synthetic fixture") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(archive.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { sqlite3_close(db); throw OSwindError.database("Cannot open benchmark reference reader") }
        defer { sqlite3_close(db) }
        func legacyScan() throws {
            var counts: OpaquePointer?, apps: OpaquePointer?
            guard sqlite3_prepare_v2(db,"SELECT COUNT(*),SUM(kind='screen'),SUM(kind='audio'),SUM(embedding IS NOT NULL),MIN(timestamp),MAX(timestamp) FROM memories",-1,&counts,nil) == SQLITE_OK else { throw OSwindError.database("Cannot prepare reference statistics") }
            defer { sqlite3_finalize(counts) }
            guard sqlite3_step(counts) == SQLITE_ROW, Int(sqlite3_column_int64(counts,0)) == expected else { throw OSwindError.database("Reference count mismatch") }
            guard sqlite3_prepare_v2(db,"SELECT app,COUNT(*) FROM memories GROUP BY app ORDER BY COUNT(*) DESC",-1,&apps,nil) == SQLITE_OK else { throw OSwindError.database("Cannot prepare reference app counts") }
            defer { sqlite3_finalize(apps) }; var sum = 0, status = sqlite3_step(apps)
            while status == SQLITE_ROW { sum += Int(sqlite3_column_int64(apps,1)); status = sqlite3_step(apps) }
            guard status == SQLITE_DONE, sum == expected else { throw OSwindError.database("Reference application count mismatch") }
        }
        var modes = [String:Any]()
        for mode in ["maintained_sql","legacy_sql_scan","maintained_with_disk"] {
            var times = [Double]()
            for _ in 0..<repetitions {
                try Task.checkCancellation(); let start = DispatchTime.now().uptimeNanoseconds
                if mode == "legacy_sql_scan" { try legacyScan() }
                else { guard try store.stats(includeDiskUsage:mode == "maintained_with_disk").count == expected else { throw OSwindError.database("Maintained count mismatch") } }
                times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
            }
            let latency = try BenchmarkLatency(samples:times)
            modes[mode] = ["milliseconds":times,"p50_ms":latency.median,"p95_ms":latency.p95,"max_ms":latency.maximum]
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return ["schema":2,"latency_quantiles":BenchmarkLatency.method,"timestamp":ISO8601DateFormatter().string(from:Date()),"count":expected,"repetitions":repetitions,"open_including_migration_seconds":openSeconds,"schema_version":6,"build":build,"os":ProcessInfo.processInfo.operatingSystemVersionString,"process_peak_rss_bytes":usage.ru_maxrss,"modes":modes,"scope":"Marked synthetic vector archive, maintained metadata versus the previous aggregate/app SQL scans. File traversal is measured separately. Warm development samples; opening may perform a one-time schema-5 migration. Not controlled cold-cache, media-heavy filesystem, whole-UI, power or competitor measurements. The archive is retained and its derived schema may be upgraded; no sources or native graphs are deleted."]
    }
}
