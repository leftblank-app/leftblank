# Real macOS MCP helper, Swift dispatcher and isolated DocumentLibrary. No mock server.

POST {{url}}
Content-Type: application/json
Accept: application/json, text/event-stream
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list"
}
HTTP 401

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
Origin: https://unexpected.example
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}
HTTP 403

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
Host: unexpected.example
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/list"
}
HTTP 403

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {
      "name": "leftblank-hurl",
      "version": "1"
    }
  }
}
HTTP 200
[Captures]
session: header "Mcp-Session-Id"
[Asserts]
header "Mcp-Session-Id" exists
jsonpath "$.result.protocolVersion" == "2025-11-25"
jsonpath "$.result.capabilities.tools.listChanged" == true
jsonpath "$.result.capabilities.resources" exists
jsonpath "$.result.capabilities.prompts" exists

# The session issued above is honoured; one from an earlier helper (app restart) gets 404.
POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
Mcp-Session-Id: {{session}}
{
  "jsonrpc": "2.0",
  "id": 41,
  "method": "tools/list"
}
HTTP 200
[Asserts]
jsonpath "$.result.tools" count == {{tool_count}}

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
Mcp-Session-Id: 00000000000000000000000000000000-0
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/list"
}
HTTP 404
[Asserts]
jsonpath "$.error.code" == -32001

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/list"
}
HTTP 200
[Asserts]
jsonpath "$.result.tools" count == {{tool_count}}
jsonpath "$.result.tools[?(@.name == 'str_replace')].inputSchema.properties.old_str" exists
jsonpath "$.result.tools[?(@.name == 'list_authoring_guides')]" not exists
jsonpath "$.result.tools[?(@.name == 'read_authoring_guide')]" not exists
jsonpath "$.result.ttlMs" not exists
jsonpath "$.result.cacheScope" not exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "tools/call",
  "params": {
    "name": "get_app_state",
    "arguments": {}
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.platform" == "macos"
jsonpath "$.result.structuredContent.mcp.connected" == true

# Standard prompts select a workflow; resources supply its bounded, read-only source files.
POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 601,
  "method": "prompts/list"
}
HTTP 200
[Captures]
illustration_prompt: jsonpath "$.result.prompts[?(@.name == 'xiaohei-illustrations')].name"
[Asserts]
jsonpath "$.result.prompts[?(@.name == 'xiaohei-illustrations')].arguments[0].name" == "request"
jsonpath "$.result.prompts[?(@.name == 'xiaohei-illustrations')].arguments[0].required" == true
jsonpath "$.result.prompts[?(@.name == 'general-authoring')].description" contains "Fallback"
jsonpath "$.result.ttlMs" not exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 602,
  "method": "resources/list"
}
HTTP 200
[Captures]
illustration_source: jsonpath "$.result.resources[?(@.name == 'xiaohei-illustrations/main.typ')].uri"
[Asserts]
jsonpath "$.result.resources[?(@.name == 'xiaohei-illustrations/guide.md')].mimeType" == "text/markdown"
jsonpath "$.result.resources[?(@.name == 'xiaohei-illustrations/license.txt')]" exists
jsonpath "$.result.ttlMs" not exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 603,
  "method": "prompts/get",
  "params": {
    "name": "{{illustration_prompt}}",
    "arguments": {
      "request": "为这一页做一张配图：反馈帮助改进设计。"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.messages[1].content.type" == "resource"
jsonpath "$.result.messages[1].content.resource.uri" == "leftblank://guides/xiaohei-illustrations/guide.md"
jsonpath "$.result.messages[1].content.resource.text" isString
jsonpath "$.result.messages[2].content.text" contains "反馈帮助改进设计"
jsonpath "$.result.messages[0].content.text" contains "feedback.typ"
jsonpath "$.result.resultType" not exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 604,
  "method": "resources/read",
  "params": {
    "uri": "{{illustration_source}}"
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.contents[0].uri" == "{{illustration_source}}"
jsonpath "$.result.contents[0].text" contains "#import"
jsonpath "$.result.ttlMs" not exists
jsonpath "$.result.resultType" not exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 605,
  "method": "resources/read",
  "params": {
    "uri": "leftblank://guides/xiaohei-illustrations/../catalog.json"
  }
}
HTTP 200
[Asserts]
jsonpath "$.error.code" == -32602

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 606,
  "method": "prompts/get",
  "params": {
    "name": "general-authoring",
    "arguments": {
      "request": "制作数学演示文稿"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.messages[1].content.resource.text" contains "https://typst.app/universe/"
jsonpath "$.result.messages[0].content.text" contains "research-notes.md"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 607,
  "method": "prompts/get",
  "params": {
    "name": "missing-guide",
    "arguments": {
      "request": "a"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.error.code" == -32602

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 608,
  "method": "prompts/get",
  "params": {
    "name": "{{illustration_prompt}}"
  }
}
HTTP 200
[Asserts]
jsonpath "$.error.code" == -32602

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 609,
  "method": "resources/templates/list"
}
HTTP 200
[Asserts]
jsonpath "$.result.resourceTemplates" count == 0

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "create_document",
    "arguments": {
      "title": "Hurl isolated document",
      "source": "Hello 中文\n",
      "request_id": "hurl-create"
    }
  }
}
HTTP 200
[Captures]
document: jsonpath "$.result.structuredContent.document.document_id"
[Asserts]
jsonpath "$.result.structuredContent.status" == "applied"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ"
    }
  }
}
HTTP 200
[Captures]
revision: jsonpath "$.result.structuredContent.revision"
[Asserts]
jsonpath "$.result.structuredContent.text" == "Hello 中文\n"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 81,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{document}}",
      "path": "missing.typ"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.structuredContent.error.code" == "not_found"
jsonpath "$.result.structuredContent.error.suggested_tool" == "list_files"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "tools/call",
  "params": {
    "name": "str_replace",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ",
      "old_str": "Hello",
      "new_str": "Updated",
      "expected_revision": "{{revision}}",
      "request_id": "hurl-edit"
    }
  }
}
HTTP 200
[Captures]
new_revision: jsonpath "$.result.structuredContent.files[0].after_revision"
before_version: jsonpath "$.result.structuredContent.files[0].before_version_id"
[Asserts]
jsonpath "$.result.structuredContent.status" == "applied"
jsonpath "$.result.structuredContent.files[0].save_status" == "saved"
jsonpath "$.result.structuredContent.files[0].diff.hunks[0].before_start_line" == 1
jsonpath "$.result.structuredContent.files[0].diff.hunks[0].text" == "-Hello 中文\n+Updated 中文\n"
jsonpath "$.result.structuredContent.files[0].diff.abbreviated" == false

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "tools/call",
  "params": {
    "name": "str_replace",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ",
      "old_str": "Hello",
      "new_str": "Updated",
      "expected_revision": "{{revision}}",
      "request_id": "hurl-edit"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.files[0].after_revision" == "{{new_revision}}"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "tools/call",
  "params": {
    "name": "str_replace",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ",
      "old_str": "Updated",
      "new_str": "Updated",
      "expected_revision": "{{revision}}",
      "request_id": "hurl-stale"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.structuredContent.error.code" == "revision_conflict"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.text" == "Updated 中文\n"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "tools/call",
  "params": {
    "name": "restore_file_version",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ",
      "version_id": "{{before_version}}",
      "expected_revision": "{{new_revision}}",
      "request_id": "hurl-restore"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.status" == "applied"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 14,
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": {
      "document_id": "{{document}}",
      "path": "main.typ"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.text" == "Hello 中文\n"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 15,
  "method": "tools/call",
  "params": {
    "name": "get_document",
    "arguments": {
      "document_id": "{{document}}"
    }
  }
}
HTTP 200
[Captures]
metadata_revision: jsonpath "$.result.structuredContent.metadata_revision"
[Asserts]
jsonpath "$.result.structuredContent.entry" == "main.typ"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 19,
  "method": "tools/call",
  "params": {
    "name": "render_page",
    "arguments": {
      "document_id": "{{document}}",
      "ppi": 72
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.page_count" == 1
jsonpath "$.result.structuredContent.mime_type" == "image/png"
jsonpath "$.result.content" count == 2
jsonpath "$.result.content[1].type" == "image"
jsonpath "$.result.content[1].mimeType" == "image/png"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 20,
  "method": "tools/call",
  "params": {
    "name": "query_document",
    "arguments": {
      "document_id": "{{document}}",
      "selector": "heading"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == false
jsonpath "$.result.structuredContent.count" == 0
jsonpath "$.result.structuredContent.items" count == 0

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 21,
  "method": "tools/call",
  "params": {
    "name": "get_editor_context",
    "arguments": {
      "document_id": "{{document}}"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.isError" == true
jsonpath "$.result.structuredContent.error.code" == "document_not_open"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
{
  "jsonrpc": "2.0",
  "id": 16,
  "method": "tools/call",
  "params": {
    "name": "trash_document",
    "arguments": {
      "document_id": "{{document}}",
      "expected_metadata_revision": "{{metadata_revision}}",
      "request_id": "hurl-trash"
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.structuredContent.document.trashed" == true

# 2026-07-28 clients skip initialize and require cache hints on list results.
POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: server/discover
{
  "jsonrpc": "2.0",
  "id": 17,
  "method": "server/discover",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.supportedVersions" includes "2026-07-28"
jsonpath "$.result.capabilities.tools" exists
jsonpath "$.result.capabilities.resources" exists
jsonpath "$.result.capabilities.prompts" exists

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: tools/list
{
  "jsonrpc": "2.0",
  "id": 18,
  "method": "tools/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.tools" count == {{tool_count}}
jsonpath "$.result.tools[*].name" includes "get_app_state"
jsonpath "$.result.ttlMs" == 0
jsonpath "$.result.cacheScope" == "private"

# The same authoring primitives use the current protocol response shapes.
POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: prompts/list
{
  "jsonrpc": "2.0",
  "id": 610,
  "method": "prompts/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.prompts[?(@.name == 'dimensional-drawing')]" exists
jsonpath "$.result.ttlMs" == 0
jsonpath "$.result.cacheScope" == "private"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: resources/list
{
  "jsonrpc": "2.0",
  "id": 611,
  "method": "resources/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.resources[?(@.name == 'general-authoring/main.typ')]" exists
jsonpath "$.result.ttlMs" == 0
jsonpath "$.result.cacheScope" == "private"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: resources/templates/list
{
  "jsonrpc": "2.0",
  "id": 612,
  "method": "resources/templates/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.resourceTemplates" count == 0
jsonpath "$.result.ttlMs" == 0
jsonpath "$.result.cacheScope" == "private"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: resources/read
Mcp-Name: leftblank://guides/general-authoring/guide.md
{
  "jsonrpc": "2.0",
  "id": 613,
  "method": "resources/read",
  "params": {
    "uri": "leftblank://guides/general-authoring/guide.md",
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.contents[0].text" contains "Typst Universe"
jsonpath "$.result.resultType" == "complete"
jsonpath "$.result.ttlMs" == 0
jsonpath "$.result.cacheScope" == "private"

POST {{url}}
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: prompts/get
Mcp-Name: dimensional-drawing
{
  "jsonrpc": "2.0",
  "id": 614,
  "method": "prompts/get",
  "params": {
    "name": "dimensional-drawing",
    "arguments": {
      "request": "画一个外壳"
    },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "leftblank-hurl",
        "version": "1"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
HTTP 200
[Asserts]
jsonpath "$.result.messages[1].content.resource.uri" == "leftblank://guides/dimensional-drawing/guide.md"
jsonpath "$.result.resultType" == "complete"
