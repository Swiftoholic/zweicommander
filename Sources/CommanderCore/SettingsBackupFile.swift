import Foundation
import Darwin

public enum SettingsBackupFile {
    public static func read(_ url:URL,token:CancellationToken = .init(),progress:(Int)->Void = { _ in }) throws -> Data {
        guard url.isFileURL,!url.path.contains("\0") else { throw CommanderError.message("Eine lokale Einstellungsdatei auswählen.") }
        let descriptor = open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard descriptor >= 0 else { throw CommanderError.message("Die Einstellungsdatei ist nicht lesbar oder eine Verknüpfung.") };defer { close(descriptor) }
        let before = try recoveryFDVersion(descriptor)
        guard before.isRegularFile,before.size >= 0,before.size <= SettingsBackupDocument.maximumBytes else { throw CommanderError.message("Die Einstellungsdatei muss eine reguläre Datei bis 48 MiB sein.") }
        let file = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false);var data = Data()
        while true {
            try token.check();let part = try file.read(upToCount:64*1024) ?? Data();if part.isEmpty { break }
            guard part.count <= SettingsBackupDocument.maximumBytes-data.count else { throw CommanderError.message("Die Einstellungsdatei wurde zu groß.") };data.append(part);progress(data.count)
        }
        guard data.count == before.size,try recoveryFDVersion(descriptor) == before,try RenameVersion.read(url) == before else { throw CommanderError.message("Die Einstellungsdatei wurde während des Lesens verändert.") };return data
    }
    /// New files only: existing backups are never silently replaced.
    public static func writeNew(_ data:Data,to url:URL) throws {
        guard url.isFileURL,data.count <= SettingsBackupDocument.maximumBytes else { throw CommanderError.message("Lokales Sicherungsziel und Dateigröße prüfen.") };try FileSystem.validateName(url.lastPathComponent)
        let parent = url.deletingLastPathComponent(),version = try RenameVersion.read(parent)
        guard version.isDirectory else { throw CommanderError.message("Ein echter Zielordner wird benötigt.") }
        let directory = try recoveryParent(url,version);defer { close(directory) }
        let temporary = ".zweicommander-settings-"+UUID().uuidString
        let descriptor = openat(directory,temporary,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw CommanderError.message("Die private Sicherungsdatei konnte nicht angelegt werden.") }
        defer { close(descriptor);_ = unlinkat(directory,temporary,0) }
        let file = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false);try file.write(contentsOf:data)
        guard fsync(descriptor) == 0,try recoveryFDVersion(directory).sameObject(version),try RenameVersion.read(parent).sameObject(version) else { throw CommanderError.message("Der Sicherungsordner wurde verändert oder die Datei konnte nicht gespeichert werden.") }
        guard renameatx_np(directory,temporary,directory,url.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw CommanderError.message("Die Sicherungsdatei existiert bereits oder konnte nicht veröffentlicht werden. Einen neuen Namen wählen.") }
    }
}
