import os
import asyncio
import time
import anyio
import httpx
import dotenv
import google.auth
import google.auth.transport.requests
from google.adk.tools.mcp_tool.mcp_toolset import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams

TARGET_PROJECT_ID = os.getenv("TARGET_PROJECT_ID", os.getenv("GOOGLE_CLOUD_PROJECT", "secops2-454901"))

def get_project_id():
    """Robustly retrieves the caller's GCP project ID."""
    pid = os.getenv("GOOGLE_CLOUD_PROJECT")
    if pid: return pid
    dotenv.load_dotenv()
    pid = os.getenv("GOOGLE_CLOUD_PROJECT")
    if pid: return pid
    try:
        _, pid = google.auth.default()
        if pid: return pid
    except: pass
    return "UNKNOWN"

# =============================================================================
# Stability Patches for MCP Transport Sessions
# =============================================================================

_orig_client_init = httpx.AsyncClient.__init__
def _patched_client_init(self, *args, **kwargs):
    kwargs['http2'] = False
    kwargs['timeout'] = httpx.Timeout(300.0, connect=60.0)
    return _orig_client_init(self, *args, **kwargs)

_token_cache = {"token": None, "expiry": 0, "credentials": None}
_token_lock = asyncio.Lock()

async def _get_fresh_mcp_token():
    """Retrieves and refreshes an OAuth2 token safely within async event loops."""
    global _token_cache
    async with _token_lock:
        now = time.time()
        if _token_cache["token"] and now < _token_cache["expiry"]:
            return _token_cache["token"]
        try:
            if _token_cache["credentials"] is None:
                def _get_creds():
                    scopes = ["https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/bigquery"]
                    creds, _ = google.auth.default(scopes=scopes)
                    return creds
                _token_cache["credentials"] = await anyio.to_thread.run_sync(_get_creds)
            credentials = _token_cache["credentials"]
            import requests
            class TimeoutSession(requests.Session):
                def request(self, *args, **kwargs):
                    kwargs.setdefault('timeout', 10.0)
                    return super().request(*args, **kwargs)
            req = google.auth.transport.requests.Request(session=TimeoutSession())
            await anyio.to_thread.run_sync(credentials.refresh, req)
            _token_cache = {"token": credentials.token, "expiry": now + 1800, "credentials": credentials}
            return credentials.token
        except Exception as e:
            import logging; logging.warning(f"Failed to refresh token: {e}")
            return ""

_orig_send = httpx.AsyncClient.send
async def _patched_send(self, request, *args, **kwargs):
    """Injects Bearer authentication headers and transmutes JSON-RPC errors to HTTP 200."""
    _url = str(request.url)
    if "bigquery.googleapis.com/mcp" in _url:
        token = await _get_fresh_mcp_token()
        if token: request.headers['Authorization'] = f"Bearer {token}"
        
    response = await _orig_send(self, request, *args, **kwargs)
    
    # JSON-RPC 2.0 compliance: Convert 400/403 to 200 so LLMs receive detailed SQL/DML error messages
    if response.status_code in [400, 403] and "bigquery.googleapis.com/mcp" in _url:
        try:
            body = b""
            async for chunk in response.aiter_bytes():
                body += chunk
                if len(body) > 0 or not chunk: break
            if b'"jsonrpc":' in body: response.status_code = 200
            response._content = body
        except Exception: pass
    return response

try:
    httpx.AsyncClient.__init__ = _patched_client_init
    httpx.AsyncClient.send = _patched_send
except Exception as e: pass

def get_bigquery_mcp_toolset():
    """Instantiates the BigQuery MCP toolset targeting project secops2-454901."""
    url = f"https://bigquery.googleapis.com/mcp?project={TARGET_PROJECT_ID}"
    caller_pid = get_project_id()
    return McpToolset(connection_params=StreamableHTTPConnectionParams(
        url=url,
        headers={"x-goog-user-project": caller_pid if caller_pid != "UNKNOWN" else TARGET_PROJECT_ID},
        timeout=300
    ))
