import Testing
import Foundation
import CryptoKit
@testable import ReleaseCore

private func response(_ request: URLRequest, _ value: JSON, _ status: Int = 200) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

@Test func rejectsWrongAppBeforeWriting() async throws {
    let client = AppleClient(token: { "private" }, transport: { request in
        #expect(request.httpMethod == "GET")
        return try response(request, ["data": ["id": "other", "attributes": ["bundleId": "co.snapwell"]]])
    })
    await #expect(throws: ReleaseError.self) { try await client.app(id: "6796609245") }
}

@Test func metadataRequiresCompleteBoundedFields() throws {
    let valid: JSON = ["name": "Teika", "subtitle": "Voice notes", "description": "Private voice notes", "keywords": "notes", "promotionalText": "",
                       "supportUrl": "https://teika.app/support/", "marketingUrl": "https://teika.app/",
                       "privacyPolicyUrl": "https://teika.app/privacy/", "copyright": "2026 Gustavs Cirulis", "reviewNotes": "No login."]
    try validateListing(valid)
    var invalid = valid
    invalid["keywords"] = String(repeating: "x", count: 101)
    #expect(throws: ReleaseError.self) { try validateListing(invalid) }
    invalid = valid; invalid["privacyPolicyUrl"] = "http://teika.app/privacy/"
    #expect(throws: ReleaseError.self) { try validateListing(invalid) }
    invalid = valid; invalid["reviewNotes"] = nil
    #expect(throws: ReleaseError.self) { try validateListing(invalid) }
}

@Test func screenshotsReserveTransferCommitAndVerifyWithoutJWTOnAssetHost() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data([1, 2, 3, 4]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    var phases: [String] = []
    let client = AppleClient(token: { "private-jwt" }, transport: { request in
        let method = request.httpMethod!
        phases.append(method)
        if method == "POST" {
            return try response(request, ["data": ["id": "asset", "attributes": ["uploadOperations": [[
                "url": "https://store.blobstore.apple.com/asset", "offset": 0, "length": 4, "method": "PUT",
                "requestHeaders": [["name": "Content-Type", "value": "image/png"]]]]]]])
        }
        if method == "PATCH" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! JSON
            let attrs = (body["data"] as! JSON)["attributes"] as! JSON
            #expect(attrs["uploaded"] as? Bool == true)
            #expect((attrs["sourceFileChecksum"] as? String)?.count == 32)
            return try response(request, [:])
        }
        return try response(request, ["data": ["attributes": ["assetDeliveryState": ["state": "COMPLETE"]]]])
    })
    var savedID: String?
    let id = try await client.uploadScreenshot(setID: "set", file: url, send: { request in
        #expect(savedID == "asset")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == Data([1, 2, 3, 4]))
        return 200
    }, reserved: { savedID = $0 }, pause: {})
    #expect(id == "asset")
    #expect(phases == ["POST", "PATCH", "GET"])
}

@Test(arguments: ["operation", "transfer", "processing"])
func assetFailuresNeverReportSuccess(_ failure: String) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data([1, 2, 3, 4]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let client = AppleClient(token: { "private" }, transport: { request in
        if request.httpMethod == "POST" {
            return try response(request, ["data": ["id": "asset", "attributes": ["uploadOperations": [[
                "url": "https://store.blobstore.apple.com/asset", "offset": 0,
                "length": failure == "operation" ? 5 : 4, "method": "PUT"]]]]])
        }
        if request.httpMethod == "GET" {
            return try response(request, ["data": ["attributes": ["assetDeliveryState": ["state": "FAILED"]]]])
        }
        return try response(request, [:])
    })
    await #expect(throws: ReleaseError.self) {
        try await client.uploadScreenshot(setID: "set", file: url, send: { _ in failure == "transfer" ? 500 : 200 }, pause: {})
    }
}

@Test func publicListingNeverReturnsReviewContacts() async throws {
    let client = AppleClient(token: { "private" }, transport: { request in
        if request.url!.path.hasSuffix("/appStoreVersionLocalizations") {
            return try response(request, ["data": [["id": "locale", "attributes": ["locale": "en-US", "description": "Notes", "contactEmail": "private@example.com"]]]])
        }
        if request.url!.path.hasSuffix("/appInfos") { return try response(request, ["data": [["id": "info", "attributes": ["appStoreState": "READY_FOR_DISTRIBUTION"]]]]) }
        if request.url!.path.hasSuffix("/appInfoLocalizations") { return try response(request, ["data": [["id": "info-locale", "attributes": ["locale": "en-US", "name": "Teika", "subtitle": "Voice notes"]]]]) }
        if request.url!.path.hasSuffix("/appScreenshotSets") { return try response(request, ["data": []]) }
        return try response(request, ["data": ["attributes": ["copyright": "2026 Gustavs Cirulis", "contactPhone": "private"]]])
    })
    let listing = try await client.listing(appID: "6796609245", versionID: "version", locale: "en-US")
    #expect(listing["supportUrl"] as? String == "https://teika.app/support/")
    #expect(!String(describing: listing).contains("private@example.com"))
    #expect(listing["contactPhone"] == nil)
}

@Test(arguments: [false, true]) func updatesMetadataAndCopiesReviewContactWithoutEmittingIt(_ editable: Bool) async throws {
    let listing: JSON = ["name": "Teika", "subtitle": "Voice notes", "description": "Private voice notes", "keywords": "notes", "promotionalText": "",
                         "supportUrl": "https://teika.app/support/", "marketingUrl": "https://teika.app/",
                         "privacyPolicyUrl": "https://teika.app/privacy/", "copyright": "2026 Gustavs Cirulis", "reviewNotes": "No login. Approve model setup."]
    var writes: [(String, JSON)] = []
    let client = AppleClient(token: { "private" }, transport: { request in
        let path = request.url!.path
        if request.httpMethod != "GET" {
            writes.append((path, try JSONSerialization.jsonObject(with: request.httpBody!) as! JSON))
            return try response(request, [:])
        }
        switch path {
        case "/v1/appStoreVersions/new/appStoreVersionLocalizations":
            return try response(request, ["data": [["id": "locale", "attributes": ["locale": "en-US"]]]])
        case "/v1/apps/6796609245/appInfos":
            return try response(request, ["data": [["id": "info", "attributes": ["appStoreState": editable ? "PREPARE_FOR_SUBMISSION" : "READY_FOR_DISTRIBUTION"]]]])
        case "/v1/appInfos/info/appInfoLocalizations":
            return try response(request, ["data": [["id": "info-locale", "attributes": ["locale": "en-US", "name": "Teika", "subtitle": "Voice notes", "privacyPolicyUrl": "https://teika.app/privacy/"]]]])
        case "/v1/appStoreVersions/old/appStoreReviewDetail":
            return try response(request, ["data": ["id": "old-review", "attributes": ["contactEmail": "private@example.com", "demoAccountRequired": false]]])
        case "/v1/appStoreVersions/new/appStoreReviewDetail":
            return try response(request, ["errors": [["code": "NOT_FOUND"]]], 404)
        default: throw ReleaseError("Unexpected endpoint: \(path)")
        }
    })
    try await client.updateListing(appID: "6796609245", versionID: "new", locale: "en-US", listing: listing, previousVersionID: "old")
    var expected = ["/v1/appStoreVersionLocalizations/locale", "/v1/appStoreVersions/new"]
    if editable { expected.append("/v1/appInfoLocalizations/info-locale") }
    expected.append("/v1/appStoreReviewDetails")
    #expect(writes.map(\.0) == expected)
    let attrs = ((writes.last!.1["data"] as? JSON)?["attributes"] as? JSON)!
    #expect(attrs["contactEmail"] as? String == "private@example.com")
    #expect(attrs["notes"] as? String == "No login. Approve model setup.")
}

@Test func screenshotResumeVerifiesChecksumsAndOrderingWithoutReupload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
    let digest = Insecure.MD5.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
    for file in files { try Data([1, 2, 3]).write(to: file) }
    let checkpoint = directory.appendingPathComponent("assets.json")
    try JSONSerialization.data(withJSONObject: ["version_id": "version", "files": [
        "APP_IPHONE_69/first.png": ["id": "first", "checksum": digest],
        "APP_IPHONE_69/second.png": ["id": "second", "checksum": digest]]]).write(to: checkpoint)
    var ids = ["old", "second", "first"]
    var writes: [String] = []
    let client = AppleClient(token: { "private" }, transport: { request in
        let path = request.url!.path
        if request.httpMethod == "DELETE" {
            writes.append("DELETE " + path)
            ids.removeAll { $0 == path.components(separatedBy: "/").last }
            return try response(request, [:])
        }
        if request.httpMethod == "PATCH" {
            writes.append("PATCH " + path)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! JSON
            ids = (body["data"] as! [JSON]).compactMap { $0["id"] as? String }
            return try response(request, [:])
        }
        #expect(request.httpMethod == "GET")
        if path.hasSuffix("/appStoreVersionLocalizations") {
            return try response(request, ["data": [["id": "locale", "attributes": ["locale": "en-US"]]]])
        }
        if path.hasSuffix("/appScreenshotSets") {
            return try response(request, ["data": [["id": "set", "attributes": ["screenshotDisplayType": "APP_IPHONE_69"]]]])
        }
        return try response(request, ["data": ids.map { ["id": $0, "attributes": [
            "sourceFileChecksum": digest, "assetDeliveryState": ["state": "COMPLETE"]]] }])
    })
    var saved: JSON = [:]
    try await client.screenshots(versionID: "version", locale: "en-US", sets: [["display": "APP_IPHONE_69", "files": files.map(\.path)]],
                                 checkpoint: checkpoint, save: { saved = $0 })
    #expect(ids == ["first", "second"])
    #expect(writes == ["DELETE /v1/appScreenshots/old", "PATCH /v1/appScreenshotSets/set/relationships/appScreenshots"])
    #expect(saved["verified"] as? Bool == true)
}

@Test func failedScreenshotReplacementPreservesOriginalAssetsAndCheckpoint() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data([1, 2, 3]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var mutations: [String] = []
    let client = AppleClient(token: { "private" }, transport: { request in
        let path = request.url!.path
        if request.httpMethod != "GET" { mutations.append(request.httpMethod! + " " + path) }
        if path.hasSuffix("/appStoreVersionLocalizations") {
            return try response(request, ["data": [["id": "locale", "attributes": ["locale": "en-US"]]]])
        }
        if path.hasSuffix("/appScreenshotSets") {
            return try response(request, ["data": [["id": "set", "attributes": ["screenshotDisplayType": "APP_IPHONE_69"]]]])
        }
        return try response(request, ["data": ["id": "replacement", "attributes": ["uploadOperations": [[
            "url": "https://store.blobstore.apple.com/asset", "offset": 0, "length": 99, "method": "PUT"]]]]])
    })
    var saved: JSON = [:]
    await #expect(throws: ReleaseError.self) {
        try await client.screenshots(versionID: "version", locale: "en-US", sets: [["display": "APP_IPHONE_69", "files": [file.path]]],
                                     checkpoint: file.appendingPathExtension("receipt"), save: { saved = $0 })
    }
    #expect(mutations == ["POST /v1/appScreenshots"])
    #expect(saved["verified"] == nil)
    #expect((saved["files"] as? JSON)?.count == 1)
}
