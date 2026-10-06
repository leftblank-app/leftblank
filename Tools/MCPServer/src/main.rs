//! macOS-only transport adapter. Swift owns schemas, authorization and document state.
use axum::{
    Router,
    extract::{Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
};
use futures::{SinkExt, StreamExt};
use rmcp::{
    ErrorData, RoleServer, ServerHandler,
    model::*,
    service::RequestContext,
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
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
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
    let mut settings = StreamableHttpServerConfig::default()
        .with_json_response(true)
        .enforce_origin_validation();
    settings.legacy_session_mode = false;
    settings.allowed_hosts = vec![format!("127.0.0.1:{port}")];
    settings.allowed_origins = vec![format!("http://127.0.0.1:{port}")];
    settings.cancellation_token = shutdown.clone();
    settings.max_request_body_bytes = 4 * 1024 * 1024;
    let service = StreamableHttpService::new(
        move || Ok(bridge.clone()),
        Arc::new(LocalSessionManager::default()),
        settings,
    );
    let app = Router::new()
        .nest_service("/mcp", service)
        .layer(middleware::from_fn_with_state(
            Arc::new(format!("Bearer {}", config.token)),
            authenticate,
        ));
    output
        .send(json!({"event":"ready", "bridge_version":1, "port":port}).to_string())
        .await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown.cancelled_owned())
        .await?;
    Ok(())
}
