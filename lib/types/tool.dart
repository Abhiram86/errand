/// Shared tool-call contract — mirrors `handy/src/types/tool.ts` in the
/// React Native/Expo app so both codebases speak the same JSON shape.
///
/// This is the "wire format": requests the loop sends and results tools
/// return. It is deliberately independent of the LLM plumbing in
/// `agent/tool.dart` (which adds the OpenAI-style `Tool` schema + `ToolCall`).
library;

/// Arguments of a tool call — a free-form string-keyed map, like
/// `Record<string, unknown>` in the TypeScript version.
typedef ToolArguments = Map<String, dynamic>;

/// The known tool names (mirrors the `ToolName` union in the TS app).
/// `value` is the wire string, e.g. `ToolName.openUrl.value == 'open_url'`.
enum ToolName {
  // Phase-1 intent / device tools
  openUrl('open_url'),
  dial('dial'),
  share('share'),
  geo('geo'),
  mailto('mailto'),
  notify('notify'),
  playMedia('play_media'),
  sendIntent('send_intent'),
  // File tools (Phase-1 SAF set)
  listDir('list_dir'),
  readFile('read_file'),
  writeFile('write_file'),
  editFile('edit_file'),
  // Phase-2 UI automation
  uiRead('ui_read'),
  uiClick('ui_click'),
  uiType('ui_type'),
  uiSwipe('ui_swipe'),
  launchApp('launch_app'),
  readNotif('read_notif'),
  // Flutter loop's current tool names
  list('list'),
  read('read'),
  write('write'),
  find('find'),
  grep('grep');

  final String value;

  const ToolName(this.value);

  /// Looks up a `ToolName` by its wire string; null if unknown.
  static ToolName? tryParse(String value) {
    for (final name in ToolName.values) {
      if (name.value == value) return name;
    }
    return null;
  }
}

/// A request to run one tool — `{ id, name, arguments, workspaceUri? }`.
class ToolCallRequest {
  final String id;
  final String name;
  final ToolArguments arguments;
  final String? workspaceUri;

  const ToolCallRequest({
    required this.id,
    required this.name,
    required this.arguments,
    this.workspaceUri,
  });

  factory ToolCallRequest.fromJson(Map<String, dynamic> json) =>
      ToolCallRequest(
        id: json['id'] as String,
        name: json['name'] as String,
        arguments: (json['arguments'] as Map?)?.cast<String, dynamic>() ?? {},
        workspaceUri: json['workspaceUri'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
    if (workspaceUri != null) 'workspaceUri': workspaceUri,
  };
}

/// A file touched by a tool call, with optional before/after snapshots for
/// the diff preview / undo layer.
class FileChange {
  final String path;
  final String? before;
  final String? after;

  const FileChange({required this.path, this.before, this.after});

  factory FileChange.fromJson(Map<String, dynamic> json) => FileChange(
    path: json['path'] as String,
    before: json['before'] as String?,
    after: json['after'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    if (before != null) 'before': before,
    if (after != null) 'after': after,
  };
}

/// Machine-readable error carried by a failed `ToolCallResult`.
class ToolCallError {
  final String type;
  final String message;
  final bool retryable;

  const ToolCallError({
    required this.type,
    required this.message,
    required this.retryable,
  });

  factory ToolCallError.fromJson(Map<String, dynamic> json) => ToolCallError(
    type: json['type'] as String,
    message: json['message'] as String,
    retryable: json['retryable'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'message': message,
    'retryable': retryable,
  };
}

/// The result of one tool call — `{ id, ok, output, filesChanged?, error? }`.
class ToolCallResult {
  final String id;
  final bool ok;
  final String output;
  final List<FileChange>? filesChanged;
  final ToolCallError? error;

  const ToolCallResult({
    required this.id,
    required this.ok,
    required this.output,
    this.filesChanged,
    this.error,
  });

  /// Shortcut for a failed call with a plain message.
  factory ToolCallResult.failure(
    String callId,
    String message, {
    String type = 'tool_error',
    bool retryable = false,
  }) => ToolCallResult(
    id: callId,
    ok: false,
    output: '',
    error: ToolCallError(type: type, message: message, retryable: retryable),
  );

  factory ToolCallResult.fromJson(Map<String, dynamic> json) => ToolCallResult(
    id: json['id'] as String,
    ok: json['ok'] as bool,
    output: json['output'] as String,
    filesChanged: (json['filesChanged'] as List?)
        ?.map((e) => FileChange.fromJson(e as Map<String, dynamic>))
        .toList(),
    error: json['error'] == null
        ? null
        : ToolCallError.fromJson(json['error'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ok': ok,
    'output': output,
    if (filesChanged != null)
      'filesChanged': filesChanged!.map((f) => f.toJson()).toList(),
    if (error != null) 'error': error!.toJson(),
  };

  String? get errorMessage => error?.message;

  /// Human-readable one-liner used when feeding the result back to the LLM.
  String toText() {
    if (ok) return output;
    return 'ERROR: ${error?.message ?? 'unknown error'}';
  }
}
