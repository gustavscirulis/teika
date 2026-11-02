import Foundation
import CryptoKit

public let listingLimits = ["description": 4000, "keywords": 100, "promotionalText": 170,
                            "supportUrl": 1000, "marketingUrl": 1000]
public let informationLimits = ["name": 30, "subtitle": 30, "privacyPolicyUrl": 1000]
private let editableInfoStates = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"]

public func validateListing(_ listing: JSON) throws {
    for (field, limit) in listingLimits.merging(informationLimits, uniquingKeysWith: { first, _ in first }) {
        guard let text = listing[field] as? String, text.count <= limit else {
            throw ReleaseError("Missing/oversized listing field: \(field)")
        }
    }
    for field in ["supportUrl", "marketingUrl", "privacyPolicyUrl"] {
        guard let text = listing[field] as? String, let url = URL(string: text),
              url.scheme == "https", url.host != nil else { throw ReleaseError("Invalid \(field)") }
    }
    guard !(listing["description"] as! String).isEmpty, !(listing["name"] as! String).isEmpty,
          let notes = listing["reviewNotes"] as? String, !notes.isEmpty, notes.count <= 4000,
          let copyright = listing["copyright"] as? String, !copyright.isEmpty else {
        throw ReleaseError("Description, copyright and review instructions are required")
    }
}

extension AppleClient {
    private func information(appID: String, locale: String) async throws -> (JSON, JSON, Bool) {
        let infos = try await pages("/v1/apps/\(appID)/appInfos?limit=200")
        func state(_ info: JSON) -> String {
            let attrs = info["attributes"] as? JSON ?? [:]
            return attrs["appStoreState"] as? String ?? attrs["appInfoState"] as? String ?? ""
        }
        // Prefer the editable/current submission over the older public information.
        guard let info = infos.first(where: { editableInfoStates.contains(state($0)) })
            ?? infos.first(where: { !["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"].contains(state($0)) })
            ?? infos.first(where: { ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains(state($0)) }) else {
            throw ReleaseError("No current App Information record")
        }
        let locales = try await pages("/v1/appInfos/\(try requiredID(info))/appInfoLocalizations?limit=200")
        guard let localized = locales.first(where: { ($0["attributes"] as? JSON)?["locale"] as? String == locale }) else {
            throw ReleaseError("Missing App Information locale")
        }
        return (info, localized, editableInfoStates.contains(state(info)))
    }

    /// Only public fields leave the helper. Reviewer identity stays in Apple/local config.
    public func listing(appID: String, versionID: String, locale: String) async throws -> JSON {
        let items = try await pages("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=200")
        guard let localized = items.first(where: { ($0["attributes"] as? JSON)?["locale"] as? String == locale }),
              let attributes = localized["attributes"] as? JSON else { throw ReleaseError("Missing \(locale) listing") }
        var result: JSON = ["locale": locale]
        for key in listingLimits.keys { result[key] = attributes[key] as? String ?? "" }
        let (_, infoLocale, _) = try await information(appID: appID, locale: locale)
        for key in informationLimits.keys { result[key] = (infoLocale["attributes"] as? JSON)?[key] as? String ?? "" }
        let version = try await request("/v1/appStoreVersions/\(versionID)")
        result["copyright"] = ((version["data"] as? JSON)?["attributes"] as? JSON)?["copyright"] as? String ?? ""
        result["supportUrl"] = "https://teika.app/support/"
        result["marketingUrl"] = "https://teika.app/"
        result["privacyPolicyUrl"] = "https://teika.app/privacy/"
        let sets = try await pages("/v1/appStoreVersionLocalizations/\(try requiredID(localized))/appScreenshotSets?limit=200")
        result["screenshotDisplays"] = sets.compactMap { ($0["attributes"] as? JSON)?["screenshotDisplayType"] }
        return result
    }

    public func updateListing(appID: String, versionID: String, locale: String,
                              listing: JSON, previousVersionID: String) async throws {
        try validateListing(listing)
        let localized = try await localization(versionID: versionID, locale: locale)
        var attributes: JSON = [:]
        for key in listingLimits.keys { attributes[key] = listing[key] }
        _ = try await request("/v1/appStoreVersionLocalizations/\(try requiredID(localized))", method: "PATCH",
            body: ["data": ["id": try requiredID(localized), "type": "appStoreVersionLocalizations", "attributes": attributes]])
        _ = try await request("/v1/appStoreVersions/\(versionID)", method: "PATCH", body: ["data": [
            "id": versionID, "type": "appStoreVersions", "attributes": ["copyright": listing["copyright"]!]]])
        let (_, infoLocale, editable) = try await information(appID: appID, locale: locale)
        if editable {
            var fields: JSON = [:]
            for key in informationLimits.keys { fields[key] = listing[key] }
            _ = try await request("/v1/appInfoLocalizations/\(try requiredID(infoLocale))", method: "PATCH", body: ["data": [
                "id": try requiredID(infoLocale), "type": "appInfoLocalizations",
                "attributes": fields]])
        } else {
            let actual = infoLocale["attributes"] as? JSON ?? [:]
            guard informationLimits.keys.allSatisfy({ (actual[$0] as? String ?? "") == listing[$0] as? String }) else {
                throw ReleaseError("App Information differs and no editable record is available")
            }
        }
        // Copy the prior review contact directly, without printing or persisting it.
        let previous = try await request("/v1/appStoreVersions/\(previousVersionID)/appStoreReviewDetail")
        guard let review = previous["data"] as? JSON, let old = review["attributes"] as? JSON else {
            throw ReleaseError("Previous review contact is unavailable; configure it in Apple")
        }
        var reviewFields: JSON = ["notes": listing["reviewNotes"]!]
        for key in ["contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountRequired", "demoAccountName", "demoAccountPassword"] {
            if let value = old[key], !(value is NSNull) { reviewFields[key] = value }
        }
        let current: JSON
        do { current = try await request("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail") }
        catch let error as ReleaseError where error.message.hasPrefix("Apple HTTP 404:") { current = [:] }
        if let detail = current["data"] as? JSON, let id = detail["id"] as? String {
            _ = try await request("/v1/appStoreReviewDetails/\(id)", method: "PATCH", body: ["data": [
                "id": id, "type": "appStoreReviewDetails", "attributes": reviewFields]])
        } else {
            _ = try await request("/v1/appStoreReviewDetails", method: "POST", body: ["data": [
                "type": "appStoreReviewDetails", "attributes": reviewFields,
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]]]]])
        }
    }

    public func localization(versionID: String, locale: String) async throws -> JSON {
        let items = try await pages("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=200")
        guard let item = items.first(where: { ($0["attributes"] as? JSON)?["locale"] as? String == locale }) else {
            throw ReleaseError("Missing listing localization")
        }
        return item
    }

    public func verifyListing(appID: String, versionID: String, locale: String, expected: JSON) async throws {
        let localized = try await localization(versionID: versionID, locale: locale)
        let actual = localized["attributes"] as? JSON ?? [:]
        for key in listingLimits.keys {
            // Apple represents empty optional promotional text/URLs as null.
            guard (actual[key] as? String ?? "") == expected[key] as? String else {
                throw ReleaseError("Remote listing differs: \(key)")
            }
        }
        let version = try await request("/v1/appStoreVersions/\(versionID)")
        guard (((version["data"] as? JSON)?["attributes"] as? JSON)?["copyright"] as? String) == expected["copyright"] as? String else {
            throw ReleaseError("Remote copyright differs")
        }
        let review = try await request("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail")
        guard (((review["data"] as? JSON)?["attributes"] as? JSON)?["notes"] as? String) == expected["reviewNotes"] as? String else {
            throw ReleaseError("Remote review instructions differ")
        }
        let (_, infoLocale, _) = try await information(appID: appID, locale: locale)
        let actualInfo = infoLocale["attributes"] as? JSON ?? [:]
        for key in informationLimits.keys {
            guard (actualInfo[key] as? String ?? "") == expected[key] as? String else {
                throw ReleaseError("Remote App Information differs: \(key)")
            }
        }
    }

    /// Reserve, upload, commit, poll. Signed asset URLs never receive the API JWT.
    /// https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect
    public func uploadScreenshot(setID: String, file: URL,
                                 send: ((URLRequest) async throws -> Int)? = nil,
                                 reserved: (String) throws -> Void = { _ in },
                                 pause: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) async throws -> String {
        let bytes = try Data(contentsOf: file)
        let checksum = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let response = try await request("/v1/appScreenshots", method: "POST", body: ["data": [
            "type": "appScreenshots", "attributes": ["fileName": file.lastPathComponent, "fileSize": bytes.count],
            "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": setID]]]]])
        guard let asset = response["data"] as? JSON, let attrs = asset["attributes"] as? JSON,
              let operations = attrs["uploadOperations"] as? [JSON], !operations.isEmpty else { throw ReleaseError("Missing asset upload operations") }
        let id = try requiredID(asset)
        try reserved(id)
        var transferred = 0
        for operation in operations {
            guard let address = operation["url"] as? String, let url = URL(string: address), url.scheme == "https",
                  let offset = operation["offset"] as? Int, let length = operation["length"] as? Int,
                  offset == transferred, length > 0, offset <= bytes.count, length <= bytes.count - offset,
                  let method = operation["method"] as? String, method == "PUT" else {
                throw ReleaseError("Invalid asset upload operation")
            }
            var upload = URLRequest(url: url)
            upload.httpMethod = method
            upload.httpBody = bytes.subdata(in: offset..<(offset + length))
            for header in operation["requestHeaders"] as? [JSON] ?? [] {
                if let name = header["name"] as? String, let value = header["value"] as? String {
                    guard name.lowercased() != "authorization" else { throw ReleaseError("Refusing asset authorization header") }
                    upload.setValue(value, forHTTPHeaderField: name)
                }
            }
            let status: Int
            if let send { status = try await send(upload) }
            else {
                let (_, response) = try await URLSession.shared.data(for: upload)
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            }
            guard (200..<300).contains(status) else { throw ReleaseError("Asset upload failed: HTTP \(status)") }
            transferred += length
        }
        guard transferred == bytes.count else { throw ReleaseError("Incomplete asset upload") }
        _ = try await request("/v1/appScreenshots/\(id)", method: "PATCH", body: ["data": ["id": id,
            "type": "appScreenshots", "attributes": ["uploaded": true, "sourceFileChecksum": checksum]]])
        for _ in 0..<60 {
            let status = try await request("/v1/appScreenshots/\(id)")
            let attributes = (status["data"] as? JSON)?["attributes"] as? JSON ?? [:]
            let state = (attributes["assetDeliveryState"] as? JSON)?["state"] as? String ?? "UNKNOWN"
            if state == "COMPLETE" { return id }
            if state == "FAILED" { throw ReleaseError("Apple failed to process screenshot \(file.lastPathComponent)") }
            try await pause()
        }
        throw ReleaseError("Screenshot processing timed out; inspect asset \(id) before resuming")
    }

    public func screenshots(versionID: String, locale: String, sets: [JSON], checkpoint: URL,
                            save: @escaping (JSON) throws -> Void) async throws {
        let local = try await localization(versionID: versionID, locale: locale)
        let localizationID = try requiredID(local)
        var receipt = (try? Data(contentsOf: checkpoint)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON } ?? [:]
        if let saved = receipt["version_id"] as? String, saved != versionID { throw ReleaseError("Screenshot checkpoint belongs to another version") }
        receipt["version_id"] = versionID
        var uploaded = receipt["files"] as? JSON ?? [:]
        for plan in sets {
            guard let display = plan["display"] as? String, let files = plan["files"] as? [String], !files.isEmpty else {
                throw ReleaseError("Invalid screenshot plan")
            }
            let existing = try await pages("/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets?limit=200")
            let set: JSON
            if let found = existing.first(where: { ($0["attributes"] as? JSON)?["screenshotDisplayType"] as? String == display }) { set = found }
            else {
                let created = try await request("/v1/appScreenshotSets", method: "POST", body: ["data": [
                    "type": "appScreenshotSets", "attributes": ["screenshotDisplayType": display],
                    "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": localizationID]]]]])
                guard let value = created["data"] as? JSON else { throw ReleaseError("Missing screenshot set") }
                set = value
            }
            let setID = try requiredID(set)
            var ids: [String] = []
            for path in files {
                let file = URL(fileURLWithPath: path)
                let digest = Insecure.MD5.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                let key = display + "/" + file.lastPathComponent
                if let previous = uploaded[key] as? JSON, let id = previous["id"] as? String {
                    guard previous["checksum"] as? String == digest else { throw ReleaseError("Screenshot changed since upload; use a new release attempt") }
                    let current = try await pages("/v1/appScreenshotSets/\(setID)/appScreenshots?limit=200")
                    if let asset = current.first(where: { $0["id"] as? String == id }) {
                        let attrs = asset["attributes"] as? JSON ?? [:]
                        if (attrs["assetDeliveryState"] as? JSON)?["state"] as? String == "COMPLETE",
                           attrs["sourceFileChecksum"] as? String == digest { ids.append(id); continue }
                        // Only our checkpoint's incomplete asset may be replaced.
                        _ = try await request("/v1/appScreenshots/\(id)", method: "DELETE")
                    }
                }
                let id = try await uploadScreenshot(setID: setID, file: file, reserved: { id in
                    uploaded[key] = ["id": id, "checksum": digest]
                    receipt["files"] = uploaded
                    try save(receipt)
                })
                ids.append(id)
            }
            // Preserve the old set until every replacement has processed successfully.
            let current = try await pages("/v1/appScreenshotSets/\(setID)/appScreenshots?limit=200")
            for asset in current {
                let id = try requiredID(asset)
                if !ids.contains(id) { _ = try await request("/v1/appScreenshots/\(id)", method: "DELETE") }
            }
            _ = try await request("/v1/appScreenshotSets/\(setID)/relationships/appScreenshots", method: "PATCH",
                body: ["data": ids.map { ["type": "appScreenshots", "id": $0] }])
            let final = try await pages("/v1/appScreenshotSets/\(setID)/appScreenshots?limit=200")
            guard final.compactMap({ $0["id"] as? String }) == ids else { throw ReleaseError("Screenshot order read-back failed") }
        }
        receipt["verified"] = true
        try save(receipt)
    }
}
