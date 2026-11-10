import AppKit
import GlassRemoteCore

/// One native dialog for unresolved local folder-name collisions.
@MainActor
public enum GlassFolderConflictAlert {
    public static func makeAlert(for conflict: TorrentRenameConflict) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A folder named “\(conflict.name)” already exists"
        alert.informativeText = "The existing folder is at:\n\(conflict.destination)\n\nDelete it to finish renaming your download, or open it in Finder to inspect it. Deleted folders go to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Existing Folder in Finder")
        let delete = alert.addButton(withTitle: "Delete Folder")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        return alert
    }
}
