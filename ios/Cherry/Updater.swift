import Foundation

/// Same idea as the Android updater: ship a built-in copy, pull newer ones from GitHub Pages.
enum Updater {
    static let base = "https://saicharan13579-source.github.io/cherry/"

    static var webDir: URL { Bundle.main.resourceURL!.appendingPathComponent("web") }
    static var docDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("web")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func build(at dir: URL) -> Int {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("build.txt"), encoding: .utf8) else { return 0 }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The page to open and the folder it may read from.
    static func startFile() -> (URL, URL) {
        let a = build(at: webDir), d = build(at: docDir)
        let idx = docDir.appendingPathComponent("index.html")
        if d > a && FileManager.default.fileExists(atPath: idx.path) {
            let three = docDir.appendingPathComponent("three.min.js")
            if !FileManager.default.fileExists(atPath: three.path) {
                try? FileManager.default.copyItem(at: webDir.appendingPathComponent("three.min.js"), to: three)
            }
            return (idx, docDir)
        }
        return (webDir.appendingPathComponent("index.html"), webDir)
    }

    static func check(_ ready: @escaping (Int) -> Void) {
        guard let vurl = URL(string: base + "version.json?t=\(Int(Date().timeIntervalSince1970))") else { return }
        var req = URLRequest(url: vurl); req.cachePolicy = .reloadIgnoringLocalCacheData; req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = (obj["build"] as? NSNumber)?.intValue else { return }
            let have = max(build(at: webDir), build(at: docDir))
            guard remote > have, let hurl = URL(string: base + "app.html?b=\(remote)") else { return }
            var r2 = URLRequest(url: hurl); r2.cachePolicy = .reloadIgnoringLocalCacheData; r2.timeoutInterval = 60
            URLSession.shared.dataTask(with: r2) { html, resp, _ in
                guard let html = html, (resp as? HTTPURLResponse)?.statusCode == 200, html.count > 100_000,
                      let s = String(data: html, encoding: .utf8), s.contains("cherry-build") else { return }
                let dir = docDir
                do {
                    try html.write(to: dir.appendingPathComponent("index.html"), options: .atomic)
                    try "\(remote)".data(using: .utf8)!.write(to: dir.appendingPathComponent("build.txt"), options: .atomic)
                    let three = dir.appendingPathComponent("three.min.js")
                    if !FileManager.default.fileExists(atPath: three.path) {
                        try? FileManager.default.copyItem(at: webDir.appendingPathComponent("three.min.js"), to: three)
                    }
                    DispatchQueue.main.async { ready(remote) }
                } catch {}
            }.resume()
        }.resume()
    }
}
