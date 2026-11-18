import AppKit
import Foundation

/// Lean full-auto updater: on launch the app checks GitHub for a newer
/// release; if one exists it downloads the zip, swaps the bundle via a
/// detached helper, and relaunches. Silent — failures NSLog and the app
/// simply keeps running. There is no manual check; relaunching is the check.
enum Updater {
    static let repo = "gbrlpzz/transcribe"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when `candidate` is strictly newer than `current` (x.y.z).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let nums = { (s: String) in s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
        let a = nums(candidate), b = nums(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct Release: Decodable {
        var tagName: String
        var assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", assets
        }
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    /// Set on the relaunch after a swap that did not land, so a bundle that
    /// cannot be replaced is not downloaded and retried in a loop.
    private static let skipFlag = "--no-update"

    /// Check once and auto-install if newer. Silent on failure and when
    /// already current.
    static func checkAndInstall() {
        guard !CommandLine.arguments.contains(skipFlag) else { return }
        latestRelease { version, zip in
            guard isNewer(version, than: currentVersion) else { return }
            guard let zip else {
                // No bundle attached yet: the release page is the update.
                NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases")!)
                return
            }
            performUpdate(zipURL: zip, version: version)
        }
    }

    private static func latestRelease(completion: @escaping (String, String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var version = ""
            var zip: String?
            if let data,
               let release = try? JSONDecoder().decode(Release.self, from: data) {
                version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                zip = release.assets.first(where: { $0.name.hasSuffix(".zip") })?.browserDownloadURL
            }
            DispatchQueue.main.async { completion(version, zip) }
        }.resume()
    }

    private static func performUpdate(zipURL: String, version: String) {
        // Update the bundle that is running, wherever it lives; a bare
        // `swift run` binary has no bundle to replace.
        let dest = Bundle.main.bundleURL
        guard dest.pathExtension == "app" else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-update-\(version)")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: URL(string: zipURL)!) { location, _, error in
            guard let location else { return }  // silent: try again next launch
            do {
                let archive = tmp.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: location, to: archive)
                let staged = tmp.appendingPathComponent("staged")
                try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                arguments: ["-x", "-k", archive.path, staged.path])
                    .waitUntilExit()
                guard let app = findApp(in: staged) else { return }
                // Copy beside the running bundle BEFORE anything is removed: a
                // copy that fails (read-only volume, no permission) leaves the
                // installed app untouched and running.
                let incoming = dest.appendingPathExtension("new")
                try? FileManager.default.removeItem(at: incoming)
                let copy = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                           arguments: [app.path, incoming.path])
                copy.waitUntilExit()
                guard copy.terminationStatus == 0 else {
                    try? FileManager.default.removeItem(at: incoming)
                    NSLog("Transcribe: auto-update could not stage beside %@", dest.path)
                    return
                }
                DispatchQueue.main.async { swapAndRelaunch(dest: dest) }
            } catch {
                NSLog("Transcribe: auto-update failed (\(error.localizedDescription))")
            }
        }
        task.resume()
    }

    private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return entries.first { $0.pathExtension == "app" } ?? entries.compactMap(findApp).first
    }

    /// Detached helper: waits for this process to exit, renames the staged
    /// `<bundle>.new` into place (two renames in one directory — the old
    /// bundle is only deleted once the new one sits at `dest`), and relaunches.
    private static func swapAndRelaunch(dest: URL) {
        // $1 = our pid, $2 = bundle path, $3 = skip flag for a failed swap.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.5; done
        if mv "$2" "$2.old" && mv "$2.new" "$2"; then
            rm -rf "$2.old"
            open "$2"
        else
            [ -d "$2" ] || mv "$2.old" "$2"
            rm -rf "$2.new"
            open "$2" --args "$3"
        fi
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "sh",
                          String(ProcessInfo.processInfo.processIdentifier), dest.path, skipFlag]
        do {
            try proc.run()  // detached: survives our termination
        } catch {
            try? FileManager.default.removeItem(at: dest.appendingPathExtension("new"))
            return
        }
        exit(0)
    }

}
