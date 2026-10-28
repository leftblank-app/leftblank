# Real MCP workflow: rejected imports publish nothing, then import, discover, repair and compile.

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 701,
  "method": "tools/call",
  "params": {
    "name": "import_project",
    "arguments": {
      "title": "Hurl rejected import sentinel",
      "entry": "missing.typ",
      "files": [
        {
          "path": "other.typ",
          "text": "Other"
        }
      ],
      "request_id": "hurl-import-rejected"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.structuredContent.error.code" == "invalid_project"
jsonpath "$.result.structuredContent.error.parameter" == "entry"
jsonpath "$.result.structuredContent.error.mutation_state" == "not_applied"
jsonpath "$.result.structuredContent.error.recovery.instructions" isString

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 702,
  "method": "tools/call",
  "params": {
    "name": "list_documents",
    "arguments": {
      "query": "Hurl rejected import sentinel"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.items" count == 0

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 703,
  "method": "tools/call",
  "params": {
    "name": "import_project",
    "arguments": {
      "title": "Hurl complete imported project",
      "entry": "book/main.typ",
      "files": [
        {
          "path": "book/main.typ",
          "text": "#include \"../chapters/intro.typ\"\n#image(\"../assets/pixel.png\", width: 10pt)\n"
        },
        {
          "path": "chapters/intro.typ",
          "text": "= Imported chapter\nHello 中文\n"
        },
        {
          "path": "assets/pixel.png",
          "data_base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        }
      ],
      "request_id": "hurl-import-complete"
    }
  }
}
HTTP 200
[Captures]
imported_document: jsonpath "$.result.structuredContent.document.document_id"
imported_revision: jsonpath "$.result.structuredContent.project_revision"
imported_metadata: jsonpath "$.result.structuredContent.document.metadata_revision"
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.status" == "applied"
jsonpath "$.result.structuredContent.document.entry" == "book/main.typ"
jsonpath "$.result.structuredContent.path_base" == "document_root"
jsonpath "$.result.structuredContent.files" count == 3

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 704,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{imported_document}}",
      "path": "main.typ"
    }
  }
}
HTTP 200
[Captures]
recovery_tool: jsonpath "$.result.structuredContent.error.recovery.next_calls[0].tool"
recovery_document: jsonpath "$.result.structuredContent.error.recovery.next_calls[0].arguments.document_id"
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.structuredContent.error.code" == "not_found"
jsonpath "$.result.structuredContent.error.path" == "main.typ"
jsonpath "$.result.structuredContent.error.path_base" == "document_root"
jsonpath "$.result.structuredContent.error.recovery.next_calls[0].tool" == "list_files"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 705,
  "method": "tools/call",
  "params": {
    "name": "{{recovery_tool}}",
    "arguments": {
      "document_id": "{{recovery_document}}"
    }
  }
}
HTTP 200
[Captures]
discovered_entry: jsonpath "$.result.structuredContent.items[?(@.path == 'book/main.typ')].path"
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.items" count == 3
jsonpath "$.result.structuredContent.items[?(@.path == 'book/main.typ')].path" == "book/main.typ"
jsonpath "$.result.structuredContent.items[?(@.path == 'document.json')]" not exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 706,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{imported_document}}",
      "path": "{{discovered_entry}}"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.text" contains "../chapters/intro.typ"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 707,
  "method": "tools/call",
  "params": {
    "name": "read_image",
    "arguments": {
      "document_id": "{{imported_document}}",
      "path": "assets/pixel.png"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.width" == 1
jsonpath "$.result.structuredContent.height" == 1
jsonpath "$.result.content[1].type" == "image"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 708,
  "method": "tools/call",
  "params": {
    "name": "compile_document",
    "arguments": {
      "document_id": "{{imported_document}}",
      "expected_project_revision": "{{imported_revision}}"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.project_sources_compiled" == true
jsonpath "$.result.structuredContent.is_current" == true

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 709,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{imported_document}}",
      "path": "book/main.typ",
      "max_lines": 0
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.structuredContent.error.code" == "invalid_params"
jsonpath "$.result.structuredContent.error.parameter" == "arguments.max_lines"
jsonpath "$.result.structuredContent.error.expected" isString

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 710,
  "method": "tools/call",
  "params": {
    "name": "trash_document",
    "arguments": {
      "document_id": "{{imported_document}}",
      "expected_metadata_revision": "{{imported_metadata}}",
      "request_id": "hurl-import-cleanup"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == false
