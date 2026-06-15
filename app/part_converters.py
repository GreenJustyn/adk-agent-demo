from typing import Optional, List, Any
import json
import uuid
from datetime import datetime, timezone
from a2a import types as a2a_types
from a2a.types import TaskStatus, TaskState, TaskStatusUpdateEvent, Message, Role
from google.genai import types as genai_types

def convert_a2a_request_to_adk_run_args(request: Any) -> dict:
    """Converts an incoming A2A RequestContext into runner arguments."""
    user_id = f"A2A_USER_{request.context_id}"
    if request.call_context and request.call_context.user and request.call_context.user.user_name:
        user_id = request.call_context.user.user_name
    parts = []
    if request.message and request.message.parts:
        for p in request.message.parts:
            if hasattr(p, 'root') and isinstance(p.root, a2a_types.TextPart):
                parts.append(genai_types.Part(text=p.root.text))
            elif hasattr(p, 'root') and isinstance(p.root, a2a_types.DataPart):
                parts.append(genai_types.Part(text=json.dumps(p.root.data)))
    return {
        'user_id': user_id,
        'session_id': request.context_id,
        'new_message': genai_types.Content(role="user", parts=parts or [genai_types.Part(text="hello")]),
    }
