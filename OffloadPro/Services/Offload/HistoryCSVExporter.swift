import Foundation

/// F2.7 transfer-history CSV export — pure so it is unit-testable without UI.
enum HistoryCSVExporter {
    static let header = "local_id,filename,bytes,sha256,destination_id,dest_path,completed_at"

    static func csv(from rows: [TransferHistoryRecord], dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()) -> String {
        var csv = header + "\n"
        for row in rows {
            let fields = [
                row.localId ?? "",
                row.filename ?? "",
                row.bytes.map(String.init) ?? "",
                row.sha256 ?? "",
                row.destinationId ?? "",
                row.destPath ?? "",
                dateFormatter.string(from: Date(timeIntervalSince1970: row.completedAt)),
            ]
            csv += fields.map(escape).joined(separator: ",") + "\n"
        }
        return csv
    }

    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
