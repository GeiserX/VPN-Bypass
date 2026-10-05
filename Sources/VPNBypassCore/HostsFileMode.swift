import Foundation

/// Whether the system resolver can read a hosts file.
///
/// mDNSResponder runs as `_mdnsresponder`, which is neither root nor in wheel, so `/etc/hosts`
/// must be world readable or every entry in it is ignored. A file at 0440 looks healthy to
/// root and to the helper that writes it, and the symptom is a name that "is in the file" yet
/// resolves through DNS, or not at all on a VPN.
enum HostsFileMode {
    nonisolated static func isWorldReadable(path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IROTH) != 0
    }

    /// The permission bits as octal text ("0440"), or nil when the file cannot be stat'ed.
    nonisolated static func octalMode(path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return String(format: "%04o", st.st_mode & 0o7777)
    }
}
