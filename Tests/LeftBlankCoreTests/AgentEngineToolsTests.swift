import Foundation
@testable import LeftBlankCore
import Testing
import UniformTypeIdentifiers

@MainActor
struct AgentEngineToolsTests {
    @Test func renderPageValidatesArgumentsAndReturnsTheRequestedPage() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Render", text: "= Pages\n")
        let id = JSONValue.string(document.id.uuidString)
        let pages = try [#require(testImage(width: 6, height: 4, type: .png)),
                         #require(testImage(width: 3000, height: 1000, type: .png))]
        fixture.host.exportOutput = { export in
            guard case let .png(page, _) = export else {
                return AgentEngineOutput(status: .engineUnavailable)
            }
            let items: [JSONValue] = page <= pages.count ? [.object([
                "page": .number(Double(page - 1)),
                "data": .string(pages[page - 1].base64EncodedString()),
            ])] : []
            return AgentEngineOutput(
                status: .completed,
                response: .object(["total_pages": .number(Double(pages.count)), "items": .array(items)]),
                diagnostics: [.object(["severity": .string("warning")])],
            )
        }
        let revision = await fixture.call("get_document", ["document_id": id]).value["project_revision"]
        let first = await fixture.call("render_page", ["document_id": id])
        #expect(!first.isError)
        #expect(fixture.host.exports == [.png(page: 1, ppi: 144)])
        #expect(first.images == [AgentToolImage(data: pages[0], mimeType: "image/png")])
        #expect(first.value["page"].int == 1 && first.value["page_count"].int == 2)
        #expect(first.value["width"].int == 6 && first.value["height"].int == 4)
        #expect(first.value["downscaled"].foundationValue as? Bool == false)
        #expect(first.value["status"].string == "unverified")
        #expect(same(first.value["compiled_project_revision"], revision))
        #expect(first.value["is_current"].foundationValue as? Bool == true)
        #expect(first.value["diagnostics"].array.count == 1)
        let large = await fixture.call(
            "render_page",
            ["document_id": id, "page": .number(2), "ppi": .number(288), "expected_project_revision": revision],
        )
        #expect(fixture.host.exports.last == .png(page: 2, ppi: 288))
        #expect(large.value["width"].int == AgentImage.maximumEdge)
        #expect(large.value["downscaled"].foundationValue as? Bool == true)
        let beyond = await fixture.call("render_page", ["document_id": id, "page": .number(3)])
        #expect(beyond.isError && beyond.images.isEmpty)
        #expect(beyond.value["error"]["code"].string == "page_out_of_range")
        #expect(beyond.value["page_count"].int == 2)
        let calls = fixture.host.exports.count
        for invalid: [String: JSONValue] in [["page": .number(0)], ["ppi": .number(500)], ["ppi": .number(1.5)],
                                             ["scale": .number(2)]]
        {
            let result = await fixture.call("render_page", invalid.merging(["document_id": id]) { $1 })
            #expect(result.value["error"]["code"].string == "invalid_params")
        }
        let stale = await fixture.call(
            "render_page",
            ["document_id": id, "expected_project_revision": .string("old")],
        )
        #expect(stale.value["error"]["code"].string == "revision_conflict")
        #expect(fixture.host.exports.count == calls)
        fixture.host.exportOutput = { _ in AgentEngineOutput(
            status: .failed,
            message: "export.rs: document is not available for export: \"error: unclosed delimiter\"",
            diagnostics: [.object(["severity": .string("error")])],
        ) }
        let broken = await fixture.call("render_page", ["document_id": id])
        #expect(broken.isError && broken.value["error"]["code"].string == "compile_failed")
        #expect(broken.value["status"].string == "failed")
        #expect(broken.value["engine_message"].string?.contains("unclosed delimiter") == true)
        #expect(broken.value["diagnostics"].array.count == 1)
        fixture.host.exportOutput = { _ in AgentEngineOutput(status: .timeout) }
        #expect(await fixture.call("render_page", ["document_id": id]).value["error"]["code"].string == "timeout")
        fixture.host.exportOutput = { _ in AgentEngineOutput(status: .completed, response: .object([
            "total_pages": .number(1),
            "items": .array([.object(["page": .number(0), "data": .string(Data("text".utf8).base64EncodedString())])]),
        ])) }
        #expect(await fixture.call("render_page", ["document_id": id]).value["error"]["code"].string == "not_image")
        let denied = await fixture.dispatcher.call(
            "render_page",
            arguments: .object(["document_id": id]),
            access: AgentToolAccess(documentIDs: [], canWrite: false),
        )
        #expect(denied.value["error"]["code"].string == "permission_denied")
    }

    @Test func queryDocumentPagesMatchesAndRejectsUnsafeArguments() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Query", text: "= Items\n")
        let id = JSONValue.string(document.id.uuidString)
        let matches: JSONValue = .array(["A", "B", "C"].map { .object(["id": .string($0)]) })
        fixture.host.exportOutput = { export in
            guard case let .query(_, _, one) = export else {
                return AgentEngineOutput(status: .engineUnavailable)
            }
            let value = one ? matches.array[0] : matches
            let data = (try? AgentTools.canonical(value)) ?? Data()
            return AgentEngineOutput(status: .completed, response: .object([
                "data": .string(data.base64EncodedString()),
            ]))
        }
        var arguments: [String: JSONValue] = [
            "document_id": id,
            "selector": .string("<item>"),
            "field": .string("value"),
            "limit": .number(2),
        ]
        let first = await fixture.call("query_document", arguments)
        #expect(!first.isError)
        let export = AgentEngineExport.query(selector: "<item>", field: "value", one: false)
        #expect(fixture.host.exports == [export])
        #expect(export.command == "tinymist.exportQuery")
        #expect(export.options["format"].string == "json" && export.options["field"].string == "value")
        #expect(AgentEngineExport.query(selector: "heading", field: nil, one: true).options["field"].isNull)
        #expect(same(AgentEngineExport.png(page: 3, ppi: 72).options["pages"], .array([.string("3")])))
        #expect(same(first.value["items"], .array(Array(matches.array.prefix(2)))))
        #expect(first.value["count"].int == 3)
        #expect(first.value["truncated"].foundationValue as? Bool == true)
        #expect(first.value["status"].string == "unverified")
        arguments["cursor"] = first.value["next_cursor"]
        let second = await fixture.call("query_document", arguments)
        #expect(same(second.value["items"], .array([matches.array[2]])))
        #expect(second.value["next_cursor"].isNull)
        try Data("= Changed\n".utf8).write(to: document.sourceURL)
        #expect(await fixture.call("query_document", arguments).value["error"]["code"].string == "cursor_expired")
        let one = await fixture.call(
            "query_document",
            ["document_id": id, "selector": .string("heading"), "one": .bool(true)],
        )
        #expect(same(one.value["value"], matches.array[0]))
        #expect(one.value["items"].isNull)
        let calls = fixture.host.exports.count
        for invalid: [String: JSONValue] in [
            ["selector": .string(" ")],
            ["selector": .string(String(repeating: "a", count: 2001))],
            ["selector": .string("<item>"), "field": .string("value); read(\"x\")")],
            ["selector": .string("<item>"), "one": .string("yes")],
        ] {
            let result = await fixture.call("query_document", invalid.merging(["document_id": id]) { $1 })
            #expect(result.value["error"]["code"].string == "invalid_params")
        }
        #expect(fixture.host.exports.count == calls)
        fixture.host.exportOutput = { _ in AgentEngineOutput(
            status: .failed,
            message: "failed to retrieve: failed to evaluate selector: unknown variable: nope",
        ) }
        let rejected = await fixture.call("query_document", ["document_id": id, "selector": .string("nope")])
        #expect(rejected.isError && rejected.value["error"]["code"].string == "query_failed")
        #expect(rejected.value["engine_message"].string?.contains("unknown variable") == true)
    }

    @Test func editorContextDescribesOnlyAnOpenAuthorizedDocument() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let text = "Line one\nSecond 中文 line\nThird\n"
        let document = try await fixture.library.create(title: "Context", text: text)
        let id = JSONValue.string(document.id.uuidString)
        #expect(await fixture.call("get_editor_context", ["document_id": id]).value["error"]["code"]
            .string == "document_not_open")
        let second = (text as NSString).range(of: "Second 中文")
        fixture.host.editorContext = AgentEditorContext(
            layout: "split",
            previewPage: 2,
            file: AgentEditorContext.File(
                path: "main.typ",
                text: text,
                selection: second,
                visible: NSRange(location: 0, length: (text as NSString).range(of: "Third").location),
                saved: true,
            ),
        )
        let context = await fixture.call("get_editor_context", ["document_id": id])
        #expect(!context.isError)
        #expect(context.value["active_path"].string == "main.typ")
        #expect(context.value["is_entry"].foundationValue as? Bool == true)
        #expect(context.value["layout"].string == "split" && context.value["preview_page"].int == 2)
        #expect(context.value["cursor"]["line_number"].int == 2)
        #expect(context.value["cursor"]["position"]["character"].int == 9)
        #expect(context.value["selection"]["text"].string == "Second 中文")
        #expect(context.value["selection"]["truncated"].foundationValue as? Bool == false)
        #expect(context.value["selection"]["range"]["start"]["line"].int == 1)
        #expect(context.value["visible_lines"]["first_line_number"].int == 1)
        #expect(context.value["visible_lines"]["last_line_number"].int == 2)
        #expect(context.value["unsaved"].foundationValue as? Bool == false)
        let read = await fixture.call("read_file", ["document_id": id, "path": .string("main.typ")])
        #expect(same(context.value["revision"], read.value["revision"]))
        let long = String(repeating: "长", count: AgentToolDispatcher.selectionLimit + 10)
        fixture.host.editorContext = AgentEditorContext(layout: "writing", previewPage: nil, file: .init(
            path: "main.typ",
            text: long,
            selection: NSRange(location: 0, length: long.utf16.count + 50),
            visible: nil,
            saved: false,
        ))
        let truncated = await fixture.call("get_editor_context", ["document_id": id])
        #expect(truncated.value["selection"]["text"].string?.count == AgentToolDispatcher.selectionLimit)
        #expect(truncated.value["selection"]["truncated"].foundationValue as? Bool == true)
        #expect(truncated.value["visible_lines"].isNull && truncated.value["preview_page"].isNull)
        #expect(truncated.value["unsaved"].foundationValue as? Bool == true)
        fixture.host.editorContext = AgentEditorContext(layout: "split", previewPage: 1, file: nil)
        let package = await fixture.call("get_editor_context", ["document_id": id])
        #expect(package.value["active_path"].isNull && package.value["selection"].isNull)
        #expect(package.value["active_file_in_project"].foundationValue as? Bool == false)
        let other = try await fixture.library.create(title: "Other", text: "Private\n")
        let denied = await fixture.dispatcher.call(
            "get_editor_context",
            arguments: .object(["document_id": .string(other.id.uuidString)]),
            access: AgentToolAccess(documentIDs: [document.id], canWrite: false),
        )
        #expect(denied.value["error"]["code"].string == "permission_denied")
        let state = await fixture.dispatcher.call(
            "get_app_state",
            arguments: .object([:]),
            access: AgentToolAccess(documentIDs: nil, canWrite: false),
        )
        let tools = state.value["available_tools"].array.compactMap(\.string)
        #expect(["render_page", "get_editor_context", "query_document"].allSatisfy(tools.contains))
    }

    @Test func engineToolsTakeTurnsWithCompiles() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Turns", text: "= Turns\n")
        #expect(await fixture.dispatcher.compiles.acquire(exclusive: true))
        let render = Task {
            await fixture.call("render_page", ["document_id": .string(document.id.uuidString)])
        }
        while fixture.dispatcher.compiles.waiters.count < 1 {
            await Task.yield()
        }
        #expect(fixture.host.exports.isEmpty)
        fixture.dispatcher.compiles.release(exclusive: true)
        #expect(await render.value.value["error"]["code"].string == "engine_unavailable")
        #expect(fixture.host.exports.count == 1)
    }
}

private func same(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    (try? AgentTools.canonical(lhs)) == (try? AgentTools.canonical(rhs))
}
