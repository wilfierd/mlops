import asyncio
import html
import os
from typing import Literal

import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from ray import serve
from transformers import AutoModelForCausalLM, AutoTokenizer


api = FastAPI(title="CPU LLM Chat")


class Message(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=8000)


class ChatRequest(BaseModel):
    messages: list[Message] = Field(min_length=1)
    max_new_tokens: int | None = Field(default=None, ge=1, le=512)
    temperature: float = Field(default=0.7, ge=0.0, le=2.0)
    top_p: float = Field(default=0.8, ge=0.1, le=1.0)


class ChatResponse(BaseModel):
    answer: str
    model: str
    replica: str


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if not raw:
        return default
    return int(raw)


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if not raw:
        return default
    return float(raw)


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


def _env_dtype(name: str, default: str) -> torch.dtype:
    raw = (os.getenv(name) or default).lower()
    return {
        "float32": torch.float32,
        "fp32": torch.float32,
        "bfloat16": torch.bfloat16,
        "bf16": torch.bfloat16,
        "float16": torch.float16,
        "fp16": torch.float16,
    }.get(raw, torch.float32)


def _chat_html(model_id: str) -> str:
    escaped_model = html.escape(model_id)
    return f"""<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>LLM Chat</title>
  <style>
    :root {{
      color-scheme: light dark;
      --bg: #f9f9f9;
      --panel: #ffffff;
      --ink: #333333;
      --muted: #888888;
      --line: #e5e5e5;
      --accent: #007aff;
      --accent-hover: #005bb5;
      --user-bg: #007aff;
      --user-text: #ffffff;
      --assistant-bg: #f1f1f1;
      --assistant-text: #333333;
      --radius: 18px;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #121212;
        --panel: #1e1e1e;
        --ink: #e0e0e0;
        --muted: #aaaaaa;
        --line: #333333;
        --accent: #0a84ff;
        --accent-hover: #0066cc;
        --user-bg: #0a84ff;
        --user-text: #ffffff;
        --assistant-bg: #2d2d2d;
        --assistant-text: #e0e0e0;
      }}
    }}
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--bg);
      color: var(--ink);
      display: flex;
      justify-content: center;
      height: 100vh;
      overflow: hidden;
    }}
    .chat-container {{
      width: 100%;
      max-width: 900px;
      display: flex;
      flex-direction: column;
      height: 100%;
      background: var(--panel);
      box-shadow: 0 0 20px rgba(0,0,0,0.05);
    }}
    header {{
      padding: 16px 24px;
      border-bottom: 1px solid var(--line);
      display: flex;
      justify-content: space-between;
      align-items: center;
      background: var(--panel);
      z-index: 10;
    }}
    h1 {{ font-size: 1.2rem; font-weight: 600; }}
    .model {{ font-size: 0.85rem; color: var(--muted); }}
    main {{
      flex: 1;
      overflow-y: auto;
      padding: 24px;
      display: flex;
      flex-direction: column;
      gap: 16px;
      scroll-behavior: smooth;
    }}
    .message {{
      max-width: 85%;
      padding: 12px 16px;
      border-radius: var(--radius);
      line-height: 1.5;
      font-size: 0.95rem;
      word-wrap: break-word;
      white-space: pre-wrap;
    }}
    .message.user {{
      align-self: flex-end;
      background: var(--user-bg);
      color: var(--user-text);
      border-bottom-right-radius: 4px;
    }}
    .message.assistant {{
      align-self: flex-start;
      background: var(--assistant-bg);
      color: var(--assistant-text);
      border-bottom-left-radius: 4px;
    }}
    .composer {{
      padding: 16px 24px;
      border-top: 1px solid var(--line);
      background: var(--panel);
    }}
    form {{
      display: flex;
      gap: 12px;
      align-items: flex-end;
    }}
    textarea {{
      flex: 1;
      min-height: 44px;
      max-height: 150px;
      resize: none;
      padding: 12px 16px;
      border-radius: 22px;
      border: 1px solid var(--line);
      background: var(--bg);
      color: var(--ink);
      font-family: inherit;
      font-size: 0.95rem;
      line-height: 1.4;
      outline: none;
      transition: border-color 0.2s;
    }}
    textarea:focus {{
      border-color: var(--accent);
    }}
    button {{
      height: 44px;
      width: 44px;
      flex-shrink: 0;
      border-radius: 50%;
      border: none;
      background: var(--accent);
      color: white;
      cursor: pointer;
      display: flex;
      justify-content: center;
      align-items: center;
      transition: background-color 0.2s, transform 0.1s;
    }}
    button:hover:not(:disabled) {{ background: var(--accent-hover); }}
    button:active:not(:disabled) {{ transform: scale(0.95); }}
    button:disabled {{
      background: var(--muted);
      cursor: not-allowed;
      opacity: 0.7;
    }}
    button svg {{ width: 20px; height: 20px; fill: currentColor; transform: translateX(1px); }}
    .error {{
      color: #ff3b30;
      font-size: 0.85rem;
      margin-top: 8px;
      text-align: center;
      min-height: 20px;
    }}
    /* Scrollbar */
    ::-webkit-scrollbar {{ width: 6px; }}
    ::-webkit-scrollbar-track {{ background: transparent; }}
    ::-webkit-scrollbar-thumb {{ background: var(--line); border-radius: 3px; }}
    ::-webkit-scrollbar-thumb:hover {{ background: var(--muted); }}
  </style>
</head>
<body>
  <div class="chat-container">
    <header>
      <h1>LLM Chat</h1>
      <div class="model">{escaped_model}</div>
    </header>
    <main id="messages">
      <div class="message assistant">Xin chào! Sẵn sàng.</div>
    </main>
    <div class="composer">
      <form id="form">
        <textarea id="input" name="input" autocomplete="off" placeholder="Nhập tin nhắn... (Enter để gửi, Shift+Enter xuống dòng)" rows="1"></textarea>
        <button id="send" type="submit" aria-label="Gửi">
          <svg viewBox="0 0 24 24"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>
        </button>
      </form>
      <div id="error" class="error"></div>
    </div>
  </div>
  <script>
    const form = document.getElementById("form");
    const input = document.getElementById("input");
    const send = document.getElementById("send");
    const messagesEl = document.getElementById("messages");
    const errorEl = document.getElementById("error");
    const messages = [];

    // Auto-resize textarea
    input.addEventListener("input", function() {{
      this.style.height = "44px";
      this.style.height = (this.scrollHeight) + "px";
    }});

    // Enter to submit
    input.addEventListener("keydown", (event) => {{
      if (event.key === "Enter" && !event.shiftKey) {{
        event.preventDefault();
        if (input.value.trim() !== "") {{
          form.requestSubmit();
        }}
      }}
    }});

    function addMessage(role, content) {{
      const node = document.createElement("div");
      node.className = `message ${{role}}`;
      node.textContent = content;
      messagesEl.appendChild(node);
      messagesEl.scrollTo({{ top: messagesEl.scrollHeight, behavior: "smooth" }});
    }}

    form.addEventListener("submit", async (event) => {{
      event.preventDefault();
      const content = input.value.trim();
      if (!content || send.disabled) return;

      errorEl.textContent = "";
      input.value = "";
      input.style.height = "44px";
      messages.push({{ role: "user", content }});
      addMessage("user", content);
      send.disabled = true;

      try {{
        const response = await fetch("/chat", {{
          method: "POST",
          headers: {{ "content-type": "application/json" }},
          body: JSON.stringify({{ messages, max_new_tokens: 160 }})
        }});
        if (!response.ok) {{
          throw new Error(await response.text());
        }}
        const data = await response.json();
        messages.push({{ role: "assistant", content: data.answer }});
        addMessage("assistant", data.answer);
      }} catch (error) {{
        errorEl.textContent = error.message || "Request failed";
      }} finally {{
        send.disabled = false;
        input.focus();
      }}
    }});
  </script>
</body>
</html>"""


@serve.deployment(
    name="ChatModel",
    ray_actor_options={"num_cpus": _env_float("MODEL_NUM_CPUS", 2.0)},
    max_ongoing_requests=_env_int("MAX_ONGOING_REQUESTS", 1),
    autoscaling_config={
        "min_replicas": _env_int("MIN_REPLICAS", 1),
        "initial_replicas": _env_int("INITIAL_REPLICAS", 1),
        "max_replicas": _env_int("MAX_REPLICAS", 4),
        "target_ongoing_requests": _env_float("TARGET_ONGOING_REQUESTS", 1.0),
        "upscale_delay_s": _env_float("UPSCALE_DELAY_S", 10.0),
        "downscale_delay_s": _env_float("DOWNSCALE_DELAY_S", 120.0),
    },
)
@serve.ingress(api)
class ChatModel:
    def __init__(self) -> None:
        self.model_id = os.getenv("MODEL_ID", "Qwen/Qwen3-0.6B")
        self.max_input_tokens = _env_int("MAX_INPUT_TOKENS", 2048)
        self.default_max_new_tokens = _env_int("MAX_NEW_TOKENS", 160)
        self.enable_thinking = _env_bool("ENABLE_THINKING", False)
        self.replica = f"{os.uname().nodename}:{os.getpid()}"

        torch.set_num_threads(_env_int("TORCH_NUM_THREADS", max(1, os.cpu_count() or 1)))
        self.dtype = _env_dtype("MODEL_DTYPE", "bfloat16")
        self.tokenizer = AutoTokenizer.from_pretrained(self.model_id)
        self.model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            torch_dtype=self.dtype,
        )
        self.model.eval()

        if self.tokenizer.pad_token_id is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token

    @api.get("/", response_class=HTMLResponse)
    async def index(self) -> HTMLResponse:
        return HTMLResponse(_chat_html(self.model_id))

    @api.get("/health")
    async def health(self) -> dict[str, str]:
        return {"status": "ok", "model": self.model_id, "replica": self.replica}

    @api.post("/chat", response_model=ChatResponse)
    async def chat(self, request: ChatRequest) -> ChatResponse:
        if not any(message.role == "user" for message in request.messages):
            raise HTTPException(status_code=400, detail="messages must include a user message")

        max_new_tokens = request.max_new_tokens or self.default_max_new_tokens
        answer = await asyncio.to_thread(
            self._generate,
            request.messages,
            max_new_tokens,
            request.temperature,
            request.top_p,
        )
        return ChatResponse(answer=answer, model=self.model_id, replica=self.replica)

    def _build_prompt(self, messages: list[Message]) -> str:
        normalized = [message.model_dump() for message in messages]
        chat_template = getattr(self.tokenizer, "chat_template", None)
        if chat_template:
            try:
                return self.tokenizer.apply_chat_template(
                    normalized,
                    tokenize=False,
                    add_generation_prompt=True,
                    enable_thinking=self.enable_thinking,
                )
            except TypeError:
                return self.tokenizer.apply_chat_template(
                    normalized,
                    tokenize=False,
                    add_generation_prompt=True,
                )

        lines = []
        for message in normalized:
            role = message["role"].upper()
            lines.append(f"{role}: {message['content']}")
        lines.append("ASSISTANT:")
        return "\n".join(lines)

    def _generate(
        self,
        messages: list[Message],
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> str:
        prompt = self._build_prompt(messages)
        inputs = self.tokenizer(
            prompt,
            return_tensors="pt",
            truncation=True,
            max_length=self.max_input_tokens,
            return_attention_mask=True,
        )

        generation_kwargs = {
            "input_ids": inputs["input_ids"],
            "attention_mask": inputs["attention_mask"],
            "max_new_tokens": max_new_tokens,
            "pad_token_id": self.tokenizer.pad_token_id,
            "eos_token_id": self.tokenizer.eos_token_id,
        }
        if temperature > 0:
            generation_kwargs.update(
                {
                    "do_sample": True,
                    "temperature": temperature,
                    "top_p": top_p,
                }
            )
        else:
            generation_kwargs["do_sample"] = False

        with torch.inference_mode():
            output_ids = self.model.generate(**generation_kwargs)

        prompt_tokens = inputs["input_ids"].shape[-1]
        generated_ids = output_ids[0][prompt_tokens:]
        text = self.tokenizer.decode(generated_ids, skip_special_tokens=True).strip()
        stripped = text.lstrip()
        if not self.enable_thinking and stripped.startswith("<think>") and "</think>" in stripped:
            text = stripped.split("</think>", 1)[1].strip()
        return text or "(empty response)"


chat_app = ChatModel.bind()
