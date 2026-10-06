import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test func agentMetadataChangesPreservePackageSourceProtection() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(title: "Agent", text: "= Draft\n")
        try await workspace.library.open(document.id)
        let package = workspace.packageCache.appendingPathComponent("preview/test/1.0.0/lib.typ")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let source = "#let original = 1\n"
        try Data(source.utf8).write(to: package)
        #expect(workspace.open(package, preservingMain: true))
        let editor = try #require(workspace.editor)
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: true)
        let renamed = await tools.call("rename_document", arguments: .object([
            "document_id": .string(document.id.uuidString), "title": .string("Renamed"),
            "expected_metadata_revision": .string(document.metadataRevision),
            "request_id": .string("rename-with-package-open"),
        ]), access: access)
        #expect(!renamed.isError)
        #expect(workspace.documentURL == package && workspace.isPackageSource)
        #expect(!editor.isEditable && !workspace.documentTransitionInProgress)
        editor.insertText("overwrite", replacementRange: NSRange(location: 0, length: source.utf16.count))
        #expect(workspace.text == source && editor.string == source)
        #expect(try String(contentsOf: package, encoding: .utf8) == source)
        workspace.navigateBack()
        #expect(workspace.documentURL == document.sourceURL)
        #expect(editor.isEditable)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"))
    func mcpHurlExercisesRealDocumentWorkflow() async throws {
        let app = try WritingFixture(text: "= Hurl fixture\n", startService: false)
        defer { app.close() }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let connection = MCPConnection(
            workspace: app.workspace,
            helperURL: checkout.appendingPathComponent(".tools/leftblank-mcp"),
        )
        defer { connection.disable() }
        try await connection.enable()
        let descriptor = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: connection.descriptorURL))
        let token = try #require(descriptor["authentication"]["token"].string)
        let url = try #require(descriptor["url"].string)
        let output = app.root.appendingPathComponent("hurl.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let status = try await Task.detached {
            let process = Process(), log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }
            process.executableURL = checkout.appendingPathComponent(".tools/hurl/bin/hurl")
            process.arguments = [
                "--test",
                "--max-time",
                "15",
                "--secret",
                "token=" + token,
                "--variable",
                "url=" + url,
                "--variable",
                "tool_count=\(AgentTools.definitions.count)",
                checkout.appendingPathComponent("Tests/MCP/editing.hurl").path,
            ]
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        #expect(status == 0, Comment(rawValue: (try? String(contentsOf: output, encoding: .utf8)) ?? "Hurl failed"))
    }

    @Test func mcpHelperReturnsProjectImagesAsImageContent() async throws {
        let app = try WritingFixture(text: "= Images\n", startService: false)
        defer { app.close() }
        let document = try await app.workspace.library.store.create(title: "Figure", text: "#image(\"dot.png\")\n")
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try png.write(to: document.folderURL.appendingPathComponent("dot.png"))
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let connection = MCPConnection(
            workspace: app.workspace,
            helperURL: checkout.appendingPathComponent(".tools/leftblank-mcp"),
        )
        defer { connection.disable() }
        try await connection.enable(documentIDs: [document.id], canWrite: false)
        let descriptor = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: connection.descriptorURL))
        var request = try URLRequest(url: #require(descriptor["url"].string.flatMap(URL.init(string:))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        try request.setValue(
            "Bearer " + #require(descriptor["authentication"]["token"].string),
            forHTTPHeaderField: "Authorization",
        )
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("read_image"), "arguments": .object([
                "document_id": .string(document.id.uuidString), "path": .string("dot.png"),
            ])]),
        ]))
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode(JSONValue.self, from: data)["result"]
        #expect(result["isError"].foundationValue as? Bool == false)
        #expect(result["structuredContent"]["mime_type"].string == "image/png")
        let content = result["content"].array.first { $0["type"].string == "image" }
        #expect(content?["mimeType"].string == "image/png")
        #expect(content?["data"].string.flatMap { Data(base64Encoded: $0) } == png)
    }

    @Test func agentCompileUsesFreshSnapshotAndReportsUnpinnedInputs() async throws {
        let app = try WritingFixture(text: "= Compile fixture\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(title: "Compile", text: "= Snapshot\nHello\n")
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: true)
        let id = JSONValue.string(document.id.uuidString)
        let metadata = await tools.call("get_document", arguments: .object(["document_id": id]), access: access)
        let compiled = await tools.call(
            "compile_document",
            arguments: .object(["document_id": id, "expected_project_revision": metadata.value["project_revision"]]),
            access: access,
        )
        #expect(compiled.value["status"].string == "unverified")
        #expect(!compiled.isError)
        #expect(compiled.value["project_sources_compiled"].foundationValue as? Bool == true)
        #expect(compiled.value["is_current"].foundationValue as? Bool == true)
        #expect(compiled.value["compiled_project_revision"].string == metadata.value["project_revision"].string)
        try Data("#let bad = (\n".utf8).write(to: document.sourceURL, options: .atomic)
        let stale = await tools.call(
            "compile_document",
            arguments: .object(["document_id": id, "expected_project_revision": metadata.value["project_revision"]]),
            access: access,
        )
        #expect(stale.value["error"]["code"].string == "revision_conflict")
        let current = await tools.call("get_document", arguments: .object(["document_id": id]), access: access)
        let broken = await tools.call(
            "compile_document",
            arguments: .object(["document_id": id, "expected_project_revision": current.value["project_revision"]]),
            access: access,
        )
        #expect(broken.value["status"].string == "failed")
        #expect(broken.isError)
        #expect(broken.value["project_sources_compiled"].foundationValue as? Bool == false)
        #expect(!broken.value["diagnostics"].array.isEmpty || broken.value["engine_message"].string?.isEmpty == false)
    }

    @Test func agentDocumentCreationRespectsNativeLibraryTransitions() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: nil, canWrite: true)
        workspace.documentTransitionInProgress = true
        let busy = await tools.call("create_document", arguments: .object([
            "title": .string("New"), "source": .string("Hello"), "request_id": .string("during-transition"),
        ]), access: access)
        #expect(busy.value["error"]["code"].string == "busy")
        #expect(workspace.documentTransitionInProgress)
        #expect(try await workspace.library.store.list().isEmpty)
        workspace.documentTransitionInProgress = false
        let invalid = await tools.call("create_document", arguments: .object([
            "title": .string("   "), "source": .string("Hello"), "request_id": .string("invalid-title"),
        ]), access: access)
        #expect(invalid.value["error"]["code"].string == "invalid_params")
        #expect(!workspace.documentTransitionInProgress && !workspace.agentMetadataChangeInProgress)
        let created = await tools.call("create_document", arguments: .object([
            "title": .string("New"), "source": .string("Hello"), "request_id": .string("create-after-transition"),
        ]), access: access)
        #expect(!created.isError)
        #expect(try await workspace.library.store.list().count == 1)
        #expect(!workspace.documentTransitionInProgress && !workspace.agentMetadataChangeInProgress)
    }

    @Test func agentChangesLiveBufferWithUndoHistoryAndConflictProtection() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(title: "Agent", text: "= Draft\nOriginal 中文😀\n")
        try await workspace.library.open(document.id)
        await app.layout()
        let editor = try #require(workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved line\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let initial = workspace.text
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: true)
        let id = JSONValue.string(document.id.uuidString)
        let read = await tools.call(
            "read_file",
            arguments: .object(["document_id": id, "path": .string("main.typ")]),
            access: access,
        )
        #expect(read.value["text"].string == initial)
        let arguments: JSONValue = .object([
            "document_id": id,
            "path": .string("main.typ"),
            "old_str": .string("Original 中文😀"),
            "new_str": .string("Updated 中文😃"),
            "expected_revision": read.value["revision"],
            "request_id": .string("live-edit"),
        ])
        let result = await tools.call("str_replace", arguments: arguments, access: access)
        #expect(!result.isError)
        #expect(workspace.text.contains("Updated 中文😃") && workspace.text.contains("Unsaved line"))
        #expect(editor.string == workspace.text && workspace.savedText == workspace.text)
        let changed = workspace.text
        let undo = try #require(editor.undoManager)
        undo.undo()
        #expect(workspace.text == initial && editor.string == initial)
        undo.redo()
        #expect(workspace.text == changed)
        let beforeID = try #require(result.value["files"].array.first?["before_version_id"].string)
        let history = try await workspace.history.store.revisions(for: workspace.historyKey)
        let before = try #require(history.first { $0.id.uuidString == beforeID })
        #expect(try await workspace.history.store.source(for: before, key: workspace.historyKey) == initial)
        #expect(before.reason == .beforeAgentEdit)
        workspace.paletteOpen = true
        let current = await tools.call(
            "read_file",
            arguments: .object(["document_id": id, "path": .string("main.typ")]),
            access: access,
        )
        let refused = await tools.call(
            "str_replace",
            arguments: .object([
                "document_id": id,
                "path": .string("main.typ"),
                "old_str": .string("Updated"),
                "new_str": .string("Denied"),
                "expected_revision": current.value["revision"],
                "request_id": .string("busy"),
            ]),
            access: access,
        )
        #expect(refused.isError && workspace.text == changed)
        workspace.paletteOpen = false
        // An external disk edit must not be overwritten when the live buffer is saved.
        try Data("Externally changed\n".utf8).write(to: document.sourceURL, options: .atomic)
        let applied = await tools.call(
            "str_replace",
            arguments: .object([
                "document_id": id,
                "path": .string("main.typ"),
                "old_str": .string("Updated"),
                "new_str": .string("New"),
                "expected_revision": current.value["revision"],
                "request_id": .string("disk-conflict"),
            ]),
            access: access,
        )
        #expect(applied.value["status"].string == "applied")
        #expect(applied.value["files"].array.first?["save_status"].string == "save_failed")
        #expect(try String(contentsOf: document.sourceURL, encoding: .utf8) == "Externally changed\n")
    }

    @Test func mcpHelperAuthenticatesForwardsAndRevokesWithoutDocumentAccessOnInstall() async throws {
        let app = try WritingFixture(text: "= MCP\n", startService: false)
        defer { app.close() }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = checkout.appendingPathComponent(".tools/leftblank-mcp")
        let connection = MCPConnection(workspace: app.workspace, helperURL: helper)
        defer { connection.disable() }
        try await connection.enable(documentIDs: [], canWrite: false)
        #expect(connection.isRunning)
        let descriptor = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: connection.descriptorURL))
        let token = try #require(descriptor["authentication"]["token"].string)
        let endpoint = try #require(descriptor["url"].string.flatMap(URL.init(string:)))
        let prompt = try connection.setupPrompt()
        #expect(!prompt.contains(token))
        #expect(prompt.contains(connection.descriptorURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: connection.descriptorURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        func post(
            _ message: JSONValue,
            authorized: Bool = true,
            origin: String? = nil,
        ) async throws -> (JSONValue, Int) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
            if authorized {
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            if let origin {
                request.setValue(origin, forHTTPHeaderField: "Origin")
            }
            request.httpBody = try JSONEncoder().encode(message)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try #require(response as? HTTPURLResponse).statusCode
            return ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null, status)
        }
        let list: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        #expect(try await post(list, authorized: false).1 == 401)
        #expect(try await post(list, origin: "https://unexpected.example").1 == 403)
        let tools = try await post(list)
        #expect(tools.1 == 200)
        #expect(tools.0["result"]["tools"].array.contains { $0["name"].string == "read_file" })
        #expect(!tools.0["result"]["tools"].array.contains { $0["name"].string == "apply_patch" })
        let call: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(2),
            "method": .string("tools/call"),
            "params": .object(["name": .string("get_app_state"), "arguments": .object([:])]),
        ])
        let state = try await post(call)
        #expect(state.1 == 200)
        #expect(state.0["result"]["structuredContent"]["instance_id"].string == descriptor["instance_id"].string)
        #expect(state.0["result"]["structuredContent"]["open_documents"].array.isEmpty)
        let settings = NSHostingView(rootView: MCPSettingsSection(connection: connection))
        settings.layoutSubtreeIfNeeded()
        #expect(settings.fittingSize.height > 0)
        connection.disable()
        #expect(!connection.isRunning)
        #expect(!FileManager.default.fileExists(atPath: connection.descriptorURL.path))
        try await Task.sleep(for: .milliseconds(100))
        try await connection.enable()
        #expect(connection.allowsEditing)
        #expect(connection.grantedDocumentIDs == nil)
        let replacement = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: connection.descriptorURL))
        #expect(replacement["url"].string == endpoint.absoluteString)
        #expect(replacement["authentication"]["token"].string != token)
        #expect(try await post(call).1 == 401)
        connection.stop()
        #expect(!connection.isRunning && connection.isEnabled)
        try await Task.sleep(for: .milliseconds(100))
        await connection.resume()
        #expect(connection.isRunning)
        #expect(connection.allowsEditing && connection.grantedDocumentIDs == nil)
        let resumed = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: connection.descriptorURL))
        #expect(resumed["authentication"]["token"].string == replacement["authentication"]["token"].string)
        connection.stop()
        connection.disable()
        #expect(!connection.isEnabled)
        await connection.resume()
        #expect(!connection.isRunning)
    }
}
