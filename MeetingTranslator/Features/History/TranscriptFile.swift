import CoreTransferable
import Foundation
import MeetingCore
import UniformTypeIdentifiers

/// One saved record as a file to share, in one format.
///
/// Nothing is written when this value is made or when the share button is drawn: the file is
/// written (into a new folder of its own under the temporary directory, named
/// `TranscriptExport.fileName`) only when the share sheet asks for it, after the user tapped
/// share. A `FileRepresentation` with that URL keeps the name and its `.txt` / `.md` extension;
/// a `DataRepresentation` with `suggestedFileName` is known to lose the name in share sheets.
/// The system takes a copy of the file (`allowAccessingOriginalFile: false`), and the temporary
/// directory is the system's to clear.
struct TranscriptFile: Transferable, Sendable {
    let document: TranscriptDocument
    let format: ExportFormat

    var fileName: String { TranscriptExport.fileName(for: document, as: format) }

    /// Markdown by its extension, conforming to plain text, so apps that take text take it.
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            SentTransferredFile(try file.write(), allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.format == .text }
        FileRepresentation(exportedContentType: markdownType) { file in
            SentTransferredFile(try file.write(), allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.format == .markdown }
    }

    private func write() throws -> URL {
        try TranscriptExport.writeFile(document, as: format,
                                       in: FileManager.default.temporaryDirectory)
    }
}
