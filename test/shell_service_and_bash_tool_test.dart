import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/services/shell_service.dart';
import 'package:errand/tools/bash_tool.dart';
import 'package:errand/tools/file_tools.dart';

void main() {
  group('ShellSafetyCheck', () {
    test('identifies safe commands', () {
      final safeCommands = [
        'echo "hello world"',
        'ls -la',
        'pwd',
        'cat README.md',
        'grep -rn "TODO" .',
        'mkdir -p test_dir/sub',
        'touch file.txt',
        'cp a.txt b.txt',
        'mv a.txt b.txt',
        'rm single_file.txt',
        'df -h',
        'ps -ef',
        'tar -czf archive.tar.gz file.txt',
      ];

      for (final cmd in safeCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isSafe, isTrue, reason: 'Command "$cmd" should be safe');
        expect(check.isBlocked, isFalse);
        expect(check.needsConfirmation, isFalse);
      }
    });

    test('blocks fork bombs', () {
      final forkBombs = [
        ':(){ :|:& };:',
        ':(){ : | : & }; :',
        'bomb() { bomb | bomb & }; bomb',
      ];

      for (final cmd in forkBombs) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: 'Fork bomb "$cmd" should be blocked');
      }
    });

    test('blocks privilege escalation / su / sudo', () {
      final suCommands = [
        'su',
        'su root',
        'echo hi; su',
        'sudo rm file',
        'doas ls',
        '/system/bin/su',
        '/system/xbin/su',
      ];

      for (final cmd in suCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: 'Command "$cmd" should be blocked');
      }

      // Words containing 'su' as substring must NOT be blocked
      final nonSuCommands = [
        'echo super',
        'touch resume.txt',
        'cat issue.md',
        'grep consult file',
      ];
      for (final cmd in nonSuCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isFalse, reason: 'Command "$cmd" should not be blocked');
      }
    });

    test('blocks system reboot and shutdown', () {
      final rebootCommands = [
        'reboot',
        'reboot recovery',
        'shutdown -h now',
        'poweroff',
        'halt',
        'init 0',
        'init 6',
        'setprop sys.powerctl reboot',
      ];

      for (final cmd in rebootCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: 'Command "$cmd" should be blocked');
      }
    });

    test('blocks raw disk formatting and block device wipes', () {
      final diskCommands = [
        'mkfs /dev/block/bootdevice',
        'mkfs.ext4 /dev/block/sda',
        'dd if=/dev/zero of=/dev/block/bootdevice',
        'echo 0 > /dev/block/mmcblk0',
      ];

      for (final cmd in diskCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: 'Command "$cmd" should be blocked');
      }
    });

    test('blocks root or system directory destruction', () {
      final rootWipes = [
        'rm -rf /',
        'rm -rf /*',
        'rm -rf /system',
        'rm -rf /data',
        'rm -rf /vendor',
      ];

      for (final cmd in rootWipes) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: 'Command "$cmd" should be blocked');
      }
    });

    test('flags destructive mutations as needing confirmation', () {
      final destructiveCommands = [
        'rm -r my_dir',
        'rm -rf /storage/emulated/0/Download/old',
        'rm --recursive cache',
        'rm *.tmp',
        'rm -f /storage/emulated/0/*.bak',
        'find . -name "*.log" -delete',
        'find . -type f -exec rm {} +',
        'xargs rm < files.txt',
        'shred secret.key',
        'truncate -s 0 database.db',
      ];

      for (final cmd in destructiveCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'Command "$cmd" should require confirmation');
        expect(check.isBlocked, isFalse);
      }
    });
  });

  group('ShellService', () {
    late ShellService service;
    late Directory tempDir;

    setUp(() async {
      service = ShellService();
      tempDir = await Directory.systemTemp.createTemp('errand_shell_test');
    });

    tearDown(() async {
      service.dispose();
      await tempDir.delete(recursive: true).catchError((_) => tempDir);
    });

    test('executes a basic shell command and returns output and exit code', () async {
      final result = await service.execute(
        'echo "hello from shell"',
        workingDirectory: tempDir,
      );

      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello from shell');
      expect(result.stderr, isEmpty);
      expect(result.isSuccess, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.cancelled, isFalse);
    });

    test('captures non-zero exit code and stderr', () async {
      final result = await service.execute(
        'echo "failing" >&2; exit 42',
        workingDirectory: tempDir,
      );

      expect(result.exitCode, 42);
      expect(result.stderr.trim(), 'failing');
      expect(result.isSuccess, isFalse);
    });

    test('executes within specified workingDirectory', () async {
      final subDir = Directory('${tempDir.path}/sub_workspace');
      await subDir.create();

      final result = await service.execute('pwd', workingDirectory: subDir);

      expect(result.exitCode, 0);
      expect(result.stdout.trim(), contains(subDir.path));
    });

    test('throws ShellSecurityException for blocked commands', () async {
      expect(
        () => service.execute('reboot', workingDirectory: tempDir),
        throwsA(isA<ShellSecurityException>()),
      );

      expect(
        () => service.execute('su -c id', workingDirectory: tempDir),
        throwsA(isA<ShellSecurityException>()),
      );
    });

    test('throws ShellDraftConfirmationException for destructive mutations without confirmation', () async {
      expect(
        () => service.execute('rm -rf test_dir', workingDirectory: tempDir),
        throwsA(isA<ShellDraftConfirmationException>()),
      );

      expect(
        () => service.execute('rm *.log', workingDirectory: tempDir),
        throwsA(isA<ShellDraftConfirmationException>()),
      );
    });

    test('allows destructive mutations when confirmDestructive is true', () async {
      final fileToDelete = File('${tempDir.path}/to_delete.txt');
      await fileToDelete.writeAsString('bye');

      final result = await service.execute(
        'rm -f "${tempDir.path}"/*.txt',
        workingDirectory: tempDir,
        confirmDestructive: true,
      );

      expect(result.exitCode, 0);
      expect(await fileToDelete.exists(), isFalse);
    });

    test('enforces per-command timeout and terminates process', () async {
      final result = await service.execute(
        'sleep 10',
        workingDirectory: tempDir,
        timeout: const Duration(milliseconds: 300),
      );

      expect(result.timedOut, isTrue);
      expect(result.isSuccess, isFalse);
    });

    test('aborts cleanly when CancelToken is cancelled', () async {
      final cancelToken = CancelToken();

      // Cancel after 100ms
      Future.delayed(const Duration(milliseconds: 100), () {
        cancelToken.cancel();
      });

      final result = await service.execute(
        'sleep 10',
        workingDirectory: tempDir,
        cancelToken: cancelToken,
      );

      expect(result.cancelled, isTrue);
      expect(result.isSuccess, isFalse);
    });

    test('truncates output if maxOutputChars is exceeded', () async {
      final limitedService = ShellService(maxOutputChars: 500);
      addTearDown(() => limitedService.dispose());

      final result = await limitedService.execute(
        // Generates ~2000 chars of output
        'for i in \$(seq 1 200); do echo "line \$i of lengthy test output"; done',
        workingDirectory: tempDir,
      );

      expect(result.stdout, contains('[...output truncated'));
      expect(result.stdout.length, lessThanOrEqualTo(1000));
    });
  });

  group('bashTool', () {
    late Directory tempDir;
    late WorkingDirectory workingDir;
    late Tool tool;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('errand_bash_tool_test');
      workingDir = WorkingDirectory(tempDir);
      tool = bashTool(workingDirectory: workingDir);
    });

    tearDown(() async {
      tool.dispose();
      await tempDir.delete(recursive: true).catchError((_) => tempDir);
    });

    test('validates missing command argument', () async {
      final result = await tool.handler(
        const ToolCall(id: 'call-1', name: 'bash', arguments: {}),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Command cannot be empty'));
    });

    test('executes a shell command successfully and formats output', () async {
      final result = await tool.handler(
        const ToolCall(
          id: 'call-2',
          name: 'bash',
          arguments: {'command': 'echo "Errand Shell Tool"'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Command: echo "Errand Shell Tool"'));
      expect(result.output, contains('Exit code: 0'));
      expect(result.output, contains('Errand Shell Tool'));
    });

    test('respects working_directory argument', () async {
      final subFolder = Directory('${tempDir.path}/custom_sub');
      await subFolder.create();

      final result = await tool.handler(
        ToolCall(
          id: 'call-3',
          name: 'bash',
          arguments: {
            'command': 'pwd',
            'working_directory': subFolder.path,
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains(subFolder.path));
    });

    test('handles relative working_directory argument', () async {
      final subFolder = Directory('${tempDir.path}/rel_sub');
      await subFolder.create();

      final result = await tool.handler(
        const ToolCall(
          id: 'call-4',
          name: 'bash',
          arguments: {
            'command': 'pwd',
            'working_directory': 'rel_sub',
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('rel_sub'));
      expect(workingDir.current.path, equals(subFolder.path));
    });

    test('persists directory when cd command succeeds', () async {
      final subFolder = Directory('${tempDir.path}/nav_sub');
      await subFolder.create();

      final cdResult = await tool.handler(
        const ToolCall(
          id: 'call-cd',
          name: 'bash',
          arguments: {'command': 'cd nav_sub'},
        ),
      );

      expect(cdResult.ok, isTrue);
      expect(workingDir.current.path, equals(subFolder.path));

      // Subsequent pwd without working_directory executes in new directory
      final pwdResult = await tool.handler(
        const ToolCall(
          id: 'call-pwd',
          name: 'bash',
          arguments: {'command': 'pwd'},
        ),
      );
      expect(pwdResult.ok, isTrue);
      expect(pwdResult.output, contains(subFolder.path));
    });

    test('fails gracefully when working_directory does not exist', () async {
      final result = await tool.handler(
        const ToolCall(
          id: 'call-5',
          name: 'bash',
          arguments: {
            'command': 'ls',
            'working_directory': 'nonexistent_folder_xyz',
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Directory does not exist'));
    });

    test('refuses dangerous command with BLOCKED security policy', () async {
      final result = await tool.handler(
        const ToolCall(
          id: 'call-6',
          name: 'bash',
          arguments: {'command': 'sudo apt-get update'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('BLOCKED (SECURITY POLICY)'));
      expect(result.error?.type, 'security_blocked');
    });

    test('refuses destructive mutation under Draft policy when unconfirmed', () async {
      final result = await tool.handler(
        const ToolCall(
          id: 'call-7',
          name: 'bash',
          arguments: {'command': 'rm -rf some_dir'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('REFUSED (DRAFT POLICY)'));
      expect(result.error?.type, 'draft_confirmation_required');
    });

    test('allows destructive mutation when confirm_destructive is true', () async {
      final testFile = File('${tempDir.path}/delete_me.txt');
      await testFile.writeAsString('data');

      final result = await tool.handler(
        ToolCall(
          id: 'call-8',
          name: 'bash',
          arguments: {
            'command': 'rm "${testFile.path}"',
            'confirm_destructive': true,
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(await testFile.exists(), isFalse);
    });

    test('handles command timeout in tool result', () async {
      final result = await tool.handler(
        const ToolCall(
          id: 'call-9',
          name: 'bash',
          arguments: {
            'command': 'sleep 10',
            'timeout_seconds': 1,
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('timed out'));
      expect(result.error?.type, 'timeout');
    });

    test('ToolRegistry.defaults includes bash in both Full and Lite configurations', () {
      final fullRegistry = ToolRegistry.defaults(
        currentDir: tempDir,
        enableA11yTools: true,
      );
      expect(fullRegistry.all.map((t) => t.name), contains('bash'));

      final liteRegistry = ToolRegistry.defaults(
        currentDir: tempDir,
        enableA11yTools: false,
      );
      expect(liteRegistry.all.map((t) => t.name), contains('bash'));
    });
  });
}
