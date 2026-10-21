import AppKit

struct AppCatalog {
    struct Entry {
        let name: String
        let id: String
        var aliases: [String] {
            let known: [String: [String]] = ["com.google.Chrome": ["Chrome", "Google Chrome"], "com.openai.chat": ["ChatGPT", "Chat GPT"], "com.apple.PhotoBooth": ["Photo Booth", "Photobooth"], "company.thebrowser.Browser": ["Arc", "Arc browser"]]
            return Array(Set([name] + (known[id] ?? [])))
        }
    }
    static func discover() -> [Entry] {
        var found: [String: Entry] = [:]
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for path in roots {
            for url in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                found[id] = Entry(name: url.deletingPathExtension().lastPathComponent, id: id)
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { found[id] = Entry(name: app.localizedName ?? id, id: id) }
        }
        return found.values.sorted { $0.name < $1.name }
    }
}
