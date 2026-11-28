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

    /// Every line of `text` as a line of one block quote.
    private static func quoted(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "> \($0)" }.joined(separator: "\n")
    }
}
