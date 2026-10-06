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
[Asserts]
jsonpath "$.result.protocolVersion" == "2025-11-25"
jsonpath "$.result.capabilities.tools" exists

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
