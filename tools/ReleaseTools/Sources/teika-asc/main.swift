import Foundation
import ReleaseCore

@main struct Main {
    static func main() async {
        do {
            umask(0o077)
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { throw ReleaseError("Expected inspect, listing, stage, assets, submit, verify, or status") }
            var options: [String: String] = [:]
            var index = 1
            while index < args.count {
                guard args[index].hasPrefix("--"), index + 1 < args.count else { throw ReleaseError("Invalid arguments") }
                options[String(args[index].dropFirst(2))] = args[index + 1]
                index += 2
            }
            func option(_ name: String) throws -> String {
                guard let value = options[name], !value.isEmpty else { throw ReleaseError("Missing --\(name)") }
                return value
            }
            func json(_ path: String) throws -> JSON {
                guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? JSON else {
                    throw ReleaseError("Expected JSON object")
                }
                return value
            }
            func save(_ value: JSON, _ path: String) throws {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
            }
            let appID = "6796609245"
            let credentials = try Credentials()
            let client = AppleClient(token: { try credentials.token() })
            let app = try await client.app(id: appID)
            var output: JSON = ["app_id": appID, "primary_locale": (app["attributes"] as? JSON)?["primaryLocale"] as? String ?? "en-US"]
            let locale = options["locale"] ?? "en-US"
            switch command {
            case "inspect", "status":
                let builds = try await client.builds(appID: appID, platform: "IOS")
                output["builds"] = builds
                output["versions"] = try await client.versions(appID: appID, platform: "IOS")
                output["next_build"] = try nextBuild(builds, local: Int(options["local-build"] ?? "0") ?? 0)
            case "listing":
                output["listing"] = try await client.listing(appID: appID, versionID: option("version-id"), locale: locale)
            case "stage":
                let notes = try String(contentsOfFile: option("notes"), encoding: .utf8)
                try validateNotes(notes)
                let listing = try json(option("metadata"))
                try validateListing(listing)
                let version = try await client.prepareVersion(appID: appID, platform: "IOS", version: option("version"), notes: notes, locale: locale)
                let id = try requiredID(version)
                try await client.updateListing(appID: appID, versionID: id, locale: locale, listing: listing, previousVersionID: option("previous-version-id"))
                try await client.attach(versionID: id, buildID: option("build-id"))
                try await client.verifyListing(appID: appID, versionID: id, locale: locale, expected: listing)
                output["version_id"] = id
            case "assets":
                let plan = try json(option("plan"))
                guard let sets = plan["sets"] as? [JSON] else { throw ReleaseError("Missing screenshot sets") }
                let checkpoint = try option("checkpoint")
                try await client.screenshots(versionID: option("version-id"), locale: locale, sets: sets,
                    checkpoint: URL(fileURLWithPath: checkpoint), save: { try save($0, checkpoint) })
                output["assets_verified"] = true
            case "submit":
                let id = try option("version-id")
                let path = try option("checkpoint")
                let saved = (try? json(path)) ?? [:]
                if let previous = saved["version_id"] as? String, previous != id { throw ReleaseError("Submission checkpoint version mismatch") }
                output["submission"] = try await client.submit(appID: appID, platform: "IOS", versionID: id,
                    resumeID: saved["submission_id"] as? String, checkpoint: { try save(["version_id": id, "submission_id": $0], path) })
            case "verify":
                let metadata = try json(option("metadata"))
                let notes = try String(contentsOfFile: option("notes"), encoding: .utf8)
                try await client.verifyListing(appID: appID, versionID: option("version-id"), locale: locale, expected: metadata)
                output.merge(try await client.verifyRelease(appID: appID, platform: "IOS", version: option("version"),
                    versionID: option("version-id"), buildID: option("build-id"), buildNumber: option("build"),
                    submissionID: option("submission-id"), notes: notes, locale: locale)) { _, new in new }
            default: throw ReleaseError("Unknown command: \(command)")
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
