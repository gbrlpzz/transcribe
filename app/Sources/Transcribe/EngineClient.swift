import Foundation

/// Client for the local Python engine server (127.0.0.1). Also responsible for
/// making sure the engine is running before a dictation.
final class EngineClient {
    let port: Int

    init(port: Int) {
        self.port = port
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func health(completion: @escaping (_ up: Bool, _ model: String?) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let model = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])
                .flatMap { $0["model"] as? String }
            DispatchQueue.main.async { completion(ok, model) }
        }.resume()
    }

    @discardableResult
    func transcribe(path: URL, preserveSource: Bool = false,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> URLSessionDataTask {
        var req = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Dictations are seconds-long: fail fast when the engine is busy with
        // a long file job. File jobs may legitimately run for many minutes.
        req.timeoutInterval = preserveSource ? 1800 : 90
        let body: [String: Any] = [
            "path": path.path,
            "preserve_source": preserveSource,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: req) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "Transcribe", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "Bad engine response"])))
                }
                return
            }
            if let errorText = json["error"] as? String {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "Transcribe", code: 3,
                                                userInfo: [NSLocalizedDescriptionKey: errorText])))
                }
                return
            }
            let result = TranscriptionResult(
                text: json["text"] as? String ?? "",
                language: json["language"] as? String ?? "",
                model: json["model"] as? String ?? "",
                transcriptPath: json["transcript_path"] as? String ?? ""
            )
            DispatchQueue.main.async { completion(.success(result)) }
        }
        task.resume()
        return task
    }

    func reload(completion: @escaping (Bool) -> Void = { _ in }) {
        var req = URLRequest(url: baseURL.appendingPathComponent("reload"))
        req.timeoutInterval = 300
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    // MARK: - Engine lifecycle

    /// Make sure the Python engine server is reachable; spawn it if needed.
    func ensureEngineRunning(completion: @escaping (Bool) -> Void) {
        health { [self] ok, _ in
            if ok { completion(true); return }
            guard let binary = Self.resolveEngineBinary() else {
                completion(false)
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = ["serve"]  // port comes from the shared config.json
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            // GUI apps launched via `open` get a minimal PATH without Homebrew,
            // which would hide ffmpeg from the engine. Prepend the usual spots.
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/sbin:/usr/local/sbin"
            env["PATH"] = (env["PATH"].map { extra + ":" + $0 } ?? extra)
            proc.environment = env
            do {
                try proc.run()
            } catch {
                completion(false)
                return
            }
            // wait for the server to come up (model download may take a while
            // on first run; health answers as soon as the port is open).
            // Poll every 0.25 s so a cold engine feels instant to the user.
            var attempts = 0
            func poll() {
                attempts += 1
                self.health { ok, _ in
                    if ok {
                        completion(true)
                    } else if attempts < 240 {  // 60 s ceiling for first-run downloads
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                    } else {
                        completion(false)
                    }
                }
            }
            poll()
        }
    }

    static func resolveEngineBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/transcribe",
            "/usr/local/bin/transcribe",
            "\(NSHomeDirectory())/.local/bin/transcribe",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // fall back to PATH lookup
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "transcribe"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }
}

struct TranscriptionResult {
    let text: String
    let language: String
    let model: String
    let transcriptPath: String
}
