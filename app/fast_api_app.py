import os
import asyncio
import uuid
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from fastapi import FastAPI, Request
from starlette.middleware.base import BaseHTTPMiddleware
import builtins
import google.auth

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fast_api_app")
logger.info("Initializing FastAPI application...")

from a2a.server.apps import A2AFastAPIApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, Artifact, Message, Role, TaskArtifactUpdateEvent, TaskState, TaskStatus, TaskStatusUpdateEvent
from a2a.server.agent_execution import RequestContext
from a2a.server.events.event_queue import EventQueue
from a2a.utils.constants import AGENT_CARD_WELL_KNOWN_PATH, EXTENDED_AGENT_CARD_PATH
from google.adk.a2a.executor.a2a_agent_executor import A2aAgentExecutor
from google.adk.artifacts import InMemoryArtifactService
from google.adk.runners import Runner, RunConfig
from google.adk.sessions import InMemorySessionService
from a2a import types as a2a_types

logger.info("Importing ADK agent configuration...")
try:
    from app.agent import app as adk_app
    import app.part_converters as part_converters
    logger.info("ADK agent imported successfully.")
except Exception as e:
    logger.error(f"Fatal error importing ADK agent: {e}", exc_info=True)
    raise

os.environ["OTEL_PYTHON_DISABLED_INSTRUMENTATIONS"] = "httpx"

runner = Runner(app=adk_app, artifact_service=InMemoryArtifactService(), session_service=InMemorySessionService())

class AdkAgentToA2AExecutor(A2aAgentExecutor):
    async def _handle_request(self, context: RequestContext, event_queue: EventQueue) -> None:
        run_args = part_converters.convert_a2a_request_to_adk_run_args(context)
        run_args['run_config'] = RunConfig(max_llm_calls=25)
        
        session_id = run_args['session_id']
        user_id = run_args['user_id']
        session = await runner.session_service.get_session(
            app_name=runner.app_name,
            user_id=user_id,
            session_id=session_id,
        )
        if session is None:
            logger.info(f"Creating new in-memory session for session_id={session_id}")
            session = await runner.session_service.create_session(
                app_name=runner.app_name,
                user_id=user_id,
                session_id=session_id,
            )
        run_args['session_id'] = session.id

        await event_queue.enqueue_event(TaskStatusUpdateEvent(
            task_id=context.task_id, context_id=context.context_id,
            status=TaskStatus(state=TaskState.working, timestamp=datetime.now(timezone.utc).isoformat()), final=False
        ))
        
        final_text = []
        async for event in runner.run_async(**run_args):
            if hasattr(event, 'error_code') and event.error_code:
                err_evt = TaskStatusUpdateEvent(
                    task_id=context.task_id, context_id=context.context_id,
                    status=TaskStatus(state=TaskState.failed, message=Message(role=Role.agent, parts=[a2a_types.Part(root=a2a_types.TextPart(text=f"Error: {event.error_code}"))], message_id=str(uuid.uuid4())), timestamp=datetime.now(timezone.utc).isoformat()), final=True
                )
                await event_queue.enqueue_event(err_evt)
                return
            if getattr(event, 'content', None) and hasattr(event.content, 'parts'):
                for p in event.content.parts:
                    if p.text: final_text.append(p.text)
                    elif p.function_call and p.function_call.name != 'transfer_to_agent':
                        final_text.clear()
                        status_msg = f"🔧 Executing {p.function_call.name}..."
                        await event_queue.enqueue_event(TaskStatusUpdateEvent(
                            task_id=context.task_id, context_id=context.context_id,
                            status=TaskStatus(state=TaskState.working, message=Message(message_id=str(uuid.uuid4()), role=Role.agent, parts=[a2a_types.Part(root=a2a_types.TextPart(text=status_msg))]), timestamp=datetime.now(timezone.utc).isoformat()), final=False
                        ))
        
        full_resp = "\n".join(final_text)
        parts = [a2a_types.Part(root=a2a_types.TextPart(text=full_resp))]
        await event_queue.enqueue_event(TaskArtifactUpdateEvent(
            task_id=context.task_id, last_chunk=True, context_id=context.context_id,
            artifact=Artifact(artifact_id=str(uuid.uuid4()), parts=parts)
        ))
        await event_queue.enqueue_event(TaskStatusUpdateEvent(
            task_id=context.task_id, context_id=context.context_id, status=TaskStatus(state=TaskState.completed, timestamp=datetime.now(timezone.utc).isoformat()), final=True
        ))

request_handler = DefaultRequestHandler(agent_executor=AdkAgentToA2AExecutor(runner=runner, use_legacy=True), task_store=InMemoryTaskStore())
A2A_RPC_PATH = f"/a2a/{adk_app.name}"

def _build_static_agent_card() -> AgentCard:
    from a2a.types import AgentSkill
    return AgentCard(
        name=adk_app.name,
        description="Claims Processing Investigation Agent",
        url=f"http://0.0.0.0:8080{A2A_RPC_PATH}",
        version="1.0.0",
        capabilities=AgentCapabilities(streaming=True, pushNotifications=True),
        defaultInputModes=["text/plain"],
        defaultOutputModes=["text/plain", "application/json"],
        skills=[AgentSkill(id="bigquery", name="BigQuery Operations", description="Investigates SIEM/MELT telemetry and performs graph analysis on service dependencies.", tags=[])]
    )

@asynccontextmanager
async def lifespan(app_instance: FastAPI):
    logger.info("FastAPI lifespan startup: registering A2A routes...")
    try:
        agent_card = _build_static_agent_card()
        a2a_app = A2AFastAPIApplication(agent_card=agent_card, http_handler=request_handler)
        a2a_app.add_routes_to_app(app_instance, agent_card_url=f"{A2A_RPC_PATH}{AGENT_CARD_WELL_KNOWN_PATH}", rpc_url=A2A_RPC_PATH, extended_agent_card_url=f"{A2A_RPC_PATH}{EXTENDED_AGENT_CARD_PATH}")
        logger.info("A2A routes registered successfully.")
    except Exception as e:
        logger.error(f"Error during lifespan startup: {e}", exc_info=True)
        raise
    yield
    logger.info("FastAPI lifespan shutdown.")

app = FastAPI(title="claims-processing-investigation-agent", lifespan=lifespan)

class TokenMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        token = request.headers.get("authorization", "")
        if token.startswith("Bearer "): builtins._workspace_oauth_token = token[7:]
        elif request.headers.get("x-authorization", "").startswith("Bearer "): builtins._workspace_oauth_token = request.headers.get("x-authorization")[7:]
        return await call_next(request)

app.add_middleware(TokenMiddleware)
logger.info("FastAPI app configuration complete.")

if __name__ == "__main__":
    import uvicorn; uvicorn.run(app, host="0.0.0.0", port=8080)
