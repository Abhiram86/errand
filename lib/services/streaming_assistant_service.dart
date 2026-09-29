import 'dart:async';
import 'package:flutter/foundation.dart';

/// The current status of the in-flight assistant turn.
enum StreamingAssistantStatus {
  working,
  thinking,
  compacting,
  retrying,
  streaming,
}

/// A snapshot of the streaming assistant state at any point in time.
@immutable
class StreamingSnapshot {
  /// Finalized, immutable blocks (paragraphs, completed code fences, completed tables).
  /// These blocks will never be altered by subsequent streaming deltas.
  final List<String> finalizedBlocks;

  /// The active in-flight segment currently receiving tokens (raw/pristine).
  final String activeTail;

  /// The active in-flight segment with incomplete markdown markers virtually closed
  /// to eliminate FOIM (Flash of Incomplete Markdown).
  final String healedTail;

  /// Complete list of display blocks: [finalizedBlocks] + [healedTail] (if non-empty).
  final List<String> displayBlocks;

  /// The complete raw text accumulated so far across all blocks.
  final String fullPristineText;

  /// The complete display text (all display blocks joined by double newlines).
  final String fullDisplayText;

  /// Current status of the turn.
  final StreamingAssistantStatus status;

  /// Text label for the placeholder when in a non-streaming state.
  final String placeholderLabel;

  /// Whether any non-whitespace text has been streamed so far.
  final bool hasContent;

  const StreamingSnapshot({
    required this.finalizedBlocks,
    required this.activeTail,
    required this.healedTail,
    required this.displayBlocks,
    required this.fullPristineText,
    required this.fullDisplayText,
    required this.status,
    required this.placeholderLabel,
    required this.hasContent,
  });

  /// An initial empty snapshot in the "working" state.
  factory StreamingSnapshot.initial() {
    return const StreamingSnapshot(
      finalizedBlocks: [],
      activeTail: '',
      healedTail: '',
      displayBlocks: [],
      fullPristineText: '',
      fullDisplayText: '…working',
      status: StreamingAssistantStatus.working,
      placeholderLabel: '…working',
      hasContent: false,
    );
  }
}

/// Manages streaming assistant tokens, paragraph-by-paragraph block segmentation,
/// virtual markdown tag healing, flush throttling, and turn status transitions.
///
/// Abstracting this out of [ChatScreen] eliminates dozens of state variables,
/// timer handlers, and string-chopping operations from the main chat widget.
class StreamingAssistantService {
  final void Function(StreamingSnapshot snapshot)? onUpdate;
  final Duration paragraphFallbackInterval;
  final Duration tableHoldInterval;

  StreamingAssistantStatus _status = StreamingAssistantStatus.working;
  int? _retryAttempt;
  bool _isCompacting = false;
  bool _isReasoning = false;

  final StringBuffer _fullPristineBuffer = StringBuffer();
  final List<String> _finalizedBlocks = [];
  String _activeTail = '';

  // Incremental code fence tracking: odd count = inside a code fence.
  int _fenceCount = 0;
  // Tail buffer for table row detection
  String _tableTail = '';

  Timer? _flushTimer;

  StreamingAssistantService({
    this.onUpdate,
    this.paragraphFallbackInterval = const Duration(milliseconds: 1200),
    this.tableHoldInterval = const Duration(milliseconds: 250),
  });

  StreamingAssistantStatus get status => _status;
  int? get retryAttempt => _retryAttempt;
  bool get hasContent => _fullPristineBuffer.toString().trim().isNotEmpty;
  String get currentPristineText => _fullPristineBuffer.toString();

  /// Finalized blocks (valid after [finalize] moves the tail in).
  List<String> get finalizedBlocks => List.unmodifiable(_finalizedBlocks);

  String get placeholderLabel {
    if (_isCompacting) return '…compacting context';
    if (_retryAttempt != null) return '…retrying · attempt $_retryAttempt';
    if (_isReasoning) return '…thinking';
    return '…working';
  }

  /// Called when thinking / reasoning deltas start for the current turn.
  void startReasoning() {
    if (hasContent) return; // Once real text streams, keep streaming text
    if (_isReasoning) return;
    _isReasoning = true;
    _status = StreamingAssistantStatus.thinking;
    _emitSnapshotNow();
  }

  /// Called when context compaction starts or finishes.
  void setCompacting(bool compacting) {
    if (_isCompacting == compacting) return;
    _isCompacting = compacting;
    if (hasContent) return;
    _status = compacting
        ? StreamingAssistantStatus.compacting
        : (_isReasoning
            ? StreamingAssistantStatus.thinking
            : StreamingAssistantStatus.working);
    _emitSnapshotNow();
  }

  /// Called when a stream error triggers a client retry.
  void setRetry(int? attempt) {
    _retryAttempt = attempt;
    if (hasContent) return;
    _status = attempt != null
        ? StreamingAssistantStatus.retrying
        : (_isReasoning
            ? StreamingAssistantStatus.thinking
            : StreamingAssistantStatus.working);
    _emitSnapshotNow();
  }

  /// Ingests an incoming text delta from the LLM stream.
  void appendDelta(String delta) {
    if (delta.isEmpty) return;
    _fullPristineBuffer.write(delta);

    // Any fresh text clears the retry label
    _retryAttempt = null;
    _status = StreamingAssistantStatus.streaming;

    // Track code fence backticks in this delta: ``` or ~~~
    _updateFenceCount(delta);
    final insideCodeFence = _fenceCount % 2 == 1;

    // Append to active tail
    _activeTail += delta;

    // Segment completed paragraphs / code fences
    final completedBlock = _segmentBlocks(insideCodeFence);

    // Table detection: hold off flushes if in an uncompleted table row
    final tableRowInProgress = !insideCodeFence && _isTableRowInProgress(delta);

    if (completedBlock) {
      // Immediate 0ms flush on paragraph/fence boundary!
      _flushTimer?.cancel();
      _flushTimer = null;
      _emitSnapshotNow();
      return;
    }

    if (tableRowInProgress) {
      _flushTimer?.cancel();
      _flushTimer = Timer(tableHoldInterval, _emitSnapshotNow);
      return;
    }

    // Paragraph-by-paragraph cadence:
    // Do NOT flush token-by-token. Schedule a fallback flush only if
    // a continuous paragraph produces text for >1200ms without reaching
    // a paragraph boundary (\n\n).
    if (!(_flushTimer?.isActive ?? false)) {
      _flushTimer = Timer(paragraphFallbackInterval, _emitSnapshotNow);
    }
  }

  /// Incremental code-fence detection
  void _updateFenceCount(String delta) {
    var idx = 0;
    while (true) {
      final backticks = delta.indexOf('```', idx);
      final tildes = delta.indexOf('~~~', idx);
      var found = -1;
      if (backticks != -1 && tildes != -1) {
        found = backticks < tildes ? backticks : tildes;
      } else if (backticks != -1) {
        found = backticks;
      } else if (tildes != -1) {
        found = tildes;
      }

      if (found == -1) break;
      _fenceCount++;
      idx = found + 3;
    }
  }

  bool _isFenceStart(String str) {
    return str.startsWith('```') || str.startsWith('~~~');
  }

  int _findClosingFence(String str, int startIndex, String marker) {
    var searchPos = startIndex;
    while (true) {
      final found = str.indexOf(marker, searchPos);
      if (found == -1) return -1;
      var check = found - 1;
      var spaces = 0;
      while (check >= 0 && spaces < 3 && str[check] == ' ') {
        spaces++;
        check--;
      }
      if (check < 0 || str[check] == '\n') {
        return found;
      }
      searchPos = found + 3;
    }
  }

  /// Segments completed blocks from [_activeTail] into [_finalizedBlocks].
  /// Returns true if a block was finalized during this step.
  bool _segmentBlocks(bool insideCodeFence) {
    var finalizedAny = false;

    while (true) {
      final trimmedLeading = _activeTail.trimLeft();
      if (trimmedLeading.isEmpty) break;

      final startsWithFence = _isFenceStart(trimmedLeading);

      if (startsWithFence) {
        final fenceMarker = trimmedLeading.startsWith('```') ? '```' : '~~~';
        final firstNewline = trimmedLeading.indexOf('\n');
        if (firstNewline == -1) break;

        final closingIndex = _findClosingFence(trimmedLeading, firstNewline, fenceMarker);
        if (closingIndex == -1) break;

        final afterClosingFence = closingIndex + 3;
        if (afterClosingFence < trimmedLeading.length) {
          final nextChar = trimmedLeading[afterClosingFence];
          if (nextChar != '\n' && nextChar != '\r' && nextChar != ' ') {
            break;
          }
        }

        var endOfClosingLine = trimmedLeading.indexOf('\n', closingIndex);
        if (endOfClosingLine == -1) {
          endOfClosingLine = trimmedLeading.length;
        } else {
          endOfClosingLine++;
        }

        final completedBlock = trimmedLeading.substring(0, endOfClosingLine).trim();
        _finalizedBlocks.add(completedBlock);
        finalizedAny = true;

        final offsetInActiveTail = _activeTail.indexOf(trimmedLeading) + endOfClosingLine;
        _activeTail = offsetInActiveTail < _activeTail.length
            ? _activeTail.substring(offsetInActiveTail)
            : '';
        continue;
      }

      final doubleNlIndex = _activeTail.indexOf('\n\n');
      final fenceBacktickIndex = _activeTail.indexOf('\n```');
      final fenceTildeIndex = _activeTail.indexOf('\n~~~');

      var earliestFence = -1;
      if (fenceBacktickIndex != -1 && fenceTildeIndex != -1) {
        earliestFence = fenceBacktickIndex < fenceTildeIndex
            ? fenceBacktickIndex
            : fenceTildeIndex;
      } else if (fenceBacktickIndex != -1) {
        earliestFence = fenceBacktickIndex;
      } else if (fenceTildeIndex != -1) {
        earliestFence = fenceTildeIndex;
      }

      if (earliestFence != -1 &&
          (doubleNlIndex == -1 || earliestFence < doubleNlIndex)) {
        final completed = _activeTail.substring(0, earliestFence).trim();
        _activeTail = _activeTail.substring(earliestFence + 1);
        if (completed.isNotEmpty) {
          _finalizedBlocks.add(completed);
          finalizedAny = true;
        }
        continue;
      }

      if (doubleNlIndex != -1) {
        final completed = _activeTail.substring(0, doubleNlIndex).trim();
        _activeTail = _activeTail.substring(doubleNlIndex + 2);
        if (completed.isNotEmpty) {
          _finalizedBlocks.add(completed);
          finalizedAny = true;
        }
        continue;
      }

      break;
    }

    return finalizedAny;
  }

  /// Checks if the active tail is currently midway through an incomplete table row.
  bool _isTableRowInProgress(String delta) {
    if (delta.contains('\n')) {
      final combined = _tableTail + delta;
      final lastNl = combined.lastIndexOf('\n');
      _tableTail = combined.substring(lastNl + 1);
      if (_tableTail.length > 2048) {
        _tableTail = _tableTail.substring(_tableTail.length - 2048);
      }
    } else {
      _tableTail += delta;
      if (_tableTail.length > 2048) {
        _tableTail = _tableTail.substring(_tableTail.length - 2048);
      }
    }

    final trimmed = _tableTail.trimLeft();
    return trimmed.startsWith('|') &&
        !trimmed.startsWith('|-') &&
        _tableTail.trim().length > 1;
  }

  /// Cancels any scheduled flush and emits the current snapshot immediately.
  void flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _emitSnapshotNow();
  }

  void _emitSnapshotNow() {
    _flushTimer = null;
    if (onUpdate == null) return;

    final trimmedActive = _activeTail.trim();
    final healedTail = trimmedActive.isEmpty ? '' : healMarkdown(trimmedActive);

    final displayBlocks = <String>[
      ..._finalizedBlocks,
      if (healedTail.isNotEmpty) healedTail,
    ];

    final fullDisplayText = hasContent
        ? (displayBlocks.isEmpty
            ? healedTail
            : displayBlocks.join('\n\n'))
        : placeholderLabel;

    final snapshot = StreamingSnapshot(
      finalizedBlocks: List.unmodifiable(_finalizedBlocks),
      activeTail: _activeTail,
      healedTail: healedTail,
      displayBlocks: List.unmodifiable(displayBlocks),
      fullPristineText: _fullPristineBuffer.toString(),
      fullDisplayText: fullDisplayText,
      status: _status,
      placeholderLabel: placeholderLabel,
      hasContent: hasContent,
    );

    onUpdate!(snapshot);
  }

  /// Finalizes the stream and returns the clean, pristine final text.
  /// Any remaining active tail is moved to finalized blocks.
  String finalize() {
    _flushTimer?.cancel();
    _flushTimer = null;

    final remaining = _activeTail.trim();
    if (remaining.isNotEmpty) {
      _finalizedBlocks.add(remaining);
      _activeTail = '';
    }

    return _fullPristineBuffer.toString().trim();
  }

  /// Finalizes when the generation was stopped early by the user.
  /// Formats partial text with "(stopped)" marker or returns empty string.
  String finalizeStopped() {
    final pristine = finalize();
    if (pristine.isEmpty) return '';
    return '$pristine\n\n_(stopped)_';
  }

  /// Resets the service for a new turn or turn reset.
  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _status = StreamingAssistantStatus.working;
    _retryAttempt = null;
    _isCompacting = false;
    _isReasoning = false;
    _fullPristineBuffer.clear();
    _finalizedBlocks.clear();
    _activeTail = '';
    _fenceCount = 0;
    _tableTail = '';
  }

  /// Cancels any pending timers without clearing accumulated state.
  void cancel() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Disposes of any resources.
  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Virtual Markdown Tag Healing (Remend in Pure Dart)
  // ---------------------------------------------------------------------------

  /// Inspects [markdown] for unclosed formatting delimiters (code fences, inline
  /// code, bold, italic, strikethrough, math, unclosed links) and appends
  /// virtual closing markers strictly for display.
  ///
  /// The underlying text buffer is never altered; this runs only during rendering
  /// to eliminate Flash of Incomplete Markdown (FOIM) and layout jitter.
  static String healMarkdown(String markdown) {
    if (markdown.isEmpty) return markdown;

    final length = markdown.length;
    var inFence = false;
    String? fenceMarker; // '```' or '~~~'
    var inInlineCode = false;
    final emphasisStack = <String>[];
    var inLinkText = false;
    var inLinkUrl = false;

    var i = 0;
    while (i < length) {
      // 1. Check for code fence start/end at line boundary
      final isLineStart = i == 0 || markdown[i - 1] == '\n';
      if (isLineStart) {
        // Optional leading spaces up to 3
        var spaceCount = 0;
        var checkPos = i;
        while (checkPos < length && spaceCount < 3 && markdown[checkPos] == ' ') {
          spaceCount++;
          checkPos++;
        }

        if (checkPos + 2 < length) {
          final prefix = markdown.substring(checkPos, checkPos + 3);
          if (prefix == '```' || prefix == '~~~') {
            if (!inFence) {
              inFence = true;
              fenceMarker = prefix;
              // Skip past the opening fence
              i = checkPos + 3;
              continue;
            } else if (fenceMarker == prefix) {
              inFence = false;
              fenceMarker = null;
              i = checkPos + 3;
              continue;
            }
          }
        }
      }

      if (inFence) {
        i++;
        continue;
      }

      final char = markdown[i];

      // 2. Escaped characters
      if (char == '\\' && i + 1 < length) {
        i += 2;
        continue;
      }

      // 3. Inline code
      if (char == '`') {
        inInlineCode = !inInlineCode;
        i++;
        continue;
      }

      if (inInlineCode) {
        i++;
        continue;
      }

      // 4. Strikethrough (~~)
      if (char == '~' && i + 1 < length && markdown[i + 1] == '~') {
        if (emphasisStack.isNotEmpty && emphasisStack.last == '~~') {
          emphasisStack.removeLast();
        } else {
          emphasisStack.add('~~');
        }
        i += 2;
        continue;
      }

      // 5. Math blocks ($$ or $)
      if (char == '\$') {
        if (i + 1 < length && markdown[i + 1] == '\$') {
          if (emphasisStack.isNotEmpty && emphasisStack.last == '\$\$') {
            emphasisStack.removeLast();
          } else {
            emphasisStack.add('\$\$');
          }
          i += 2;
          continue;
        } else {
          if (emphasisStack.isNotEmpty && emphasisStack.last == '\$') {
            emphasisStack.removeLast();
          } else {
            emphasisStack.add('\$');
          }
          i++;
          continue;
        }
      }

      // 6. Bold & Italic (* and _)
      if (char == '*' || char == '_') {
        // Count consecutive matching characters
        var count = 0;
        var pos = i;
        while (pos < length && markdown[pos] == char) {
          count++;
          pos++;
        }

        // Check if this is a list bullet (e.g. "* item" or "- item")
        final isBullet = char == '*' &&
            count == 1 &&
            (i == 0 || markdown[i - 1] == '\n') &&
            pos < length &&
            markdown[pos] == ' ';

        if (!isBullet) {
          final token = count >= 3
              ? (char * 3)
              : (count == 2 ? (char * 2) : char);

          if (emphasisStack.isNotEmpty && emphasisStack.last == token) {
            emphasisStack.removeLast();
          } else {
            emphasisStack.add(token);
          }
        }

        i = pos;
        continue;
      }

      // 7. Links [text](url)
      if (char == '[') {
        inLinkText = true;
      } else if (char == ']') {
        inLinkText = false;
        if (i + 1 < length && markdown[i + 1] == '(') {
          inLinkUrl = true;
          i += 2;
          continue;
        }
      } else if (char == ')' && inLinkUrl) {
        inLinkUrl = false;
      }

      i++;
    }

    // Build the closing virtual markers in reverse order
    final healBuffer = StringBuffer();

    if (inLinkUrl) {
      healBuffer.write(')');
    } else if (inLinkText) {
      healBuffer.write(']');
    }

    for (var j = emphasisStack.length - 1; j >= 0; j--) {
      healBuffer.write(emphasisStack[j]);
    }

    if (inInlineCode) {
      healBuffer.write('`');
    }

    if (inFence) {
      if (!markdown.endsWith('\n')) {
        healBuffer.write('\n');
      }
      healBuffer.write(fenceMarker ?? '```');
    }

    return healBuffer.isEmpty ? markdown : '$markdown${healBuffer.toString()}';
  }
}
