/// Runtime result returned by a registered tool.
library;

typedef ToolArguments = Map<String, dynamic>;

class ToolCallError {
  final String type;
  final String message;
  final bool retryable;

  const ToolCallError({
    required this.type,
    required this.message,
    required this.retryable,
  });
}

class ToolCallResult {
  final String id;
  final bool ok;
  final String output;
  final ToolCallError? error;

  const ToolCallResult({
    required this.id,
    required this.ok,
    required this.output,
    this.error,
  });

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

  String? get errorMessage => error?.message;

  String toText() {
    if (ok) return output;
    return 'ERROR: ${error?.message ?? 'unknown error'}';
  }
}
