import Ergon
import FoundationModels
import Foundation

/// Errors specific to the notes tools.
enum NotesToolError: Error, LocalizedError {
    case invalidName(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "'\(name)' is not a valid note name."
        case .notFound(let name):
            return "No note named '\(name)'."
        }
    }
}

enum NotesStore {
    /// Sandbox notes directory, created on first access.
    static func directory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("ErgonNotes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Keeps only alphanumerics, space, dash, underscore, so the result can
    /// never escape the notes directory. Disallowed characters are dropped
    /// rather than substituted: replacing them turned "tomorrow's trip" into
    /// "tomorrow_s trip" on screen for no safety gain.
    static func sanitize(_ name: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw NotesToolError.invalidName(name) }
        return trimmed
    }

    /// Where a note's previous text waits so an overwrite can be undone.
    /// Hidden, so it never shows up in the notes list or in Files.
    static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".prev")
    }

    static func fileURL(for name: String) throws -> URL {
        let safe = try sanitize(name)
        return try directory().appendingPathComponent(safe + ".txt")
    }
}

/// Every note Ergon has saved, name and text, sorted by name. Hosts need this
/// to show the notes anywhere other than by asking the model for them: a note
/// the user cannot find is a note they do not believe was written.
public func savedNotes() -> [(name: String, text: String)] {
    guard let directory = try? NotesStore.directory(),
          let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        return []
    }
    return files.filter { $0.hasSuffix(".txt") }.sorted().map { file in
        let name = String(file.dropLast(4))
        let text = (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return (name, text)
    }
}

/// Lists the user's saved notes. Read-only: runs during generation.
public struct ListNotesTool: ReadTool {
    @Generable
    public struct Arguments {}

    public let name = "listNotes"
    public let description = "List the names of the notes saved inside Ergon. These are Ergon's own notes, not the Apple Notes app."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        do {
            let dir = try NotesStore.directory()
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let names = files.filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) }
            guard !names.isEmpty else { return "No notes saved yet." }
            return "Notes: " + names.joined(separator: ", ")
        } catch {
            return "Could not list notes: \(error.localizedDescription)"
        }
    }
}

/// Reads one saved note by name. Read-only: runs during generation.
public struct ReadNoteTool: ReadTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Name of the note to read, without the .txt extension")
        var name: String
    }

    public let name = "readNote"
    public let description = "Read one of Ergon's own saved notes by name. Cannot read the Apple Notes app."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        do {
            let url = try NotesStore.fileURL(for: arguments.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "Note '\(arguments.name)' not found."
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            return text
        } catch {
            return "Could not read note '\(arguments.name)': \(error.localizedDescription)"
        }
    }
}

/// Creates or overwrites a saved note. Consequential: never runs without
/// approval; overwriting an existing note is reversible only in the sense
/// that the user can write it back, so it is still marked reversible since
/// no data outside the sandbox is touched and the old text was disposable.
public struct WriteNoteTool: ReversibleTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Name for the note, without the .txt extension")
        var name: String
        @Guide(description: "Full text content to save in the note")
        var text: String
    }

    public let name = "writeNote"
    public let description = "Create or overwrite a note inside Ergon with the given text. This does not write to the Apple Notes app."

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Write note in Ergon", detail: arguments.name)
    }

    // Contract: throwing means no file was written or changed. The previous
    // text is kept aside first, because overwriting a note is only reversible
    // if the old text still exists somewhere.
    public func call(arguments: Arguments) async throws -> String {
        let url = try NotesStore.fileURL(for: arguments.name)
        let backup = NotesStore.backupURL(for: url)
        try? FileManager.default.removeItem(at: backup)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try arguments.text.write(to: url, atomically: true, encoding: .utf8)
        return "Saved note '\(arguments.name)'."
    }

    public func undo(_ arguments: Arguments) async throws -> String {
        let url = try NotesStore.fileURL(for: arguments.name)
        let backup = NotesStore.backupURL(for: url)
        if FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            return "Restored the previous text of '\(arguments.name)'."
        }
        try FileManager.default.removeItem(at: url)
        return "Removed note '\(arguments.name)'."
    }
}

/// Deletes a saved note. Consequential and NOT reversible.
public struct DeleteNoteTool: ConsequentialTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Name of the note to delete, without the .txt extension")
        var name: String
    }

    public let name = "deleteNote"
    public let description = "Permanently delete one of Ergon's own saved notes by name."
    public let isReversible = false

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Delete note in Ergon", detail: arguments.name)
    }

    // Contract: throwing means no file was deleted. Throws if the note is
    // missing so a deletion is never falsely reported as having happened.
    public func call(arguments: Arguments) async throws -> String {
        let url = try NotesStore.fileURL(for: arguments.name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NotesToolError.notFound(arguments.name)
        }
        try FileManager.default.removeItem(at: url)
        return "Deleted note '\(arguments.name)'."
    }
}
