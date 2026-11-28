import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case text, markdown

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        }
    }
}

/// Renders a `TranscriptDocument` as the content and name of an exported file.
public enum TranscriptExport {
    /// The subfolder that holds every exported file, so they can be removed together.
    static let folderName = "TranscriptExports"

    /// The whole file, ending with one newline. Texts are not escaped for Markdown.
    public static func render(_ document: TranscriptDocument, as format: ExportFormat) -> String {
        let blocks: [String]
        switch format {
        case .text:
            let header = ([document.title] + document.metadata).joined(separator: "\n")
            blocks = [header] + document.entries.map { entry in
                ["[\(entry.label)]", entry.original, entry.translation]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            }
        case .markdown:
            let metadata = document.metadata.map { "- \($0)" }.joined(separator: "\n")
            blocks = ["# \(document.title)", metadata] + document.entries.map { entry in
                ["**\(entry.label)**", quoted(entry.original), entry.translation]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// E.g. "会议-20261128-1430.txt", from the record's start time in `timeZone`.
    public static func fileName(for document: TranscriptDocument, as format: ExportFormat,
                                timeZone: TimeZone = .current) -> String {
        let kind = switch document.kind {
        case .meeting: "会议"
        case .conversation: "对话"
        }
        let time = TranscriptTime(document.startedAt, in: timeZone)
        return "\(kind)-\(time.year)\(time.month)\(time.day)-\(time.hour)\(time.minute)"
            + ".\(format.fileExtension)"
    }

    /// Writes the rendered file (UTF-8) as `fileName(for:as:timeZone:)` into a new folder of
    /// its own inside the export folder of `directory`, so files of the same name never
    /// overwrite each other, and returns its URL. The file stays until `removeExportedFiles`.
    public static func writeFile(_ document: TranscriptDocument, as format: ExportFormat,
                                 in directory: URL, timeZone: TimeZone = .current) throws -> URL {
        let folder = exportFolder(in: directory)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: document, as: format, timeZone: timeZone),
                                                isDirectory: false)
        try Data(render(document, as: format).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Removes everything `writeFile` wrote into `directory`: exported files hold record texts,
    /// which must not outlive a deleted record. Never fails; without exports it does nothing.
    public static func removeExportedFiles(in directory: URL) {
        try? FileManager.default.removeItem(at: exportFolder(in: directory))
    }

    private static func exportFolder(in directory: URL) -> URL {
        directory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Every line of `text` as a line of one block quote.
    private static func quoted(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "> \($0)" }.joined(separator: "\n")
    }
}
