# Installed app or Swift test host, real MCP helper and bundled authoring files.

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
header "Mcp-Session-Id" exists
jsonpath "$.result.protocolVersion" == "2025-11-25"
jsonpath "$.result.capabilities.tools.listChanged" == true
jsonpath "$.result.capabilities.resources" exists
jsonpath "$.result.capabilities.prompts" exists

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

