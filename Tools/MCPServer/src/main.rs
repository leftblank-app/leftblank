//! macOS-only transport adapter. Swift owns schemas, authorization and document state.
use axum::{
    Router,
    body::Body,
    extract::{Request, State},
    http::{HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
};
use futures::{SinkExt, StreamExt};
use rmcp::{
    ErrorData, RoleServer, ServerHandler,
    model::*,
    service::{RequestContext, SubscriptionContext},
    transport::streamable_http_server::{
        StreamableHttpServerConfig, StreamableHttpService, session::local::LocalSessionManager,
    },
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use subtle::ConstantTimeEq;
use tokio::{
    net::TcpListener,
    sync::{mpsc, oneshot},
};
use tokio_util::{
    codec::{FramedRead, FramedWrite, LinesCodec},
    sync::CancellationToken,
};

const MAX_FRAME: usize = 8 * 1024 * 1024;
const MAX_BODY: usize = 4 * 1024 * 1024;
const SESSION_HEADER: &str = "mcp-session-id";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    bridge_version: u32,
    port: u16,
    token: String,
    tools: Vec<Tool>,
    instructions: String,
}

#[derive(Clone)]
struct Bridge {
    tools: Arc<Vec<Tool>>,
    instructions: Arc<String>,
    output: mpsc::Sender<String>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    serial: Arc<AtomicU64>,
    shutdown: CancellationToken,
}

// Cleaning up a dropped handler also covers transport cancellation and client disconnects.
struct PendingCall {
    id: u64,
    bridge: Bridge,
    finished: bool,
}
impl Drop for PendingCall {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.bridge.pending.lock() {
            pending.remove(&self.id);
        }
        if !self.finished {
            let _ = self
                .bridge
                .output
                .try_send(json!({"cancel": self.id}).to_string());
        }
    }
}

impl ServerHandler for Bridge {
    fn get_info(&self) -> ServerConfig {
        // The tool set is fixed for a helper's lifetime, but a restarted app may offer different
        // tools; listen streams announce that once (see `listen`).
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_tool_list_changed()
                .build(),
        )
        .with_server_info(Implementation::new("leftblank", env!("CARGO_PKG_VERSION")))
        .with_instructions(self.instructions.as_str())
    }
    async fn list_tools(
        &self,
        request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        if request.and_then(|r| r.cursor).is_some() {
            return Err(ErrorData::invalid_params("Unexpected cursor", None));
        }
        let result = ListToolsResult::with_all_items(self.tools.as_ref().clone());
        // 2026-07-28 makes ttlMs and cacheScope required; the tool set depends on the grant.
        Ok(match context.protocol_version() {
            Some(version) if version.as_str() >= ProtocolVersion::V_2026_07_28.as_str() => {
                result.with_ttl_ms(0).with_cache_scope(CacheScope::Private)
            }
            _ => result,
        })
    }
    fn accepted_subscription_filter(
        &self,
        _requested: &SubscriptionFilter,
    ) -> Option<SubscriptionFilter> {
        Some(SubscriptionFilter::builder().tools_list_changed().build())
    }
    async fn listen(&self, context: SubscriptionContext) -> Result<(), ErrorData> {
        // A new helper cannot know what a client cached from its predecessor (an app upgrade can
        // add tools), so every listen stream starts by asking the client to fetch tools/list again.
        if context.accepted().tools_list_changed == Some(true) {
            let _ = context.sink().notify_tool_list_changed().await;
        }
        tokio::select! {
            _ = context.cancelled() => {}
            _ = self.shutdown.cancelled() => {}
        }
        Ok(())
    }
    fn get_tool(&self, name: &str) -> Option<Tool> {
        self.tools.iter().find(|tool| tool.name == name).cloned()
    }
    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        if self.get_tool(&request.name).is_none() {
            return Err(ErrorData::invalid_params("Unknown tool", None));
        }
        let id = self.serial.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        {
            let mut pending = self
                .pending
                .lock()
                .map_err(|_| ErrorData::internal_error("Bridge unavailable", None))?;
            if pending.len() >= 32 {
                return Ok(CallToolResult::structured_error(
                    json!({"error":{"code":"busy","message":"Too many pending requests"}}),
                )
                .into());
            }
            pending.insert(id, sender);
        }
        let mut call = PendingCall {
            id,
            bridge: self.clone(),
            finished: false,
        };
        let frame = json!({"id": id, "method": request.name, "arguments": request.arguments.unwrap_or_default()}).to_string();
        self.output.send(frame).await.map_err(|_| {
            ErrorData::internal_error("Bridge disconnected; write result may be unknown", None)
        })?;
        let value = tokio::select! {
            result = receiver => result.map_err(|_| ErrorData::internal_error("Bridge disconnected; write result may be unknown", None))?,
            _ = context.ct.cancelled() => return Err(ErrorData::internal_error("Cancelled; check document state before retrying a write", None)),
            _ = self.shutdown.cancelled() => return Err(ErrorData::internal_error("Application closed; write result may be unknown", None)),
            _ = tokio::time::sleep(Duration::from_secs(90)) => return Ok(CallToolResult::structured_error(json!({"error":{"code":"timeout","message":"Result unknown. Read the document before retrying a write."}})).into()),
        };
        call.finished = true;
        let payload = value.get("value").cloned().unwrap_or(Value::Null);
        let mut result = if value
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(true)
        {
            CallToolResult::structured_error(payload)
        } else {
            CallToolResult::structured(payload)
        };
        // Swift prepares viewable images; the bridge only forwards known image types.
        for image in value
            .get("images")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let (Some(data), Some(mime_type)) = (
                image.get("data").and_then(Value::as_str),
                image.get("mime_type").and_then(Value::as_str),
            ) && ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(&mime_type)
            {
                result.content.push(ContentBlock::image(data, mime_type));
            }
        }
        Ok(result.into())
    }
}

async fn authenticate(
    State(token): State<Arc<String>>,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let supplied = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if !bool::from(supplied.as_bytes().ct_eq(token.as_bytes())) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(next.run(request).await)
}

/// Session IDs for initialize-based (pre-2026-07-28) clients. The service itself is stateless;
/// IDs only let clients notice a restart. They carry no authority: the bearer token does.
#[derive(Clone)]
struct Sessions {
    instance: Arc<String>,
    issued: Arc<AtomicU64>,
}

impl Sessions {
    fn new() -> std::io::Result<Self> {
        use std::io::Read;
        let mut bytes = [0u8; 16];
        std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
        Ok(Self {
            instance: Arc::new(bytes.iter().map(|b| format!("{b:02x}")).collect()),
            issued: Arc::new(AtomicU64::new(0)),
        })
    }
    fn issue(&self) -> String {
        format!(
            "{}-{}",
            self.instance,
            self.issued.fetch_add(1, Ordering::Relaxed)
        )
    }
    fn recognizes(&self, id: &str) -> bool {
        id.strip_prefix(self.instance.as_str())
            .and_then(|rest| rest.strip_prefix('-'))
            .and_then(|serial| serial.parse::<u64>().ok())
            .is_some_and(|serial| serial < self.issued.load(Ordering::Relaxed))
    }
}

/// 2026-07-28 removed sessions; earlier versions use them, and initialize carries no header.
fn uses_sessions(request: &Request) -> bool {
    request
        .headers()
        .get("mcp-protocol-version")
        .and_then(|v| v.to_str().ok())
        .is_none_or(|version| version < ProtocolVersion::V_2026_07_28.as_str())
}

/// Streamable HTTP requires 404 for an unknown session so the client initializes again. After an
/// app restart or upgrade that is how initialize-based clients rediscover the current tools.
async fn sessions(State(sessions): State<Sessions>, request: Request, next: Next) -> Response {
    if !uses_sessions(&request) {
        return next.run(request).await;
    }
    if let Some(id) = request.headers().get(SESSION_HEADER) {
        if id.to_str().is_ok_and(|id| sessions.recognizes(id)) {
            return next.run(request).await;
        }
        let body = json!({"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Session not found"}});
        return (
            StatusCode::NOT_FOUND,
            [(header::CONTENT_TYPE, "application/json")],
            body.to_string(),
        )
            .into_response();
    }
    if request.method() != Method::POST {
        return next.run(request).await;
    }
    let (parts, body) = request.into_parts();
    let Ok(bytes) = axum::body::to_bytes(body, MAX_BODY).await else {
        return StatusCode::PAYLOAD_TOO_LARGE.into_response();
    };
    let initialize = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .is_some_and(|message| message.get("method") == Some(&json!("initialize")));
    let mut response = next
        .run(Request::from_parts(parts, Body::from(bytes)))
        .await;
    if initialize
        && response.status() == StatusCode::OK
        && let Ok(id) = HeaderValue::from_str(&sessions.issue())
    {
        response.headers_mut().insert(SESSION_HEADER, id);
    }
    response
}

fn router(bridge: Bridge, token: &str, port: u16, sessions_state: Sessions) -> Router {
    let mut settings = StreamableHttpServerConfig::default()
        .with_json_response(true)
        .enforce_origin_validation();
    settings.legacy_session_mode = false;
    settings.allowed_hosts = vec![format!("127.0.0.1:{port}")];
    settings.allowed_origins = vec![format!("http://127.0.0.1:{port}")];
    settings.cancellation_token = bridge.shutdown.clone();
    settings.max_request_body_bytes = MAX_BODY;
    let service = StreamableHttpService::new(
        move || Ok(bridge.clone()),
        Arc::new(LocalSessionManager::default()),
        settings,
    );
    // Layers run outside-in: authenticate before session handling reveals anything.
    Router::new()
        .nest_service("/mcp", service)
        .layer(middleware::from_fn_with_state(sessions_state, sessions))
        .layer(middleware::from_fn_with_state(
            Arc::new(format!("Bearer {token}")),
            authenticate,
        ))
}

#[tokio::main(worker_threads = 2)]
async fn main() {
    if run().await.is_err() {
        // Never log configuration, bearer credentials, request arguments or document contents.
        eprintln!("LeftBlank MCP helper could not start or lost its application connection.");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = FramedRead::new(
        tokio::io::stdin(),
        LinesCodec::new_with_max_length(MAX_FRAME),
    );
    let line = tokio::time::timeout(Duration::from_secs(10), input.next())
        .await?
        .ok_or("missing configuration")??;
    let config: Configuration = serde_json::from_str(&line)?;
    if config.bridge_version != 1
        || config.token.len() != 64
        || !config.token.bytes().all(|b| b.is_ascii_hexdigit())
        || config.tools.is_empty()
        || config.tools.len() > 64
    {
        return Err("invalid configuration".into());
    }
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, config.port)).await?;
    let port = listener.local_addr()?.port();
    let shutdown = CancellationToken::new();
    let (output, mut outgoing) = mpsc::channel::<String>(64);
    let bridge = Bridge {
        tools: Arc::new(config.tools),
        instructions: Arc::new(config.instructions),
        output: output.clone(),
        pending: Arc::new(Mutex::new(HashMap::new())),
        serial: Arc::new(AtomicU64::new(1)),
        shutdown: shutdown.clone(),
    };
    let writer_shutdown = shutdown.clone();
    tokio::spawn(async move {
        let mut writer = FramedWrite::new(
            tokio::io::stdout(),
            LinesCodec::new_with_max_length(MAX_FRAME),
        );
        while let Some(line) = outgoing.recv().await {
            if writer.send(line).await.is_err() {
                break;
            }
        }
        writer_shutdown.cancel();
    });
    let reader_bridge = bridge.clone();
    tokio::spawn(async move {
        while let Some(Ok(line)) = input.next().await {
            let Ok(reply) = serde_json::from_str::<Value>(&line) else {
                break;
            };
            let Some(id) = reply.get("id").and_then(Value::as_u64) else {
                break;
            };
            let Some(result) = reply.get("result") else {
                break;
            };
            if let Ok(mut pending) = reader_bridge.pending.lock()
                && let Some(sender) = pending.remove(&id)
            {
                let _ = sender.send(result.clone());
            }
        }
        reader_bridge.shutdown.cancel();
    });
    let app = router(bridge, &config.token, port, Sessions::new()?);
    output
        .send(json!({"event":"ready", "bridge_version":1, "port":port}).to_string())
        .await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown.cancelled_owned())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    async fn serve(sessions: Sessions) -> (u16, CancellationToken) {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let shutdown = CancellationToken::new();
        let (output, _) = mpsc::channel(1);
        let tool: Tool = serde_json::from_value(
            json!({"name":"get_app_state","inputSchema":{"type":"object","properties":{}}}),
        )
        .unwrap();
        let bridge = Bridge {
            tools: Arc::new(vec![tool]),
            instructions: Arc::new(String::new()),
            output,
            pending: Arc::new(Mutex::new(HashMap::new())),
            serial: Arc::new(AtomicU64::new(1)),
            shutdown: shutdown.clone(),
        };
        let app = router(bridge, TOKEN, port, sessions);
        let stop = shutdown.clone();
        tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(stop.cancelled_owned())
                .await
        });
        (port, shutdown)
    }

    fn request(port: u16, body: &Value, headers: &[(&str, &str)]) -> Vec<u8> {
        let body = body.to_string();
        let mut text = format!(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\n\
             Accept: application/json, text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n",
            body.len()
        );
        for (name, value) in headers {
            text += &format!("{name}: {value}\r\n");
        }
        (text + "\r\n" + &body).into_bytes()
    }

    /// Returns status, the session header and the body of a one-shot request.
    async fn post(
        port: u16,
        body: Value,
        headers: &[(&str, &str)],
    ) -> (u16, Option<String>, String) {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        stream
            .write_all(&request(port, &body, headers))
            .await
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        let (head, body) = response.split_once("\r\n\r\n").unwrap();
        let status = head.split(' ').nth(1).unwrap().parse().unwrap();
        let session = head.lines().find_map(|line| {
            let (name, value) = line.split_once(": ")?;
            name.eq_ignore_ascii_case(SESSION_HEADER)
                .then(|| value.to_owned())
        });
        (status, session, body.to_owned())
    }

    fn initialize() -> Value {
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}})
    }

    fn list() -> Value {
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"})
    }

    #[test]
    fn session_ids_belong_to_one_helper_instance() {
        let first = Sessions::new().unwrap();
        let second = Sessions::new().unwrap();
        let id = first.issue();
        assert!(first.recognizes(&id));
        assert!(!second.recognizes(&id));
        assert!(!first.recognizes(&format!("{}-1", first.instance)));
        assert!(!first.recognizes("stale"));
    }

    #[tokio::test]
    async fn stale_sessions_get_404_until_the_client_initializes_again() {
        let auth = format!("Bearer {TOKEN}");
        let legacy = [
            ("Authorization", auth.as_str()),
            ("MCP-Protocol-Version", "2025-11-25"),
        ];
        // A session from the helper that ran before an app restart.
        let previous = Sessions::new().unwrap().issue();
        let (port, shutdown) = serve(Sessions::new().unwrap()).await;
        let stale = [legacy[0], legacy[1], ("Mcp-Session-Id", previous.as_str())];
        let (status, _, body) = post(port, list(), &stale).await;
        assert_eq!(status, 404);
        let error: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(error["error"]["code"], -32001);
        assert_eq!(
            post(port, list(), &[stale[1], stale[2]]).await.0,
            401,
            "authentication comes before session handling"
        );
        let (status, session, body) = post(port, initialize(), &[legacy[0]]).await;
        assert_eq!(status, 200);
        let capabilities: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(
            capabilities["result"]["capabilities"]["tools"]["listChanged"],
            true
        );
        let session = session.expect("initialize issues a session");
        let current = [legacy[0], legacy[1], ("Mcp-Session-Id", session.as_str())];
        let (status, _, body) = post(port, list(), &current).await;
        assert_eq!(status, 200);
        assert!(body.contains("get_app_state"));
        // Sessionless and 2026-07-28 requests keep working without a session.
        assert_eq!(post(port, list(), &legacy).await.0, 200);
        let modern = json!({"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{
            "io.modelcontextprotocol/protocolVersion":"2026-07-28",
            "io.modelcontextprotocol/clientInfo":{"name":"test","version":"1"},
            "io.modelcontextprotocol/clientCapabilities":{}}}});
        let modern_headers = [
            legacy[0],
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/list"),
            ("Mcp-Session-Id", "ignored"),
        ];
        assert_eq!(post(port, modern, &modern_headers).await.0, 200);
        shutdown.cancel();
    }

    #[tokio::test]
    async fn listen_streams_announce_the_tool_list() {
        let (port, shutdown) = serve(Sessions::new().unwrap()).await;
        let auth = format!("Bearer {TOKEN}");
        let listen = json!({"jsonrpc":"2.0","id":7,"method":"subscriptions/listen","params":{
            "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                "io.modelcontextprotocol/clientInfo":{"name":"test","version":"1"},
                "io.modelcontextprotocol/clientCapabilities":{}},
            "notifications":{"toolsListChanged":true}}});
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        let headers = [
            ("Authorization", auth.as_str()),
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "subscriptions/listen"),
        ];
        stream
            .write_all(&request(port, &listen, &headers))
            .await
            .unwrap();
        let mut received = Vec::new();
        let read = async {
            let mut buffer = [0u8; 4096];
            while !String::from_utf8_lossy(&received).contains("notifications/tools/list_changed") {
                let count = stream.read(&mut buffer).await.unwrap();
                assert!(count > 0, "stream closed before list_changed");
                received.extend_from_slice(&buffer[..count]);
            }
        };
        tokio::time::timeout(Duration::from_secs(5), read)
            .await
            .expect("list_changed arrives on the listen stream");
        let text = String::from_utf8_lossy(&received);
        assert!(text.contains("notifications/subscriptions/acknowledged"));
        assert!(text.contains("\"toolsListChanged\":true"));
        shutdown.cancel();
    }
}
