import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../llm/llm_client.dart';

/// Safety classification for a shell command.
enum ShellSafetyLevel {
  /// Command is safe to execute without special confirmation.
  safe,

  /// Command performs destructive mutations (e.g. bulk deletes, rm -rf)
  /// and requires explicit confirmation under the Draft model.
  needsConfirmation,

  /// Command is strictly prohibited (e.g. fork bombs, su/root, reboot).
  blocked,
}

/// Evaluation result from analyzing a shell command.
class ShellSafetyCheck {
  final ShellSafetyLevel level;
  final String? reason;
  final String? matchedPattern;

  const ShellSafetyCheck.safe()
      : level = ShellSafetyLevel.safe,
        reason = null,
        matchedPattern = null;

  const ShellSafetyCheck.needsConfirmation({
    required this.reason,
    required this.matchedPattern,
  }) : level = ShellSafetyLevel.needsConfirmation;

  const ShellSafetyCheck.blocked({
    required this.reason,
    required this.matchedPattern,
  }) : level = ShellSafetyLevel.blocked;

  bool get isSafe => level == ShellSafetyLevel.safe;
  bool get isBlocked => level == ShellSafetyLevel.blocked;
  bool get needsConfirmation => level == ShellSafetyLevel.needsConfirmation;

  /// Analyzes a command line for dangerous operations and destructive mutations.
  static ShellSafetyCheck analyze(String command) {
    final cmd = command.trim();
    if (cmd.isEmpty) {
      return const ShellSafetyCheck.safe();
    }

    // 1. Blocked: Fork bombs
    // Classic :(){ :|:& };: or variations with arbitrary whitespace/function names
    final classicForkBomb = RegExp(r':\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:', caseSensitive: false);
    if (classicForkBomb.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Fork bombs are strictly prohibited.',
        matchedPattern: ':(){ :|:& };:',
      );
    }

    final recursiveFunctionFork = RegExp(
      r'([a-zA-Z_0-9]+)\s*\(\s*\)\s*\{\s*.*\b\1\s*\|\s*\1\b.*\}',
      caseSensitive: false,
    );
    if (recursiveFunctionFork.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Recursive self-piping fork patterns are strictly prohibited.',
        matchedPattern: 'function self-pipe',
      );
    }

    // 2. Blocked: Privilege escalation & root invocation
    final suPattern = RegExp(
      r'(?:^|[;&|`\s])(?:sudo|doas|su)(?:$|[;&|`\s])',
      caseSensitive: false,
    );
    if (suPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Privilege escalation and superuser (su/sudo) commands are strictly prohibited.',
        matchedPattern: 'su/sudo',
      );
    }

    final suPathPattern = RegExp(
      r'(?:^|[;&|`\s])(?:\/[a-zA-Z0-9_.\-]+)*\/(?:su|sudo|doas)(?:$|[;&|`\s])',
      caseSensitive: false,
    );
    if (suPathPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Direct invocation of su/sudo binaries is strictly prohibited.',
        matchedPattern: 'path/to/su',
      );
    }

    // 3. Blocked: Reboot, shutdown, power off, init changes
    final rebootPattern = RegExp(
      r'(?:^|[;&|`\s])(?:reboot|shutdown|poweroff|halt)(?:$|[;&|`\s])',
      caseSensitive: false,
    );
    if (rebootPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Reboot and system shutdown commands are strictly prohibited.',
        matchedPattern: 'reboot/shutdown',
      );
    }

    final initPattern = RegExp(r'(?:^|[;&|`\s])init\s+[06](?:$|[;&|`\s])', caseSensitive: false);
    if (initPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'System state change via init is strictly prohibited.',
        matchedPattern: 'init 0/6',
      );
    }

    final sysPowerCtlPattern = RegExp(r'setprop\s+sys\.powerctl', caseSensitive: false);
    if (sysPowerCtlPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Direct Android powerctl manipulation is strictly prohibited.',
        matchedPattern: 'setprop sys.powerctl',
      );
    }

    // 4. Blocked: Raw disk/partition formatting or device node wiping
    final mkfsPattern = RegExp(r'(?:^|[;&|`\s])mkfs(?:\.[a-zA-Z0-9_\-]+)?(?:$|[;&|`\s])', caseSensitive: false);
    if (mkfsPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Filesystem formatting (mkfs) is strictly prohibited.',
        matchedPattern: 'mkfs',
      );
    }

    final ddDevPattern = RegExp(r'\bdd\b.*(?:of\s*=\s*\/dev\/)', caseSensitive: false);
    if (ddDevPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Direct writes to raw block devices are strictly prohibited.',
        matchedPattern: 'dd of=/dev/...',
      );
    }

    final rawBlockRedirect = RegExp(r'(?:>|>>)\s*\/dev\/(?:block|mtd|sda|sdb|mmcblk)', caseSensitive: false);
    if (rawBlockRedirect.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Redirection to raw storage block devices is strictly prohibited.',
        matchedPattern: '> /dev/block',
      );
    }

    // 5. Blocked: System/root directory destruction
    final systemWipePattern = RegExp(
      r'\brm\s+.*(?:^|\s)(?:\/|\/\*|\/system|\/data|\/vendor|\/apex|\/boot|\/recovery)(?:\s|$|\/\*)',
      caseSensitive: false,
    );
    if (systemWipePattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.blocked(
        reason: 'Destruction of root or system directories is strictly prohibited.',
        matchedPattern: 'rm on root/system path',
      );
    }

    // 6. Destructive mutations (Draft model confirmation required):
    // Recursive deletions: rm -r, rm -rf, rm --recursive
    final recursiveRm = RegExp(
      r'\brm\b.*(?:\s-[a-zA-Z]*[rR][a-zA-Z]*|\s--recursive)\b',
      caseSensitive: false,
    );
    if (recursiveRm.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Recursive deletion of files or directories ("rm -r")',
        matchedPattern: 'rm -r',
      );
    }

    // Bulk deletion with wildcards: rm ... * or ?
    final wildcardRm = RegExp(r'\brm\b.*[\*\?]', caseSensitive: false);
    if (wildcardRm.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Bulk deletion with wildcards ("rm *")',
        matchedPattern: 'rm with wildcard',
      );
    }

    // Utilities performing bulk deletions: find ... -delete or find ... -exec rm
    final findDelete = RegExp(r'\bfind\b.*-delete\b', caseSensitive: false);
    if (findDelete.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Automated bulk file deletion ("find -delete")',
        matchedPattern: 'find -delete',
      );
    }

    final findExecRm = RegExp(r'\bfind\b.*-exec\s+rm\b', caseSensitive: false);
    if (findExecRm.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Automated bulk deletion via find ("find -exec rm")',
        matchedPattern: 'find -exec rm',
      );
    }

    final xargsRm = RegExp(r'\bxargs\s+(?:.*)?\brm\b', caseSensitive: false);
    if (xargsRm.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Automated bulk deletion via xargs ("xargs rm")',
        matchedPattern: 'xargs rm',
      );
    }

    // Bulk file truncation or shredding
    final shredPattern = RegExp(r'\bshred\b', caseSensitive: false);
    if (shredPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Permanent data shredding ("shred")',
        matchedPattern: 'shred',
      );
    }

    final truncateZeroPattern = RegExp(r'\btruncate\b.*-s\s*0\b', caseSensitive: false);
    if (truncateZeroPattern.hasMatch(cmd)) {
      return const ShellSafetyCheck.needsConfirmation(
        reason: 'Truncating files to zero bytes ("truncate -s 0")',
        matchedPattern: 'truncate -s 0',
      );
    }

    return const ShellSafetyCheck.safe();
  }
}

/// Exception thrown when a command violates security boundaries.
class ShellSecurityException implements Exception {
  final String message;
  const ShellSecurityException(this.message);

  @override
  String toString() => 'ShellSecurityException: $message';
}

/// Exception thrown when a destructive mutation is requested without confirmation.
class ShellDraftConfirmationException implements Exception {
  final String reason;
  const ShellDraftConfirmationException(this.reason);

  @override
  String toString() =>
      'REFUSED (DRAFT POLICY): Potentially destructive command detected: $reason. '
      'Errand adheres to a Draft-first policy. Explain what will be deleted to the user and re-run with confirm_destructive: true only after receiving explicit user confirmation.';
}

/// Execution outcome of a shell command.
class ShellResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool cancelled;

  const ShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.cancelled = false,
  });

  bool get isSuccess => exitCode == 0 && !timedOut && !cancelled;

  /// Formats the result as structured text. Reserves the leading metadata
  /// header block (ending with an empty line) so [ToolOutputFileService]
  /// keeps Command, Working directory, and Exit code in previews.
  String toFormattedOutput({String? command, Directory? workingDirectory}) {
    final buffer = StringBuffer();
    if (command != null) {
      buffer.writeln('Command: $command');
    }
    if (workingDirectory != null) {
      buffer.writeln('Working directory: ${workingDirectory.path}');
    }
    buffer.writeln('Exit code: $exitCode');
    if (timedOut) {
      buffer.writeln('Status: TIMED OUT');
    } else if (cancelled) {
      buffer.writeln('Status: CANCELLED');
    }
    buffer.writeln(); // Metadata header boundary for ToolOutputFileService

    final cleanStdout = stdout.trimRight();
    final cleanStderr = stderr.trimRight();

    if (cleanStdout.isNotEmpty) {
      buffer.writeln(cleanStdout);
    }
    if (cleanStderr.isNotEmpty) {
      if (cleanStdout.isNotEmpty) buffer.writeln();
      buffer.writeln('stderr:');
      buffer.writeln(cleanStderr);
    }
    if (cleanStdout.isEmpty && cleanStderr.isEmpty) {
      buffer.writeln('(no output)');
    }

    return buffer.toString().trimRight();
  }
}

/// On-device shell execution service running commands via `/system/bin/sh` (or host shell).
class ShellService {
  final String? _configuredExecutable;
  final Duration defaultTimeout;
  final int maxOutputChars;

  final Set<Process> _activeProcesses = {};

  ShellService({
    String? executable,
    this.defaultTimeout = const Duration(seconds: 30),
    this.maxOutputChars = 512 * 1024,
  }) : _configuredExecutable = executable;

  /// Default executable path: `/system/bin/sh` on Android when present, otherwise `sh`.
  String get executable {
    if (_configuredExecutable != null) return _configuredExecutable;
    if (Platform.isAndroid && File('/system/bin/sh').existsSync()) {
      return '/system/bin/sh';
    }
    return 'sh';
  }

  /// Executes [command] in [workingDirectory] with timeout and cancellation support.
  Future<ShellResult> execute(
    String command, {
    Directory? workingDirectory,
    Duration? timeout,
    CancelToken? cancelToken,
    bool confirmDestructive = false,
  }) async {
    // 1. Safety check
    final safetyCheck = ShellSafetyCheck.analyze(command);
    if (safetyCheck.isBlocked) {
      throw ShellSecurityException(
        safetyCheck.reason ?? 'Command is blocked by security policy.',
      );
    }
    if (safetyCheck.needsConfirmation && !confirmDestructive) {
      throw ShellDraftConfirmationException(
        safetyCheck.reason ?? 'Command performs destructive operations.',
      );
    }

    // 2. Cancellation check before start
    if (cancelToken?.isCancelled ?? false) {
      return const ShellResult(
        exitCode: -1,
        stdout: '',
        stderr: '',
        cancelled: true,
      );
    }

    final execDir = workingDirectory ?? Directory.current;
    final effTimeout = timeout ?? defaultTimeout;

    // 3. Environment configuration
    Map<String, String>? env;
    if (Platform.isAndroid) {
      final currentPath = Platform.environment['PATH'] ?? '';
      final standardAndroidPaths = ['/system/bin', '/system/xbin', '/vendor/bin'];
      final combined = [
        if (currentPath.isNotEmpty) currentPath,
        ...standardAndroidPaths.where((p) => !currentPath.contains(p)),
      ].join(':');
      env = {'PATH': combined};
    }

    // 4. Start process
    final Process process;
    try {
      process = await Process.start(
        executable,
        ['-c', command],
        workingDirectory: execDir.path,
        environment: env,
        runInShell: false,
      );
    } catch (e) {
      return ShellResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Failed to start shell process ($executable): $e',
      );
    }

    _activeProcesses.add(process);

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    var stdoutChars = 0;
    var stderrChars = 0;
    var truncated = false;

    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    final stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (chunk) {
        if (stdoutChars + chunk.length <= maxOutputChars) {
          stdoutBuffer.write(chunk);
          stdoutChars += chunk.length;
        } else if (!truncated) {
          final remaining = maxOutputChars - stdoutChars;
          if (remaining > 0) {
            stdoutBuffer.write(chunk.substring(0, remaining));
            stdoutChars += remaining;
          }
          stdoutBuffer.write(
            '\n[...output truncated: exceeded maximum limit of ${maxOutputChars ~/ 1024} KB...]',
          );
          truncated = true;
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      },
      onDone: () {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      onError: (_) {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
    );

    final stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (chunk) {
        if (stderrChars + chunk.length <= maxOutputChars) {
          stderrBuffer.write(chunk);
          stderrChars += chunk.length;
        } else if (!truncated) {
          final remaining = maxOutputChars - stderrChars;
          if (remaining > 0) {
            stderrBuffer.write(chunk.substring(0, remaining));
            stderrChars += remaining;
          }
          stderrBuffer.write(
            '\n[...stderr truncated: exceeded maximum limit of ${maxOutputChars ~/ 1024} KB...]',
          );
          truncated = true;
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      },
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      onError: (_) {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
    );

    var timedOut = false;
    var cancelled = false;

    void onCancel() {
      cancelled = true;
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }

    cancelToken?.addListener(onCancel);

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(
        effTimeout,
        onTimeout: () {
          timedOut = true;
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
          return -1;
        },
      );
    } catch (_) {
      exitCode = -1;
    } finally {
      cancelToken?.removeListener(onCancel);
      _activeProcesses.remove(process);

      // Give streams a short grace period to flush
      await Future.wait([
        stdoutDone.future,
        stderrDone.future,
      ]).timeout(const Duration(milliseconds: 300), onTimeout: () => []);

      await stdoutSub.cancel().catchError((_) {});
      await stderrSub.cancel().catchError((_) {});
    }

    return ShellResult(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
      timedOut: timedOut,
      cancelled: cancelled,
    );
  }

  /// Disposes resources and terminates any currently running processes.
  void dispose() {
    for (final process in {..._activeProcesses}) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    _activeProcesses.clear();
  }
}
