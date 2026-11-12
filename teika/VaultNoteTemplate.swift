import Foundation

/// How a new note is named and filled, resolved from the vault's own Obsidian
/// settings (the Unique note creator and Templates core plugins), with optional
/// Teika overrides on top. Empty overrides mean "use what the vault says".
nonisolated struct VaultNoteSettings: Equatable {
    static let defaultFilenameFormat = "YYYY-MM-DD HHmm"
    static let defaultDateFormat = "YYYY-MM-DD"
    static let defaultTimeFormat = "HH:mm"

    /// moment.js format for the file name, as in the Unique note creator.
    var filenameFormat: String
    /// Folder inside the vault; empty is the vault root. May contain `{{date:FORMAT}}`.
    var folder: String
    /// Vault-relative template path (with or without `.md`); empty for none.
    var templatePath: String
    var dateFormat: String
    var timeFormat: String

    init(
        filenameFormat: String = defaultFilenameFormat, folder: String = "",
        templatePath: String = "", dateFormat: String = defaultDateFormat,
        timeFormat: String = defaultTimeFormat
    ) {
        self.filenameFormat = filenameFormat
        self.folder = folder
        self.templatePath = templatePath
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
    }

    struct Overrides: Equatable {
        var filenameFormat = ""
        var folder = ""
        var templatePath = ""
    }

    /// Reads `.obsidian/zk-prefixer.json` and `.obsidian/templates.json`. Missing or
    /// unreadable files fall back to Obsidian's own defaults, except the file name,
    /// which falls back to a readable timestamp rather than `YYYYMMDDHHmm`.
    static func fromVault(
        uniqueNoteJSON: Data?, templatesJSON: Data?, overrides: Overrides = .init()
    ) -> Self {
        let unique = uniqueNoteJSON.flatMap(Self.object(from:)) ?? [:]
        let templates = templatesJSON.flatMap(Self.object(from:)) ?? [:]
        func value(_ dict: [String: Any], _ key: String) -> String? {
            (dict[key] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0 }
        }
        func pick(_ override: String, _ vault: String?, _ fallback: String) -> String {
            override.trimmed.isEmpty ? (vault ?? fallback) : override
        }
        return Self(
            filenameFormat: pick(
                overrides.filenameFormat,
                uniqueNoteJSON == nil ? nil : (value(unique, "format") ?? "YYYYMMDDHHmm"),
                defaultFilenameFormat),
            folder: pick(overrides.folder, value(unique, "folder"), ""),
            templatePath: pick(overrides.templatePath, value(unique, "template"), ""),
            dateFormat: value(templates, "dateFormat") ?? defaultDateFormat,
            timeFormat: value(templates, "timeFormat") ?? defaultTimeFormat)
    }

    private static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The vault-relative folder for a note created at `date`, without slashes at
    /// either end. `/` (Obsidian's way of saying the root) becomes "".
    func resolvedFolder(for date: Date, timeZone: TimeZone = .current) -> String {
        let expanded = VaultNoteTemplate.expandDates(
            in: folder, date: date, dateFormat: dateFormat, timeFormat: timeFormat,
            timeZone: timeZone)
        return expanded.split(separator: "/")
            .map { VaultNoteTemplate.sanitizedName(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// The template file's vault-relative path, with `.md` added as Obsidian does.
    var resolvedTemplatePath: String? {
        let path = templatePath.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        return path.lowercased().hasSuffix(".md") ? path : path + ".md"
    }

    func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let name = VaultNoteTemplate.sanitizedName(
            MomentFormat.string(from: date, format: filenameFormat, timeZone: timeZone))
        return name.isEmpty ? MomentFormat.string(
            from: date, format: Self.defaultFilenameFormat, timeZone: timeZone) : name
    }
}

nonisolated enum VaultNoteTemplate {
    /// Teika's own placeholder: where the transcript goes. Obsidian leaves it alone,
    /// so the same template still works for notes created in Obsidian.
    static let textPlaceholder = "{{text}}"

    /// The rendered template around the transcript. The file is always
    /// `prefix + text + suffix`, which lets later edits rewrite only the transcript.
    struct Rendered: Equatable {
        var prefix: String
        var suffix: String

        func content(with text: String) -> String { prefix + text + suffix }
    }

    /// Fills `{{date}}`, `{{time}}`, `{{title}}` and their `:FORMAT` forms the way
    /// Obsidian's Templates plugin does. Without `{{text}}` the transcript follows the
    /// template, as typing does in a new unique note.
    static func render(
        template: String?, title: String, date: Date, settings: VaultNoteSettings,
        timeZone: TimeZone = .current
    ) -> Rendered {
        guard let template, !template.isEmpty else { return Rendered(prefix: "", suffix: "") }
        let filled = expandDates(
            in: template, date: date, dateFormat: settings.dateFormat,
            timeFormat: settings.timeFormat, timeZone: timeZone)
            .replacingOccurrences(
                of: "{{title}}", with: title, options: .caseInsensitive)
        if let range = filled.range(of: textPlaceholder, options: .caseInsensitive) {
            return Rendered(
                prefix: String(filled[..<range.lowerBound]),
                suffix: String(filled[range.upperBound...])
                    .replacingOccurrences(of: textPlaceholder, with: "", options: .caseInsensitive))
        }
        // Text typed straight after a closing `---` would break the frontmatter.
        return Rendered(prefix: filled.hasSuffix("\n") ? filled : filled + "\n", suffix: "")
    }

    /// Expands `{{date}}`, `{{time}}`, `{{date:FORMAT}}` and `{{time:FORMAT}}`.
    static func expandDates(
        in text: String, date: Date, dateFormat: String, timeFormat: String,
        timeZone: TimeZone = .current
    ) -> String {
        guard text.contains("{{") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let custom = parts.count > 1 ? String(parts[1]) : nil
            switch name {
            case "date":
                out += MomentFormat.string(
                    from: date, format: custom ?? dateFormat, timeZone: timeZone)
            case "time":
                out += MomentFormat.string(
                    from: date, format: custom ?? timeFormat, timeZone: timeZone)
            default:
                out += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Removes characters Obsidian refuses in file names, or that break links.
    static func sanitizedName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|#^[]")
        let cleaned = name.unicodeScalars
            .map { forbidden.contains($0) || CharacterSet.newlines.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the note from Obsidian.
        return cleaned.drop(while: { $0 == "." }).trimmingCharacters(in: .whitespaces)
    }
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
