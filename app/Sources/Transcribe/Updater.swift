import AppKit
import Foundation

/// Lean full-auto updater: on launch (staggered 5 s) the app checks GitHub
/// for a newer release; if one exists it downloads the zip, swaps the bundle
/// via a detached helper, and relaunches. Silent — failures NSLog and the
/// app simply keeps running. The menu item forces the same check.
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

    /// Check once and auto-install if newer. Silent on failure and when
    /// already current.
    static func checkAndInstall() {
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
                DispatchQueue.main.async { swapAndRelaunch(stagedApp: app, version: version) }
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

    /// Detached helper: waits for this process to exit, swaps the bundle, and relaunches.
    private static func swapAndRelaunch(stagedApp: URL, version: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = "/Applications/Transcribe.app"
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
        rm -rf '\(dest)'
        ditto '\(stagedApp.path)' '\(dest)'
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

}
