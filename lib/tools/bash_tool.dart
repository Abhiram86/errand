import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent/tool.dart';
import '../llm/llm_client.dart';
import '../services/shell_service.dart';
import '../types/tool.dart';
import 'file_tools.dart';

/// Tool that executes shell commands on-device via `/system/bin/sh` (or host shell).
///
/// Provides access to Android Toybox and Toolbox CLI utilities (`ls`, `cat`,
/// `grep`, `find`, `sed`, `awk`, `cut`, `sort`, `uniq`, `wc`, `tr`, `head`,
/// `tail`, `mkdir`, `cp`, `mv`, `rm`, `tar`, `gzip`, `df`, `du`, `ps`, etc.).
///
/// Execution runs within the application process UID and defaults to
/// [workingDirectory.current]. Enforces per-command timeouts (30s default)
/// and Draft-first safety policies (blocks fork bombs, su, reboot; requires
/// `confirm_destructive: true` for bulk deletions and `rm -rf`).
Tool bashTool({
  required WorkingDirectory workingDirectory,
  ShellService? shellService,
  CancelToken Function()? getCancelToken,
}) {
  final svc = shellService ?? ShellService();

  return Tool(
    name: 'bash',
    onDispose: () => svc.dispose(),
    description:
        'Executes a shell command on-device via Android shell (/system/bin/sh). '
        'Provides access to Android Toybox/Toolbox utilities (ls, cat, grep, find, '
        'sed, awk, cut, sort, uniq, wc, tr, head, tail, mkdir, cp, mv, rm, tar, '
        'gzip, df, du, ps, etc.). Commands execute in the active working directory '
        '(defaults to current workspace directory). '
        'Enforces a default 30s timeout and Draft safety policies (dangerous '
        'commands like su, reboot, and fork bombs are strictly blocked; destructive '
        'mutations like rm -rf require confirm_destructive: true).',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'The shell command line to execute.',
        },
        'working_directory': {
          'type': 'string',
          'description':
              'Optional directory to execute the command in. Defaults to the current '
              'workspace directory. Relative paths resolve against the current working directory.',
        },
        'timeout_seconds': {
          'type': 'integer',
          'description':
              'Execution timeout in seconds (default 30, minimum 1, maximum 120).',
          'minimum': 1,
          'maximum': 120,
          'default': 30,
        },
        'confirm_destructive': {
          'type': 'boolean',
          'description':
              'Set to true to confirm execution of a potentially destructive command '
              '(e.g. recursive rm -r or wildcard deletion) after receiving user consent.',
          'default': false,
        },
      },
      'required': ['command'],
    },
    handler: (call) async {
      final command = (call.arguments['command'] as String?)?.trim();
      if (command == null || command.isEmpty) {
        return ToolCallResult.failure(call.id, 'Command cannot be empty.');
      }

      Directory execDir = workingDirectory.current;
      final rawWorkingDir = (call.arguments['working_directory'] as String?)?.trim();
      if (rawWorkingDir != null && rawWorkingDir.isNotEmpty) {
        final resolvedPath = p.isAbsolute(rawWorkingDir)
            ? p.normalize(rawWorkingDir)
            : p.normalize(p.join(workingDirectory.current.path, rawWorkingDir));

        final targetDir = Directory(resolvedPath);
        if (!await targetDir.exists()) {
          return ToolCallResult.failure(
            call.id,
            'Directory does not exist: $resolvedPath',
          );
        }
        execDir = targetDir;
        workingDirectory.current = targetDir;
      } else {
        if (!await execDir.exists()) {
          try {
            await execDir.create(recursive: true);
          } catch (_) {
            if (await workingDirectory.root.exists()) {
              execDir = workingDirectory.root;
            }
          }
        }
      }

      final timeoutSecs = ((call.arguments['timeout_seconds'] as num?)?.toInt() ?? 30)
          .clamp(1, 120);
      final confirmDestructive = call.arguments['confirm_destructive'] == true;

      try {
        final result = await svc.execute(
          command,
          workingDirectory: execDir,
          timeout: Duration(seconds: timeoutSecs),
          cancelToken: getCancelToken?.call(),
          confirmDestructive: confirmDestructive,
        );

        if (result.cancelled) {
          return ToolCallResult.failure(
            call.id,
            'Command execution was cancelled.',
            type: 'cancelled',
          );
        }

        if (result.timedOut) {
          return ToolCallResult.failure(
            call.id,
            'Command timed out after $timeoutSecs seconds.\n${result.toFormattedOutput(command: command, workingDirectory: execDir)}',
            type: 'timeout',
          );
        }

        if (result.exitCode == 0) {
          final cdMatch = RegExp(r'^cd(?:\s+(.+))?$').firstMatch(command);
          if (cdMatch != null) {
            var rawTarget = cdMatch.group(1)?.trim();
            if (rawTarget != null &&
                ((rawTarget.startsWith('"') && rawTarget.endsWith('"')) ||
                    (rawTarget.startsWith("'") && rawTarget.endsWith("'"))) &&
                rawTarget.length >= 2) {
              rawTarget = rawTarget.substring(1, rawTarget.length - 1);
            }
            final targetPath = (rawTarget == null || rawTarget.isEmpty || rawTarget == '~')
                ? workingDirectory.root.path
                : rawTarget;
            final resolvedPath = p.isAbsolute(targetPath)
                ? p.normalize(targetPath)
                : p.normalize(p.join(execDir.path, targetPath));
            final targetDir = Directory(resolvedPath);
            if (await targetDir.exists()) {
              workingDirectory.current = targetDir;
              execDir = targetDir;
            }
          }
        }

        return ToolCallResult(
          id: call.id,
          ok: true,
          output: result.toFormattedOutput(
            command: command,
            workingDirectory: execDir,
          ),
        );
      } on ShellSecurityException catch (e) {
        return ToolCallResult.failure(
          call.id,
          'BLOCKED (SECURITY POLICY): ${e.message}',
          type: 'security_blocked',
        );
      } on ShellDraftConfirmationException catch (e) {
        return ToolCallResult.failure(
          call.id,
          e.toString(),
          type: 'draft_confirmation_required',
        );
      } catch (e) {
        return ToolCallResult.failure(
          call.id,
          'Shell execution failed: $e',
          type: 'handler_error',
        );
      }
    },
  );
}
