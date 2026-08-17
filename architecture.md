# Handy (Flutter) — Architecture Overview

This document maps the current implementation: a Flutter chat UI, an
OpenAI-compatible agent loop, two file tools, and Android shared-storage access.

## Big picture

The app keeps the conversation on the phone and sends the complete conversation
history to the configured LLM. The LLM can call the registered file tools; tool
results are fed back into the same loop until the model returns a final answer.

```text
chat UI (lib/main.dart)
     │  builds Conversation: messages + currentDir
     ▼
agent loop (lib/agent/agent_loop.dart)
     │  converts history to chat API messages
     │  calls tools and feeds results back
     ▼
LLM client (lib/llm/llm_client.dart)  ◀── HTTP → OpenRouter or compatible API
     ▲
     │  tool schemas / tool calls / tool results
     ▼
tool registry (lib/agent/tool_registry.dart)
     │
     ▼
file tools (lib/tools/file_tools.dart)
     │
     ▼
workspace (lib/services/workspace.dart) ──▶ Android MethodChannel
                                           └─ MANAGE_EXTERNAL_STORAGE
```

## Conversation and messages

`lib/types/conversation.dart` is the session container. It carries:

- the conversation ID and timestamps;
- the optional system prompt;
- the complete `List<Message>` history;
- the current `Directory`, defaulting to `/storage/emulated/0`;
- tool invocation metadata.

`lib/types/message.dart` models the UI and conversation history with typed
messages:

- `UserMessage` — user input;
- `AssistantMessage` — model responses;
- `ToolMessage` — a tool name, arguments, call ID, display preview, and full
  result;
- `ErrorMessage` — an application error surfaced in the conversation.

The UI stores a short tool preview for rendering, while the complete tool
result is retained for future LLM requests. `Conversation.toJson()` persists
the current directory as its path.

## The agent — `lib/agent/`

- **`tool.dart`** defines the LLM-facing `Tool` schema and parsed `ToolCall`.
  `ToolCall.toJson()` serializes function arguments as a JSON string, which is
  required by OpenAI-compatible chat APIs.
- **`tool_registry.dart`** registers the current tools and safely executes a
  call, converting handler exceptions into `ToolCallResult.failure` values.
  The default registry currently contains `read` and `list`.
- **`agent_loop.dart`** exposes `run(Conversation)`. It converts every user,
  assistant, tool, and error message into the LLM chat format. Consecutive tool
  messages are reconstructed as one assistant `tool_calls` message followed by
  matching tool-result messages. During the active request it continues tool
  turns for up to 12 iterations.

## The LLM client — `lib/llm/llm_client.dart`

`LlmClient` is a small `package:http` client for `/chat/completions`. It sends:

- the model name;
- the complete message history supplied by `AgentLoop`;
- the registered tool schemas;
- the configured bearer token.

Responses are parsed into `LlmMessage` and `ToolCall` objects. The API key is
provided at build/run time with:

```bash
flutter run --dart-define-from-file=.env
```

The `.env` file is local-only and is ignored by Git.

## The file tools — `lib/tools/file_tools.dart`

The current registry contains two tools:

- **`read`** reads a bounded byte range from a file. Relative paths resolve
  against `/storage/emulated/0`; absolute paths are also accepted by the
  current implementation.
- **`list`** lists immediate files and directories. With no `path`, it lists
  the app-provided current directory. A relative `path` is resolved from that
  directory, while an absolute path must remain inside the workspace root.
  An optional regular-expression `pattern` filters the returned paths.

The LLM may supply `list.path`, but the workspace/current-directory root is
owned by the app and passed into the tool handler by `ToolRegistry`.

## The workspace — `lib/services/workspace.dart`

`Workspace` is a singleton around the Android `storage_access` MethodChannel.
It currently:

- checks `Environment.isExternalStorageManager()` through Android;
- opens Android's all-files-access settings page when permission is requested;
- exposes `/storage/emulated/0` as the default root directory;
- converts missing or failed platform-channel calls into a safe “no permission”
  result rather than crashing.

This implementation uses direct `dart:io` paths, not the Storage Access
Framework or a persisted folder URI. Android all-files access is declared in
`android/app/src/main/AndroidManifest.xml` and handled in
`android/app/src/main/kotlin/com/handy/handy_flutter/MainActivity.kt`.

## The UI — `lib/main.dart`

`ChatScreen` owns the active conversation state, current directory, input
controller, busy state, and scroll state.

- `_send()` appends the user message, builds a `Conversation`, and starts the
  agent loop with the current directory injected into the tool registry.
- Tool events are stored as `ToolMessage` entries with full results.
- User and assistant messages use chat bubbles.
- Tool calls render as compact, plain textual `ExpansionTile` rows. Tool names
  and arguments are truncated in the header, and output is truncated only for
  display; the full result remains available to the LLM.
- The folder button checks or requests Android all-files access.

## Reading order

1. `lib/types/message.dart` and `lib/types/conversation.dart`
2. `lib/agent/tool.dart` → `tool_registry.dart` → `agent_loop.dart`
3. `lib/services/workspace.dart` + `lib/tools/file_tools.dart`
4. `lib/llm/llm_client.dart`
5. `lib/main.dart`

## Next steps

- Add explicit directory navigation so `_currentDir` can change independently
  of `list.path`.
- Add more tools under `lib/tools/` and register them in
  `ToolRegistry.defaults()`.
- Add a local conversation store if history should survive app restarts.
- Consider the Android Storage Access Framework if broad all-files access is
  not required by the final product.
