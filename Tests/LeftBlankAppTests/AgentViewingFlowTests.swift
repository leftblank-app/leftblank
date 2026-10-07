import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func agentRendersCapturedPagesAsPNGWithRealEngine() async throws {
        let app = try WritingFixture(text: "= Render fixture\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(
            title: "Render",
            text: "#set page(width: 200pt, height: 100pt, fill: white)\n= One\n#pagebreak()\n= Two\n",
        )
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: false)
        let id = JSONValue.string(document.id.uuidString)
        let metadata = await tools.call("get_document", arguments: .object(["document_id": id]), access: access)
        let rendered = await tools.call("render_page", arguments: .object([
            "document_id": id, "page": .number(2), "ppi": .number(72),
            "expected_project_revision": metadata.value["project_revision"],
        ]), access: access)
        #expect(!rendered.isError, "\(rendered.value)")
        #expect(rendered.value["page_count"].int == 2)
        #expect(rendered.value["compiled_project_revision"].string == metadata.value["project_revision"].string)
        #expect(rendered.value["is_current"].foundationValue as? Bool == true)
        let image = try #require(rendered.images.first)
        #expect(image.mimeType == "image/png")
        #expect(image.data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let bitmap = try #require(NSBitmapImageRep(data: image.data))
        // 200 × 100 pt at 72 ppi is one pixel per point.
        #expect(bitmap.pixelsWide == 200 && bitmap.pixelsHigh == 100)
        #expect(rendered.value["width"].int == 200 && rendered.value["height"].int == 100)
        let sharp = await tools.call(
            "render_page",
            arguments: .object(["document_id": id, "ppi": .number(144)]),
            access: access,
        )
        #expect(sharp.images.first.flatMap { NSBitmapImageRep(data: $0.data) }?.pixelsWide == 400)
        let beyond = await tools.call(
            "render_page",
            arguments: .object(["document_id": id, "page": .number(3)]),
            access: access,
        )
        #expect(beyond.value["error"]["code"].string == "page_out_of_range")
        #expect(beyond.value["page_count"].int == 2)
        try Data("#let broken = (\n".utf8).write(to: document.sourceURL, options: .atomic)
        let broken = await tools.call("render_page", arguments: .object(["document_id": id]), access: access)
        #expect(broken.isError && broken.images.isEmpty)
        #expect(broken.value["error"]["code"].string == "compile_failed")
        #expect(broken.value["engine_message"].string?.contains("<compile>") != false)
        #expect(broken.value["engine_message"].string?.contains(workspace.stateDirectory.path) == false)
    }

    @Test func agentRendersHugePagesWithinPixelLimitsWithRealEngine() async throws {
        let app = try WritingFixture(text: "= Poster fixture\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(
            title: "Poster",
            text: "#set page(width: 500cm, height: 500cm)\n#set text(size: 400pt)\nPoster\n" +
                "#page(width: 10000cm, height: 1cm)[Strip]\n",
        )
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: false)
        let id = JSONValue.string(document.id.uuidString)
        let poster = await tools.call("render_page", arguments: .object([
            "document_id": id, "ppi": .number(288),
        ]), access: access)
        #expect(!poster.isError, "\(poster.value)")
        let bitmap = try #require(poster.images.first.flatMap { NSBitmapImageRep(data: $0.data) })
        #expect(max(bitmap.pixelsWide, bitmap.pixelsHigh) <= 2048)
        #expect(bitmap.pixelsWide * bitmap.pixelsHigh <= 3_145_728)
        // 500 cm is about 196.85 in, so the image is square and close to the area bound.
        #expect(bitmap.pixelsWide == bitmap.pixelsHigh && bitmap.pixelsWide > 1700)
        #expect(poster.value["ppi_reduced"].foundationValue as? Bool == true)
        #expect(poster.value["requested_ppi"].int == 288)
        let ppi = try #require(poster.value["ppi"].foundationValue as? Double)
        #expect(abs(Double(bitmap.pixelsWide) - 196.85 * ppi) <= 1)
        #expect(poster.value["downscaled"].foundationValue as? Bool == false)
        let strip = await tools.call("render_page", arguments: .object([
            "document_id": id, "page": .number(2),
        ]), access: access)
        #expect(strip.isError && strip.images.isEmpty)
        #expect(strip.value["error"]["code"].string == "page_too_large")
        #expect(strip.value["page_count"].int == 2)
    }

    @Test func agentQueriesMetadataFromTheLiveBufferWithRealEngine() async throws {
        let app = try WritingFixture(text: "= Query fixture\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(title: "Items", text: """
        = Tracker
        == Open work
        #metadata((id: "A", status: "done")) <item>
        #metadata((id: "B", status: "todo")) <item>

        """)
        try await workspace.library.open(document.id)
        await app.layout()
        let editor = try #require(workspace.editor)
        // Unsaved text is part of the captured revision.
        editor.insertSnippet(
            Snippet(text: "#metadata((id: \"C\", status: \"todo\")) <item>\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        #expect(workspace.text != workspace.savedText)
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: false)
        let id = JSONValue.string(document.id.uuidString)
        let items = await tools.call("query_document", arguments: .object([
            "document_id": id, "selector": .string("<item>"), "field": .string("value"),
        ]), access: access)
        #expect(!items.isError, "\(items.value)")
        #expect(items.value["count"].int == 3)
        #expect(items.value["items"].array.map { $0["id"].string ?? "" } == ["A", "B", "C"])
        #expect(items.value["items"].array.first?["status"].string == "done")
        #expect(items.value["is_current"].foundationValue as? Bool == true)
        let headings = await tools.call("query_document", arguments: .object([
            "document_id": id, "selector": .string("heading.where(level: 2)"), "one": .bool(true),
        ]), access: access)
        #expect(headings.value["value"]["func"].string == "heading")
        #expect(headings.value["value"]["body"]["text"].string == "Open work")
        let ambiguous = await tools.call("query_document", arguments: .object([
            "document_id": id, "selector": .string("<item>"), "one": .bool(true),
        ]), access: access)
        #expect(ambiguous.value["error"]["code"].string == "query_failed")
        #expect(ambiguous.value["engine_message"].string?.contains("exactly one") == true)
        let invalid = await tools.call("query_document", arguments: .object([
            "document_id": id, "selector": .string("heading.where(level: "),
        ]), access: access)
        #expect(invalid.value["error"]["code"].string == "query_failed")
    }

    @Test func agentEditorContextReflectsNativeCursorSelectionAndLayout() async throws {
        let app = try WritingFixture(text: "= Context fixture\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let text = "= Draft\nFirst line\nSecond 中文 line\nThird\n"
        let document = try await workspace.library.store.create(title: "Context", text: text)
        let other = try await workspace.library.store.create(title: "Closed", text: "Private\n")
        let tools = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let access = AgentToolAccess(documentIDs: nil, canWrite: false)
        func context(_ document: LibraryDocument) async -> AgentToolResult {
            await tools.call(
                "get_editor_context",
                arguments: .object(["document_id": .string(document.id.uuidString)]),
                access: access,
            )
        }
        #expect(await context(document).value["error"]["code"].string == "document_not_open")
        try await workspace.library.open(document.id)
        await app.layout()
        let editor = try #require(workspace.editor)
        workspace.layout = .split
        await app.layout()
        editor.setSelectedRange((editor.string as NSString).range(of: "中文 line"))
        try workspace.previewReading.observe(#require(PreviewReadingAnchor(page: 1, x: 0.5, y: 0.2, viewportY: 0)))
        let result = await context(document)
        #expect(!result.isError, "\(result.value)")
        #expect(result.value["active_path"].string == "main.typ")
        #expect(result.value["layout"].string == "split")
        #expect(result.value["preview_page"].int == 2)
        #expect(result.value["selection"]["text"].string == "中文 line")
        #expect(result.value["selection"]["range"]["start"]["line"].int == 2)
        #expect(result.value["selection"]["range"]["start"]["character"].int == 7)
        #expect(result.value["cursor"]["line_number"].int == 3)
        #expect(result.value["visible_lines"]["first_line_number"].int == 1)
        #expect((result.value["visible_lines"]["last_line_number"].int ?? 0) >= 4)
        #expect(result.value["unsaved"].foundationValue as? Bool == false)
        let read = await tools.call("read_file", arguments: .object([
            "document_id": .string(document.id.uuidString), "path": .string("main.typ"),
        ]), access: access)
        #expect(result.value["revision"].string == read.value["revision"].string)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        workspace.layout = .writing
        let caret = await context(document)
        #expect(caret.value["selection"].isNull)
        #expect(caret.value["cursor"]["position"]["character"].int == 2)
        #expect(caret.value["preview_page"].isNull)
        #expect(await context(other).value["error"]["code"].string == "document_not_open")
        let scoped = await tools.call(
            "get_editor_context",
            arguments: .object(["document_id": .string(document.id.uuidString)]),
            access: AgentToolAccess(documentIDs: [other.id], canWrite: false),
        )
        #expect(scoped.value["error"]["code"].string == "permission_denied")
    }

    @Test func mcpHelperReturnsRenderedPagesAsImageContent() async throws {
        let app = try WritingFixture(text: "= Helper render\n", startService: false)
        defer { app.close() }
        let document = try await app.workspace.library.store.create(
            title: "Rendered",
            text: "#set page(width: 120pt, height: 80pt)\nHello\n",
        )
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
            "params": .object(["name": .string("render_page"), "arguments": .object([
                "document_id": .string(document.id.uuidString), "ppi": .number(72),
            ])]),
        ]))
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode(JSONValue.self, from: data)["result"]
        #expect(result["isError"].foundationValue as? Bool == false, "\(result)")
        #expect(result["structuredContent"]["page_count"].int == 1)
        let content = result["content"].array.first { $0["type"].string == "image" }
        #expect(content?["mimeType"].string == "image/png")
        let png = content?["data"].string.flatMap { Data(base64Encoded: $0) }
        #expect(png.flatMap(NSBitmapImageRep.init(data:))?.pixelsWide == 120)
    }
}
