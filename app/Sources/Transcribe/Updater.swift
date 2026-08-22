import AppKit
import Foundation

/// Minimal release checker/updater for github.com/gbrlpzz/transcribe.
///
/// A release is a Git tag whose assets include a zipped `Transcribe.app`
/// (built by `make dist`). Checking compares the bundle's short version
/// string with the latest tag; updating downloads the zip, swaps the bundle
/// in / Applications, refreshes the engine tool, and relaunches.
enum Updater {
    static let repo = "gbrlpzz/transcribe"

    // MARK: - Version

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

    // MARK: - Check

    /// Fetches the latest published release. Completion yields
    /// `(newestVersion, zipURL)` — `zipURL` nil when the release carries no app zip.
    static func latestRelease(completion: @escaping (String, String?) -> Void) {
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

    static func checkForUpdates() {
        latestRelease { version, zip in
            guard isNewer(version, than: currentVersion) else {
                presentAlert(title: "Up to Date",
                             message: "Transcribe \(currentVersion) is the newest release.")
                return
            }
            guard let zip else {
                // No bundle attached yet: send them to the release page.
                NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases")!)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Update to \(version)?"
            alert.informativeText = "Transcribe \(version) is available (you have \(currentVersion)). The app restarts afterwards."
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                performUpdate(zipURL: zip, version: version)
            }
        }
    }

    // MARK: - Update

    private static func performUpdate(zipURL: String, version: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-update-\(version)")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: URL(string: zipURL)!) { location, _, error in
            guard let location else {
                DispatchQueue.main.async { self.openReleasesPage() }
                return
            }
            do {
                let archive = tmp.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: location, to: archive)
                let staged = tmp.appendingPathComponent("staged")
                try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                arguments: ["-x", "-k", archive.path, staged.path])
                    .waitUntilExit()
                let app = findApp(in: staged)
                guard let app else { throw NSError(domain: "Transcribe", code: 10,
                                                  userInfo: [NSLocalizedDescriptionKey: "no .app in release zip"]) }
                DispatchQueue.main.async { swapAndRelaunch(stagedApp: app, version: version) }
            } catch {
                DispatchQueue.main.async { self.openReleasesPage() }
            }
        }
        task.resume()
    }

    private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return entries.first { $0.pathExtension == "app" }
            ?? entries.compactMap(findAppRecursive).first
    }

    private static func findAppRecursive(dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries where entry.pathExtension == "app" { return entry }
        return entries.compactMap(findAppRecursive).first
    }

    /// Detached helper: waits for this process to exit, swaps the bundle,
    /// refreshes the engine tool from the same tag, relaunches.
    private static func swapAndRelaunch(stagedApp: URL, version: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = "/Applications/Transcribe.app"
        let tag = "v\(version)"
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
        rm -rf '\(dest)'
        ditto '\(stagedApp.path)' '\(dest)'
        if command -v uv >/dev/null 2>&1; then
          uv tool install --force --reinstall --from "git+https://github.com/\(repo).git@\(tag)" transcribe >/dev/null 2>&1 &
        fi
        open '\(dest)'
        """
        let helper = stagedApp.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try? script.write(to: helper, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [helper.path]
        do {
            try proc.run()  // detached: survives our termination
        } catch {}
        exit(0)
    }

    private static func openReleasesPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases")!)
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
