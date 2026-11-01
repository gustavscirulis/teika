import Foundation

enum ThingsDestination: String, CaseIterable {
    case inbox, today

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        }
    }
}

/// Pure URL construction, separate from queue persistence and UIApplication.
enum ThingsExportURL {
    static let callbackHost = "things-export"
    static let notesLimit = 10_000
    static let shorteningNotice = "\n\n[Transcript shortened. The complete note is saved in Teika.]"

    static func notes(_ transcript: String) -> String {
        // Bound UTF-16 length conservatively as Things may measure NSString length.
        // Never cut inside an emoji or a composed character.
        guard transcript.utf16.count > notesLimit else { return transcript }
        let budget = notesLimit - shorteningNotice.utf16.count
        var length = 0
        let excerpt = transcript.prefix { character in
            length += character.utf16.count
            return length <= budget
        }
        return String(excerpt) + shorteningNotice
    }

    static func add(
        title: String, transcript: String, operationID: String,
        destination: ThingsDestination = .today
    ) -> URL {
        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/add"
        // Things defaults to Inbox when neither a date nor a list is supplied.
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "show-quick-entry", value: "false"),
            URLQueryItem(name: "reveal", value: "false"),
            URLQueryItem(name: "x-source", value: "Teika"),
        ] + (transcript.isEmpty ? [] : [URLQueryItem(name: "notes", value: notes(transcript))])
        + (destination == .today ? [URLQueryItem(name: "when", value: "today")] : [])
        + ["success", "error", "cancel"].map { result in
            var callback = URLComponents()
            callback.scheme = TeikaURL.scheme
            callback.host = callbackHost
            callback.queryItems = [
                URLQueryItem(name: "operation", value: operationID),
                URLQueryItem(name: "result", value: result),
            ]
            return URLQueryItem(name: "x-\(result)", value: callback.url!.absoluteString)
        }
        // Foundation leaves '+' unescaped in query values. Encode it too so the
        // recipient cannot interpret a literal plus in a transcript as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    struct Callback {
        let operationID: String
        let result: String
        let taskID: String?

        init?(url: URL) {
            guard url.scheme == TeikaURL.scheme, url.host == callbackHost,
                  url.path.isEmpty || url.path == "/",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else { return nil }
            func single(_ name: String) -> String? {
                let matches = items.filter { $0.name == name }
                return matches.count == 1 ? matches[0].value : nil
            }
            guard let operation = single("operation"), UUID(uuidString: operation) != nil,
                  let result = single("result"), ["success", "error", "cancel"].contains(result)
            else { return nil }
            let task = single("x-things-id")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if result == "success" {
                guard let task, !task.isEmpty, !task.contains(",") else { return nil }
            }
            operationID = operation
            self.result = result
            taskID = task
        }
    }
}
