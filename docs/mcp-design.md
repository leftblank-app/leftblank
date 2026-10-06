# LeftBlank MCP 设计

状态：已开始实现，尚未发布。设计与实现记录日期：2026-10-05。

本文定义 LeftBlank 可复用的 agent 文档工具、macOS MCP 接入方式、Rust 与 Swift 的边界，以及用户复制给 agent 的连接配置提示词。macOS 应用自带本机 MCP 服务，Codex、Claude Code 等外部 agent 负责理解请求和生成修改；应用负责可靠地读取、编辑、保存和编译文档。未来 macOS 与 iOS/iPadOS 内置 agent 直接复用同一套 Swift 工具，不依赖 MCP server。

## 目标与范围

LeftBlank 的技术内核是面向 Typst 的代码编辑器，用户体验仍围绕文章、书籍和排版组织。MCP 是已有编辑器能力的适配层。

首要工作流是：读取文档及错误 → 修改源码 → 编译指定版本 → 根据结果继续修复。支持文档管理，但不以扩充工具数量为目标。

首版交付面向本机运行的外部 agent 和 macOS 应用，不包括内置聊天或模型调用、远程公网访问、任意 shell 执行、跨设备协同编辑、跨文件 ACID 事务。iOS/iPadOS 不集成 MCP server，这是本设计的平台边界；后续智能编辑通过内置 agent 接入共享工具服务。应用崩溃或同步故障也不是文档修复工具能够自动解决的问题。

本文保留完整设计目标；下节记录当前实现及尚未完成的验证，不能将设计承诺当作全部已交付。

## 当前实现状态

本次从 origin/main 的 `3b98e88` 开始实现：

- 共享 Swift 层提供 16 个工具的清单、schema 校验、dispatcher、版本检查、精确替换、patch、项目文件读取与搜索、文档管理和文件历史恢复。对外列表类结果统一放在 items；历史结果放在 versions，修改结果放在 files。
- macOS 层通过 Workspace 接入未保存 buffer、原生撤销、IME 与同步冲突保护。关闭的文件使用协调访问；单个编辑文件上限 2 MiB，项目读取上限 2000 项、单个资源 16 MiB、合计 64 MiB。超出上限明确报错。所有工具调用暂时串行，并发请求返回 busy。
- Rust helper 使用锁定的 rmcp 3.5.0，只承担 MCP transport、认证与私有 JSON 行协议。macOS 构建和签名脚本打包 helper；iPad 继续使用独立依赖图，CI 增加产物检查。
- 入口位于 **设置 → 编程智能体**：默认关闭；新启用的连接可读写文稿库里的所有文档（包括新建文稿），启用后复制配置提示词。设置页保留连接启停和复制提示词，删除文稿范围与只读权限选项。既有连接继续遵守已保存的权限，重新启用后采用新的完整文稿权限。状态表示本机服务已启用，不代表某个 agent 已完成连接。停用会撤销当前凭证，再次启用使用新凭证。配置不会同步到 iCloud。
- 写操作去重只保留当前 helper/dispatcher 生命周期内最近 256 个请求，按授权身份隔离；不承诺重启后或缓存过期后的 exactly-once。游标最多保留 128 个，服务重启后失效。

当前编译工具已经在独立目录捕获项目文件与实时 buffer，并启动全新的 Tinymist 实例，避免旧 PDF 混入结果。但外部包和系统字体尚未固定，因此即使产生有效 PDF，也返回 status=unverified、project_sources_compiled=true 与具体 limitation；无有效 PDF 返回 failed。这里还没有完成设计中的严格验证保证。缓存诊断暂时统一返回 freshness=unknown，原生诊断只保留起点时标明 range_is_point。

当前错误校验和 mutation 执行复用共享 dispatcher；业务 JSON 参数由同一份 schema 验证，尚未为每个工具分别建立 Codable 参数结构。返回 schema 当前为 object，具体结果字段见实现和测试。搜索超时或结果预算耗尽明确返回 incomplete，不保证一次覆盖大项目；查询结果在续页前变化会使游标失效。

本地验证覆盖共享工具工作流、真实 AppKit 编辑/撤销/历史、真实 MCP helper 的认证/发现/调用/重启/撤销，以及 Swift 包依赖图。Mac 完整回归通过，源码行覆盖率 86.12%；SwiftFormat、SwiftLint 和 Rust clippy 通过。iPad 模拟器 build-for-testing 及产物隔离检查通过，本次复用了源码和依赖输入完全相同的 Tinymist 静态库，没有重新构建引擎。

Hurl 已接入 GitHub CI，针对真实 helper、Swift dispatcher 和隔离文档库执行，不使用模拟服务；本机不执行 Hurl，本次尚未运行该 CI。Mac 本地 ad-hoc 打包通过；正式签名沙箱运行、iPad 真机及两个目标 coding agent 的实际配置提示词执行仍需相应 CI/客户端验收，不能只凭单元测试报告完成。

开发构建使用 `scripts/build.sh`，会构建并打包 Rust helper；直接 `swift build` 仅编译 Swift，不产生完整可连接的 app。调试时使用隔离文档库，不要把用户私有 connection.json 或 access.json 放进仓库。

## 现有能力

设计调研基于 `e05d4aa`，实现基线为 `3b98e88`；下表描述接入前的复用依据：

| 组件 | 可复用能力 | 接入时需要补齐 |
| --- | --- | --- |
| [DocumentLibrary](../Sources/LeftBlankCore/DocumentLibrary.swift) | UUID 文档身份、创建、读取、重命名、回收站和恢复 | 授权范围、对外版本、分页 |
| [Workspace](../Sources/LeftBlank/Workspace.swift) | 当前编辑 buffer、版本、编辑链路、诊断、PDF 编译 | 无需模拟 UI 操作的服务入口；明确异步结果版本 |
| [DocumentStorage](../Sources/LeftBlankCore/DocumentStorage.swift) | 文件协调、baseline 比较、原子单文件保存、iCloud 冲突保护 | 对外报告已应用与已保存的区别 |
| [TextEditing](../Sources/LeftBlankCore/TextEditing.swift) | 文本范围修改 | patch 与精确替换转换、统一校验 |
| [DocumentHistory](../Sources/LeftBlankCore/DocumentHistory.swift) | 单个源文件的有限历史快照 | agent 修改前的明确保存策略；删除文件的恢复路径 |
| [ProjectSources](../Sources/LeftBlankCore/ProjectSources.swift) | 项目内源文件发现与路径检查 | 对外文件清单、资源范围检查 |

当前只有一个活跃编辑 buffer；导航到章节文件时保留主编译入口。历史按源文件保存，不是完整项目备份。某些 Tinymist 诊断通知缺少版本，当前空诊断列表不能证明刚提交的版本编译成功。详见 [架构](architecture.md)与[文档历史](document-history.md)。

## 调研依据

| 项目 | 已公开的行为 | 对本设计的影响 |
| --- | --- | --- |
| [JetBrains MCP](https://www.jetbrains.com/help/idea/mcp-server.html#apply_patch) | 当前英文文档提供 Codex 风格 patch 和 unified Git diff 的 apply_patch，支持文件增删改及移动 | 对外采用 agent 熟悉的补丁格式；其文档没有替我们保证事务或冲突语义 |
| [LSP TextDocumentEdit](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/textDocumentEdit.md) | 对同一文档版本提交一组不重叠修改 | 统一内部编辑批次，所有位置基于同一快照 |
| [VS Code API](https://code.visualstudio.com/api/references/vscode-api#workspace.applyEdit) | 纯文本编辑采用全成或全败策略，混合文件操作有不同失败语义 | 分清预校验、buffer 应用与文件保存的保证 |
| [ACP 文件接口](https://agentclientprotocol.com/protocol/v1/file-system) | 读取包括未保存内容；write_text_file 接收全文 | 协议传输格式与编辑器应用方式可以分离 |
| [Zed 实现](https://github.com/zed-industries/zed/blob/96837d78cb0f2128c1965716f8df56b8aea59742/crates/acp_thread/src/acp_thread.rs#L6797) | 对 agent 快照与新全文计算 diff，转换为 anchors，通过 buffer 事务应用 | 修改必须进入编辑器状态；首版不照搬其并发 anchor 机制 |
| [Claude 编辑工具](https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool) | 精确文本替换要求唯一匹配，失败返回错误 | 保留简单的 str_replace 入口 |
| [Aider 编辑格式](https://aider.chat/docs/more/edit-formats.html) | 支持全文、SEARCH/REPLACE 和简化 diff | 多种输入格式共享一个执行层 |

MCP、ACP 和 LSP 解决不同层面的问题。本次外部接入实现 MCP；未来内置 agent 直接调用共享工具即可，不要求实现 MCP 或 ACP。只有需要连接独立的外部 agent 进程时，再评估 ACP。

## 平台边界与未来内置 agent

iOS/iPadOS 不按桌面模式安装、启动或管理供其他应用长期连接的本机 MCP server。这里不作“iOS 技术上无法使用 MCP”或“完全没有相关生态”的绝对判断；MCP 协议本身与是否部署桌面 helper 是两回事。Apple 的后台执行受系统调度和时限约束，不能据此承诺常驻服务。LeftBlank 因此将本机 MCP 接入限定在 macOS。[后台执行限制](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)、[后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

| 能力 | macOS | iOS/iPadOS |
| --- | --- | --- |
| 共享工具定义、参数、结果与文档业务 | 首版 MCP 复用；未来内置 agent 也复用 | 为未来内置 agent 复用，不依赖 MCP |
| Rust rmcp helper、MCP HTTP 与私有 IPC | macOS 专属适配层 | 不解析依赖、不编译、不链接、不打包 |
| MCP 启停、连接凭证、描述文件、复制配置提示词 | macOS 专属功能 | 不提供相应设置或资源 |
| 内置 agent 会话、模型调用与 tool calling | 后续独立设计 | 后续独立设计；进程内调用工具 |
| 原生 buffer、撤销、IME、引擎与生命周期 | Workspace / AppKit 适配 | TabletWorkspace / UIKit 适配 |

### 一份业务契约，两种调用入口

共享层提供与协议无关的 ToolDefinition、ToolDispatcher 和文档操作服务。工具名称、业务参数、结果、错误码、版本校验与恢复语义以本文为准，不为内置 agent 复制第二套 CRUD 或 patch 实现。具体模型提供方的 tool schema 与消息格式由 agent 适配层转换；MCP 的 annotations、structuredContent、isError 和 HTTP 会话只属于 MCP 适配层。

外部 MCP 请求和内置 agent 调用均经过同一个 dispatcher。调用上下文由可信宿主注入，包含会话身份、文档授权范围、读写权限、目标窗口/工作区以及取消信号，不能让模型通过 arguments 自行声明授权或选择更高权限。内置 agent 也必须遵守相同的路径限制、版本检查、输入法保护、编辑批次、保存与历史恢复规则。

首版 16 个工具作为共享业务契约设计；未来内置 agent 按宿主实际能力和用户授权获得可用子集，未实现的能力不得注册为可用。get_app_state 的公共结果包含 platform、应用身份、引擎状态、可用工具与已授权的打开文档；MCP 连接信息放在可选的 mcp 字段，iOS 省略该字段，不伪造 server 状态。安装和启停 MCP 属于 macOS 宿主功能，不增加为通用文档工具。

共享代码优先放在现有 LeftBlankCore，保持依赖方向为“macOS MCP 适配层 / 未来 agent 适配层 → 共享工具 → 文档服务”。共享层通过平台接口访问实时 buffer、原生撤销及引擎；不要直接依赖 AppKit 的 Workspace，也不要在 iOS 绕开 TabletWorkspace 直接覆盖磁盘文件。首版先实现 macOS 适配，iOS 适配随内置 agent 工作推进，不宣称当前已有同等工具能力。

### 构建与运行约束

沿用根目录 Package.swift 与 Sources/Package.swift 的独立构建边界：macOS target 才拥有 MCP 桥接、helper 管理和连接资源；iPad 的固定 core-only 依赖图不引入 MCP。不能只用运行时开关隐藏功能，也不能按执行 manifest 的宿主操作系统判断目标平台，因为 iOS 构建同样在 Mac 上解析 manifest。打包脚本也必须显式区分平台。

现有 iPad Tinymist Rust 静态库属于排版引擎，继续保留；本约束不禁止 Rust、Tokio 或引擎已有的本机预览通信。不得因为排版引擎已经使用 Rust，就顺便把 rmcp、MCP transport 或 server helper 合入 iOS 引擎产物。详见 [Mac/iPad 架构](ipad-architecture.md)。

未来内置 agent 的推理位置（设备端或远程）、模型提供方、凭证与会话 UI 单独设计，“内置 agent”不等于必须在设备上运行模型。工具执行仍在当前应用的文档服务内完成，不需要 localhost MCP、Rust helper 或 Swift MCP SDK。

iOS 内置 agent 首先按前台交互设计。进入后台时停止调度新的工具步骤，取消或暂停未完成推理，利用系统允许的时间完成必要保存并记录会话/操作状态。已应用的修改不因取消而假装未发生；恢复前台后重新检查文档版本和操作结果，不能盲目重放写请求。系统允许的后台任务可以后续专项评估，本设计不承诺持续后台运行。

## SDK 与进程结构

采用官方 [modelcontextprotocol/rust-sdk](https://github.com/modelcontextprotocol/rust-sdk)，crate 名为 `rmcp`。本文所称 Rust MCP server 指基于该 SDK 构建的 helper，不指另一个同名第三方项目。

调研时官方列表将 Rust 列为 Tier 1、Swift 列为 Tier 3。分级衡量协议覆盖、一致性测试与维护承诺，并不等同于模型编辑效果评分。选择 Rust 是为了协议支持和维护保障；文档业务继续使用现有 Swift 实现。[SDK 列表](https://modelcontextprotocol.io/docs/sdk)、[分级标准](https://modelcontextprotocol.io/community/sdk-tiers)

```mermaid
flowchart LR
    External[Mac 本机 coding agent] <-->|MCP Streamable HTTP| Rust[macOS Rust rmcp helper]
    Rust <-->|私有 stdin stdout 管道| MCP[macOS Swift MCP 适配层]
    MCP --> Dispatcher[共享 Swift ToolDispatcher]
    Embedded[未来 macOS / iOS 内置 agent] -.->|进程内调用| Dispatcher
    Dispatcher --> Service[共享文档操作服务]
    Service <--> Host[平台适配 Workspace / TabletWorkspace]
    Service <--> Library[文档库 保存 历史]
    Host <--> Native[原生编辑与 Tinymist]
```

上述 Rust helper、Swift MCP 适配层和 IPC 仅在 macOS 构建。macOS 应用启动和停止 helper，并与同版本 helper 一起发布。首版要求 LeftBlank 正在运行且用户已启用连接。helper 退出不影响写作；应用退出时关闭监听、结束待处理请求并清理子进程。

对 agent 暴露本机 Streamable HTTP。stdin/stdout 是应用与 helper 的私有 IPC，不是第二个外部 MCP stdio 服务。首版不增加客户端启动的代理进程，也不通过 C ABI 将 Tokio 嵌入 Swift。

### 职责边界

| Rust | Swift |
| --- | --- |
| MCP 生命周期、版本协商、工具发现与调用 | 工具描述和业务参数解码 |
| HTTP 连接、认证、协议错误 | 授权文档范围、路径和版本校验 |
| 通用请求转发、响应关联、取消传递 | patch 解析、文本替换、编辑与撤销 |
| 将内部结果封装为 MCP 结果 | 保存、恢复、诊断、编译与业务错误 |

Swift 不实现 MCP 握手或 HTTP 会话，Rust 不持有第二套文档状态，也不绕过 Swift 直接修改文档目录。MCP 的请求生命周期和业务执行状态通过 IPC 协调。

### 控制胶水代码

共享 Swift 层维护一份与 MCP 无关的工具清单，包含名称、说明、输入/输出 JSON Schema 和只读、破坏性等业务属性。macOS MCP 适配层将它们映射为 inputSchema、outputSchema 与 annotations，通过私有 IPC 启动握手发给 Rust。Rust 校验并缓存，准备完成后才接受外部 MCP 连接，通过通用 ServerHandler 暴露 tools/list 与 tools/call。首版清单在一个 helper 生命周期内固定；共享层不导入任何 MCP SDK。

Rust 透传 arguments JSON，无需为每个工具重复定义业务 struct。当前 Swift 从同一份 schema 校验 JSON 参数并分派给处理函数，避免第二份参数声明与 schema 不一致；必要时可再引入 Codable 参数结构，并增加一致性检查。首版不额外引入跨语言代码生成框架。

内部调用示意：

```json
{"id":17,"method":"str_replace","arguments":{"document_id":"doc-123","path":"main.typ","expected_revision":"file-r42","old_str":"szie: 12pt","new_str":"size: 12pt","request_id":"req-001"}}
```

IPC 使用 UTF-8、换行分帧 JSON；正文中的换行由 JSON 转义。日志只写 stderr。公共桥接层统一处理消息大小上限、并发请求关联、超时、取消、断线和协议版本不匹配。超时或断线不能被转换为“修改没有发生”，也不能自动重放写操作。Swift UI 修改在 MainActor 上执行，文件工作与昂贵计算尽量离开主线程。

新增工具通常只改工具清单、Swift handler 和契约测试，不改 Rust dispatcher。先构建签名及沙箱可运行的最小 helper 验证这条边界，再扩大工具范围。

## 工具协议

所有工具只操作服务端授权的文档。`document_id` 使用稳定 UUID；项目文件使用相对路径；标题变化不改变身份。只读工具明确标记，删除工具标记破坏性，但 annotations 只是客户端提示，不能代替服务端授权。

### 名称与参数的设计依据

工具名没有跨编辑器强制统一的标准。下表区分实际参考接口与 LeftBlank 的调整；沿用名称不表示完全兼容原工具，也不保证某个模型一定优先使用它。文档库、应用状态和历史版本属于 LeftBlank 自定义领域能力，不伪称为 IDE 标准接口。

| LeftBlank 接口 | 原始参考及参数 | 保留与调整 |
| --- | --- | --- |
| read_file | [JetBrains read_file](https://www.jetbrains.com/help/idea/mcp-server.html#read_file)：file_path、mode、start_line、max_lines；[Zed read_file](https://zed.dev/docs/ai/tools#read_file) | 保留工具名与行切片参数；统一路径字段为 path，省去多个相似定位模式；增加 document_id 与历史 version_id |
| list_files | [JetBrains search_file](https://www.jetbrains.com/help/idea/mcp-server.html#search_file)：q 为 glob，另有 paths、limit；[Zed find_path 与 list_directory](https://zed.dev/docs/ai/tools) | 合并列出与按文件名寻找；采用自定义的 list_files(path, glob, recursive, limit, cursor)，不另设 search_files |
| search_text | [JetBrains search_text / search_regex](https://www.jetbrains.com/help/idea/mcp-server.html#search_text)：q、paths、limit；[Zed grep](https://zed.dev/docs/ai/tools#grep) | 沿用 search_text 名称与 paths、limit；q 改成 query，literal/regex 用一个枚举；增加行上下文和分页 |
| str_replace | [Claude 编辑工具](https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool)：command=str_replace，path、old_str、new_str | 将该命令拆成独立 MCP 工具，保留这三个业务参数，移除冗余 command；增加文档身份、版本和请求 ID。不是复制其外层 str_replace_based_edit_tool |
| apply_patch | [JetBrains apply_patch](https://www.jetbrains.com/help/idea/mcp-server.html#apply_patch)：input、patch 别名、projectPath | 保留名称与主参数 input；不引入未发布接口的兼容别名；项目路径换为 document_id，补充文件前置版本 |
| get_diagnostics | [Zed diagnostics](https://zed.dev/docs/ai/tools#diagnostics)、[JetBrains get_file_problems](https://www.jetbrains.com/help/idea/mcp-server.html#get_file_problems) | 使用明确的读取动词；path 可选以支持文件或项目范围。LeftBlank 返回已有诊断与新鲜度，不宣称触发 IntelliJ 式实时检查 |
| compile_document | [JetBrains build_project](https://www.jetbrains.com/help/idea/mcp-server.html#build_project)：filesToRebuild、rebuild、timeout | 借鉴执行并等待验证的语义；Typst 总是围绕入口编译，采用 document_id 与 expected_project_revision，不照搬不适用的增量构建参数 |
| 文档库与历史工具 | LeftBlank DocumentLibrary 与 DocumentHistory | 按现有领域行为设计，明确与通用文件操作的区别 |

除沿用的 str_replace 外，名称采用动词在前的 snake_case。读取用 get/read/list/search，写操作用 create/rename/trash/restore。参数优先保持参考接口中适用的拼写，全局统一 path、document_id、limit、cursor 和版本字段，不为了逐字复制不同产品而混用 filePath、file_path、pathInProject。

### 首版工具

首个完整版本包含 16 个工具。按真实任务覆盖范围确定数量，不把所有 IDE 工具照搬过来。最小连通实验可以先实现子集，但不能把它称为完整编辑能力。

| 工具 | 主要输入 | 输出与语义 |
| --- | --- | --- |
| get_app_state | 无 | platform、应用版本、发行版、实例 ID、引擎状态、可用工具与能力、已授权的打开文档；可选 mcp 连接信息仅 macOS 提供 |
| list_documents | query?、include_trashed?、cursor?、limit? | 文档摘要与下一页游标；首版搜索范围明确为标题与主文件，不宣称全项目全文搜索 |
| get_document | document_id | 标题、metadata_revision、入口、项目版本、保存与冲突状态；文件树交给 list_files |
| create_document | title、source、request_id | 创建 main.typ 和文档身份，返回元数据与版本 |
| rename_document | document_id、title、expected_metadata_revision、request_id | 只修改标题 |
| trash_document | document_id、expected_metadata_revision、request_id | 放入回收站，保留项目；脏 buffer 或并发保存无法安全协调时拒绝 |
| restore_document | document_id、expected_metadata_revision、request_id | 恢复回收站文档 |
| list_files | document_id、path?、glob?、recursive?、limit?、cursor? | 列举源码与资源，按 glob 找文件；返回路径、类型、大小、下载状态及文本版本 |
| read_file | document_id、path、start_line?、max_lines?、version_id?、cursor? | 当前文本或指定历史文本、实际行范围、版本信息、总行数、truncated；cursor 续读字符上限截断的内容 |
| search_text | document_id、query、mode?、paths?、case_sensitive?、context_lines?、limit?、cursor? | 跨项目文本查找，返回匹配范围、上下文和文件版本 |
| str_replace | document_id、path、old_str、new_str、expected_revision、request_id | 一个唯一匹配的精确替换；多处修改使用 apply_patch |
| apply_patch | document_id、expected_revisions、input、request_id | 对项目提交文本文件 Add、Update、Delete 操作 |
| get_diagnostics | document_id、path?、severity?、limit?、cursor? | 文件、severity、message、range 与新鲜度；未知版本明确标记 |
| compile_document | document_id、expected_project_revision | 编译捕获的项目输入，返回状态、诊断、compiled_project_revision 和 is_current |
| list_file_versions | document_id、path | 已保留历史版本的 ID、日期、大小、原因；允许查询已删除文件，缺失历史明确返回 |
| restore_file_version | document_id、path、version_id、expected_revision、request_id | 恢复指定文件历史，先保护当前内容；null 前置版本要求文件不存在 |

`read_file` 优先读取实时 buffer，未打开文件走协调读取。行号从 1 开始；源码字符串不插入行号前缀，行号作为元数据提供。读取范围不会改变返回版本代表整个文件的含义。诊断 range 采用 0-based LSP 坐标并显式声明 `position_encoding: utf-16`。

read_file 的历史读取只返回 version_id 和不可变快照信息，不伪造可用于当前写入的 revision；写入前另读当前文件。首版只返回 UTF-8 文本，其他资源由 list_files 暴露元数据，不能把二进制内容当正文或返回为空。

### 通用参数与输出约定

这些默认值与上限是 LeftBlank 的设计选择，不是引用产品的默认值：

- list_files 默认 path 为项目根、glob 为 `**/*`、recursive 为 true。recursive=false 只返回直接子项；glob 在项目相对路径上匹配。稳定按 path 排序；不会暴露应用内部文件或跟随逃逸链接。
- search_text 默认 mode=literal、case_sensitive=true、context_lines=2；mode=regex 显式启用受限正则。paths 为可选项目相对 glob 数组，首版只支持包含模式，不支持混合 ! 排除语法。query 非空，正则有时间与输出预算，不提供正则替换。
- 文本搜索使用与 read_file 相同的 buffer 优先规则，覆盖 .typ、.bib、JSON、CSV 等项目 UTF-8 文本，不只查 main.typ。缺少 iCloud 文件、超出扫描预算或存在无法读取的文本时返回 incomplete 和具体原因，不能将“未扫描”当作“没有匹配”。
- 所有分页列表的 limit 默认 100、最大 500；read_file 的 max_lines 默认 200、最大 1000，另有字符上限以保护超长行。context_lines 最大 10。越界参数返回 invalid_params，不静默产生不可见行为变化。
- cursor 是不透明 token，绑定查询参数与快照；继续翻页时相关内容变化返回 cursor_expired。read_file 和列表均返回 next_cursor，所有截断明确标记 truncated。read_file 的 cursor 在字符上限截断一行时也能继续读取剩余内容，不能跳过整行；续读不可改变起始行或历史版本。每个结果还受总字节预算限制。
- get_diagnostics 的 severity 可选，值为 error/warning/info/hint，省略表示全部；每项返回该诊断的实际 severity。path 省略表示整个项目。
- 搜索范围与诊断都返回统一的 0-based UTF-16 range 和显式编码；面向人的 line_number 从 1 开始并单独命名，避免同一个 line 字段两种含义。
- 所有业务输入采用明确 object schema 和 additionalProperties=false。共享输出是业务结果，不包含 MCP 信封；MCP 适配层提供 outputSchema、structuredContent 和兼容的 JSON 文本内容。MCP 协议级取消、请求 ID 与工具业务 request_id 不混用；未来内置 agent 的 provider call ID 也不能取代业务 request_id。
- 修改结果包含每个文件的 before_revision、after_revision、before_version_id（如已保存恢复快照）、save_status 与有界 diff 摘要；不新增只为回显本次修改而存在的 get_diff 工具。去重与失败语义对所有写工具一致。

### 工作流完整性与不重复的边界

| 用户任务 | 工具组合 | 为什么不需要额外工具 |
| --- | --- | --- |
| 找到文档、章节或样式 | list_documents → get_document → list_files → search_text → read_file | 文档库查询、文件路径查询与正文搜索范围不同；文件名搜索已由 glob 覆盖 |
| 修复一处错误 | get_diagnostics → read_file → str_replace → compile_document | 局部修改格式简单，无需让模型算字符偏移 |
| 创建、修改或删除多个源码文件 | read_file → apply_patch → compile_document | 不再暴露 create_file、write_file、delete_file、insert_text、append_text 等同义写入口；Add 自动创建安全的父目录 |
| 改名或移动文本章节 | read_file → apply_patch 的 Add/Delete 与引用修改 → compile_document | 首版可以显式组合，不承诺语义重命名或透明 Move；复杂目录和二进制移动留待后续 |
| 查看并恢复错误修改 | list_file_versions → read_file(version_id) → restore_file_version → compile_document | 复用文件历史，不用不指定目标的 undo 撤销用户最近一次输入 |
| 管理整份文档 | create/rename/trash/restore_document | 文档包含身份、元数据和项目目录，不能由通用文件 patch 代替 |

str_replace 与 apply_patch 是有意保留的两种表达方式，复用同一个 EditBatch；不再加第三套全文写入或范围编辑入口。get_diagnostics 读取缓存状态，compile_document 执行严格验证，职责不同。get_document 只返回文档状态，list_files 只负责目录，不再重复返回整棵文件树。

“完整”在本版指文本项目的发现、读取、搜索、增删改、编译和文件级恢复闭环。页面视觉审查、二进制资源导入和最终文件导出是单独的出版工作流，不能被宣称已由源码工具覆盖；下文明确列出后续边界。

文档元数据版本、文件内容版本、项目版本和历史快照 ID 是不同概念，均不可相互代用。版本 token 由服务端产生，必须处理重启、磁盘变化和 iCloud 切换，不能直接暴露 Workspace 内部递增整数。

### 精确替换

```json
{
  "document_id": "doc-123",
  "path": "main.typ",
  "expected_revision": "file-r42",
  "old_str": "#set text(szie: 12pt)",
  "new_str": "#set text(size: 12pt)",
  "request_id": "req-001"
}
```

old_str 非空且必须唯一、精确匹配，包含空白。需要插入时替换包含锚点的上下文，删除时 new_str 为空。空文件填充或多处替换使用 apply_patch。失败不猜测位置、不模糊匹配，也不默认替换所有匹配。大文档不要求 agent 计算 UTF-16 偏移。

### 补丁

首版支持文档化的 Codex 风格 Add、Update、Delete 子集。Move、二进制文件、unified diff 后续按需要增加，暂不宣称完整兼容。补丁上下文和删除行必须精确匹配；`@@` 用于定位上下文，歧义返回错误。明确测试空文件、文件尾换行、CRLF 和同文件多个 hunk。

```json
{
  "document_id": "doc-123",
  "expected_revisions": {
    "main.typ": "file-r42",
    "chapters/intro.typ": null
  },
  "input": "*** Begin Patch\n*** Update File: main.typ\n@@\n-#set text(szie: 12pt)\n+#set text(size: 12pt)\n*** Add File: chapters/intro.typ\n+= 简介\n*** End Patch",
  "request_id": "req-002"
}
```

每个目标文件都必须声明前置条件；null 表示要求不存在。只处理授权项目内的 UTF-8 文本源文件与文本依赖，拒绝路径穿越、符号链接逃逸、应用元数据及历史目录。首版拒绝删除编译入口；项目内部文件 Delete 必须先持久化可恢复副本，并返回 before_version_id 供 restore_file_version 恢复，否则不执行删除。现有 DocumentHistory 主要存储源文件，扩展到 .bib、JSON 等文本依赖及已删除路径的身份校验属于实现工作，不能假设已有能力。

两个入口归一化为内部 EditBatch，再交给同一编辑服务。采用这个格式并不会自动重定向 agent 的内置文件工具；工具说明必须明确要求通过 LeftBlank MCP 修改其托管文档。

### 应用 保存与重试

先解析完整请求，检查路径、权限、所有版本、匹配、重叠和恢复条件，再开始应用。正式修改前重新校验版本，不能在异步计算与写入之间留下检查竞态。尊重 marked text，输入法组合期间返回可重试 busy，不打断用户输入。

单文件文本批次形成一次原生 undo group，沿现有编辑链路更新恢复数据、自动保存和 Tinymist。未打开文件经服务协调保存，不为执行 agent 请求强行切换当前编辑文件。

跨文件预校验失败时不修改任何文件；执行阶段或保存阶段仍可能部分失败。首版不承诺跨文件磁盘原子性或一次原生 Undo 撤销整个项目。

```json
{
  "request_id": "req-002",
  "status": "applied",
  "files": [
    {"path": "main.typ", "operation": "update", "before_revision": "file-r42", "after_revision": "file-r43", "before_version_id": "version-17", "save_status": "saved"},
    {"path": "chapters/intro.typ", "operation": "create", "before_revision": null, "after_revision": "file-r1", "before_version_id": null, "save_status": "saved"}
  ],
  "project_revision": "project-r88"
}
```

status 区分 rejected、applied、partially_applied。每个文件报告实际是否应用、当前版本、保存结果和相关错误。已应用但保存失败不能被描述成未修改；本机保存成功不表示 iCloud 已同步。

业务失败通过 MCP `isError: true` 和结构化错误返回；混合结果也保留逐文件状态。错误码包括 revision_conflict、text_not_found、ambiguous_match、overlapping_edits、invalid_patch、path_not_allowed、file_not_found、download_pending、unresolved_conflict、busy、save_failed、engine_unavailable、timeout、outcome_unknown。

request_id 在服务端按授权连接身份与请求参数摘要去重，拒绝同 ID 不同参数；运行中的重复请求不能再次执行。首版去重缓存有界，保证范围和期限通过连接能力说明公开。实例重启或缓存过期后的未知结果必须重新读取核实，不自动重放。跨重启 exactly-once 不在首版承诺内。

### 恢复与后续能力

复用原生撤销、文档历史和回收站；agent 覆盖或删除文本前保存文件快照，不依赖按小时采样一定保留修改前状态。恢复快照失败时拒绝修改。有限历史保留策略公开；版本过期返回 version_not_found，不宣称无限备份。

list_file_versions、read_file(version_id) 与 restore_file_version 在首版形成可供 agent 调用的恢复路径。恢复前必须匹配当前版本、先保留当前内容，且通过同一个编辑与保存服务应用；已删除文件以 expected_revision=null 恢复，不覆盖后来创建的同名文件。恢复一组文件仍可能部分失败，不承诺项目级一键撤回。

后续出版能力按任务引入，名称与参数为待验证提案，不提前加入 tools/list：

| 能力 | 拟议工具 | 独立存在的原因 |
| --- | --- | --- |
| 视觉验证 | render_page(document_id, compiled_project_revision, page) | 编译成功不能证明排版正确；返回同一编译产物的有界页面图片 |
| 导出 | export_document(document_id, format, expected_project_revision) | format 为 pdf/source/project；返回授权产物 resource link，不允许任意磁盘覆盖 |
| 图片等资源 | import_asset(document_id, path, content_base64, expected_revision, request_id) | patch 不承载二进制；大小、MIME 与覆盖规则单独定义，配套资源读取与删除也须一起设计 |

不添加万能 execute_action、任意 shell、整份项目 dump，或同时保留 edit_file/replace_text/str_replace 等同义别名。符号重命名、格式化、定义跳转需要 Tinymist 实际能力验证后才引入。完整文件替换若有必要，仍先算 diff 再进入 EditBatch。

维护规则：工具清单是唯一对外契约；新增可选参数保持原语义，已发布的名称、必填字段和默认行为变更必须有迁移策略。当前还未发布，直接统一名称并更新安装提示词，不保留旧草案别名。业务版本冲突与资源权限不能仅在某个工具里实现，所有写入口共用校验和执行服务。

此前讨论过 change_get、change_revert 和跨文件变更日志。它们列为后续增强，不属于首版工具承诺；只有实际的断线恢复与批次撤回需求证明必要时再增加。

## 编译与诊断

get_diagnostics 用于快速定位问题，返回 freshness 为 current、stale 或 unknown；没有版本的通知不能擅自标记 current。

compile_document 校验项目版本后捕获源码、未保存内容、项目内资源及影响编译的设置，使用与应用一致的引擎、字体和包解析上下文。编译期间外部包等输入也需固定或记录；无法建立稳定输入时返回无法验证，而不声称复现了指定版本。

项目版本表示这些已追踪输入的状态，不能只使用主文件版本。实现可以捕获独立快照或使用经验证的引擎版本屏障；具体机制需要 Tinymist 探针验证。现有 exportPdf 是起点，不是完整的多文件快照保证。

结果区分 succeeded、failed、timeout、engine_unavailable、unverified。编译完成期间用户继续编辑，则 compiled_project_revision 保留实际输入版本，is_current 为 false。不能复用旧 PDF 或“诊断为空”报告成功。编译失败不会自动回滚有效提交，agent 可继续修复。

## 本机连接与发行（仅 macOS）

服务仅监听 127.0.0.1。用户启用连接时选择授权范围与读写权限，应用生成高熵连接凭证；Rust 验证凭证，Swift 再按绑定的授权上下文校验文档范围。session ID、request_id 和 document_id 都不是凭证。

校验 HTTP Origin，并检查 Host；拒绝意外来源和重定向泄露凭证。MCP transport 的认证细节随所选稳定版本验证，不向 agent 暴露无认证的文档接口。[传输要求](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

首次启用时分配可用端口并持久化，后续重启优先使用相同端口；冲突时明确报告并要求更新连接，不静默切换到旧配置仍指向的其他服务。凭证可撤销和轮换，不随每次启动变化。首次发行前验证本机 HTTP 和客户端凭证注入的实际兼容性。

Standard 与 Preview 使用独立连接名称、监听端口、凭证和实例标识，例如 leftblank 与 leftblank-preview。两者可能访问同一 iCloud 文档库，发行版隔离不能被当成内容并发隔离；仍须协调文件访问和检查版本。

helper 随 app 打包、签名和发布，锁定依赖并纳入第三方许可。用户无需安装 Rust、Cargo、Node 或 Python。App Sandbox 下的子进程继承、管道、网络权限和签名必须在真实打包产物上验证。

## 复制给 coding agent 的配置提示词

### 用户流程

仅在 macOS 设置页的“编程智能体”区块提供连接入口：选择文档范围及读写权限 → 启用服务 → 复制配置提示词 → 粘贴到本机 Codex 或 Claude Code。无需在 Documents 菜单设置独立入口。

这里的“安装”是向客户端注册应用已自带的 MCP 服务。首版要求 agent 与 LeftBlank 位于同一台 Mac；远程主机或云端 agent 的 127.0.0.1 不指向用户的 Mac，不能宣称可以直接接入。

服务就绪时，应用在本机私有状态目录原子写入一个连接描述文件；复制提示词时填入该文件的真实绝对路径。描述文件与父目录限制为当前用户可读写；其中包含凭证，不能同步到 iCloud、写进项目仓库或直接复制到聊天正文。停用会撤销服务端凭证并删除描述文件；客户端的旧配置由用户或 agent 清理，应用不直接改写其他客户端配置。

描述文件的提议结构如下，值由运行中的应用生成；占位符不是可用配置：

```json
{
  "format_version": 1,
  "server_name": "leftblank",
  "app_bundle_id": "app.leftblank.writer",
  "app_version": "<installed-version>",
  "instance_id": "<running-instance-id>",
  "transport": "streamable-http",
  "url": "http://127.0.0.1:<allocated-port>/mcp",
  "authentication": {
    "type": "bearer",
    "token": "<local-secret>"
  }
}
```

描述文件只提供数据，不包含任意可执行命令。客户端 agent 通过本地程序解析并写配置，不把整个文件或 token 打印进工具输出。静态 Authorization header 是兼容基线，只写入用户私有配置；客户端支持安全的凭证引用或 helper 时可使用。不能仅在临时 shell 中 export token 就认为桌面客户端重启后仍能连接。

### 可复制提示词模板

应用必须替换以下所有双花括号字段；若连接未启用或描述文件不存在，应引导启用，而不是复制不可执行的模板。

```text
请帮我把这台 Mac 上的 {{app_name}} MCP 服务配置到你当前使用的 coding agent 客户端。

应用已经自带服务，不需要下载 MCP server、克隆源码或安装 Rust/Cargo/Node/Python。应用需保持运行，并已由我启用连接和文档访问范围。

连接信息文件：{{connection_descriptor_absolute_path}}
预期应用标识：{{app_bundle_id}}
预期服务名称：{{server_name}}
官方参考：
- Codex：https://developers.openai.com/codex/mcp
- Claude Code：https://code.claude.com/docs/en/mcp

请执行配置和验证：
1. 确认你在同一台 Mac 上执行，并识别当前客户端及其实际配置位置；不要猜测端口、应用路径或 CLI 参数。无法判断目标客户端时再向我询问。
2. 使用本地程序读取上述描述文件，校验版本、应用标识、服务名称以及 URL 的主机确为 127.0.0.1。文件含连接凭证，不要将全文、token 或带凭证的命令打印到聊天、日志或终端输出。
3. 按当前客户端支持的方式，在用户私有范围新增或更新该服务。保留其他配置及其他 MCP 服务；已有相同配置则复用。有同名但不同应用的连接时报告冲突。凭证不要写入项目共享配置或 Git；不要更改全局审批、安全或信任设置。
4. 连接方式是 Streamable HTTP，凭证从文件读取并通过 Authorization Bearer 使用。确保凭证配置在客户端重新启动后仍生效。环境变量方式只有在实际客户端进程能持续获得变量时才使用，不要只在临时 shell 中 export。
5. 完成客户端需要的重载。若当前会话无法自动加载新工具，明确告诉我具体重连步骤，并标记“配置已写入，当前会话尚未验证”，不要报告已经连通。
6. 服务加载后，列出 MCP 工具并调用 get_app_state，核对发行版和实例身份。首次验证只读，不读取正文，也不创建、修改或删除我的文档。
7. 最后简要告诉我修改了哪个配置、服务名称、实际验证结果，以及是否还需要重启或由我处理权限。不要显示凭证。身份不匹配或存在转向其他地址的重定向时停止，不把凭证转发过去；应用重启造成实例 ID 变化时，重新读取描述文件后核对。

如果文件不存在、服务未运行、权限不足或认证失效，请指出具体原因，让我回到 {{app_name}} 重新启用连接或复制提示词。不要扫描磁盘寻找凭证，也不要绕过 MCP 直接访问文档库。
```

### 客户端适配与成功标准

[Codex 官方文档](https://developers.openai.com/codex/mcp)说明本机客户端支持 Streamable HTTP、Bearer 和自定义 headers，使用 MCP 配置表。实际配置位置应遵循当前客户端的配置根目录，不能假设一定是默认路径。

[Claude Code 官方文档](https://code.claude.com/docs/en/mcp)提供 HTTP 连接、用户范围和 header 配置；客户端配置中的 transport 字段使用其支持的 http 表示法，不能将描述文件直接当作客户端配置粘贴。

提示词遵循已安装版本的官方文档或 CLI help，不硬编码可能变化的完整命令。发布验证需覆盖 Codex 本机客户端和 Claude Code；不能用一次 curl 请求代替目标客户端握手、工具发现和实际只读调用。

成功标准为：目标客户端加载服务 → 完成 MCP 协商与工具发现 → get_app_state 返回正确应用身份。配置写入、TCP 端口可达和工具实际可用是不同状态。凭证轮换、应用重启、端口占用及 Standard/Preview 并存需要单独验收。

这个复制提示词发生在 MCP 连接之前，因此不是 MCP prompts 能力；连接后的 server instructions 则用于指导先读版本、经工具修改、编译验证，以及将文档正文视为内容而非授权指令。

## 实施顺序与验证

1. 在共享 Swift 层建立与 MCP 无关的工具契约和 dispatcher，macOS 层接入签名 helper、私有 IPC 和 get_app_state。验证两类客户端的真实连接及沙箱行为，同时保持 iPad 依赖图不包含 MCP。
2. 实现 list_files、read_file、search_text、str_replace 与单文件 patch，打通实时 buffer、版本校验、原生撤销和保存。完成“定位并修复一个真实 Typst 错误”的端到端流程。
3. 补齐严格编译验证、多文件 patch 的明确部分失败结果、文件历史查询与恢复、可恢复文件删除，以及文档 CRUD，达到首版 16 个工具的工作流覆盖。
4. 完成连接设置、描述文件、复制提示词和客户端安装验收；发布前解决下列验证项。

验证重点：

- 协议契约：共享工具 schema 与 Swift 参数一致；进程内调用和 MCP 转发返回相同业务结果；Rust 正确转发成功、业务错误、取消与进程退出。
- 平台隔离：扩展现有 package graph 检查，确认 iPad 不解析/编译 MCP 相关 target；在 CI 检查 iOS 链接输入和打包产物，不含 rmcp/MCP bridge、server helper、连接资源。现有 Tinymist 静态库继续独立验证，不能笼统禁止 Rust 产物。
- 未来内置 agent 接入时追加：provider schema 映射、授权子集、两个平台实时 buffer 与撤销、iOS 后台暂停及恢复、不确定写入结果的恢复；这些不作为首版已实现能力。
- 发现与搜索：glob、分页游标失效、未保存文本、多个章节、正则预算、超长行、下载未完成和部分扫描；各场景返回明确范围，不能漏结果却报告完整。
- 恢复：检查删除前版本可发现、可读、可恢复；拒绝覆盖同名新文件；历史过期与保存失败有确定结果。
- 编辑：中文、emoji、组合字符、CRLF、重复文本、空文件、EOF、多个 hunk、重叠和越界。
- 状态：未保存 buffer、用户同时输入、输入法组合、版本变化、撤销/重做、磁盘外部变化与 iCloud 冲突。
- 失败：安全快照失败、保存失败、批次中断、超时后结果未知、重复 request_id；不能重复应用。
- 编译：错误诊断、无版本通知、章节和资源变化、旧产物隔离、编译期间继续编辑。
- 连接：错误凭证、撤销、Origin/Host 校验、实例身份、重启、端口冲突、两个发行版并存、客户端配置保留。

HTTP 边界优先用 Hurl 在 GitHub CI 验证；编辑器行为用现有 Swift 原生集成测试，IPC 用独立测试进程。单元测试不连接真实数据库；测试使用隔离库与注入的云状态，不碰用户文档或真实 iCloud。遵循仓库约束：只有 GitHub CI 失败且需要验证修复时才在本机运行 Hurl 或 OrbStack；本方案不需要容器。

当前已验证项目源码快照编译、跨文件部分失败报告和文件历史恢复。发布前仍需完成外部包与字体的固定输入验证、正式签名沙箱中的 helper，以及桌面客户端持久凭证配置验收；当前状态以上文实现记录为准。
