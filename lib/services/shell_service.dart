import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../llm/llm_client.dart';

/// Safety classification for a shell command.
enum ShellSafetyLevel {
  /// Command is safe to execute without special confirmation.
  safe,

  /// Command performs destructive mutations (e.g. bulk deletes, rm -rf, mv)
  /// and requires explicit confirmation under the Draft model.
  needsConfirmation,

  /// Command is strictly prohibited (e.g. fork bombs, su/root, reboot, disk wipes).
  blocked,
}

/// Evaluation result from analyzing a shell command.
class ShellSafetyCheck {
  final ShellSafetyLevel level;
  final String? reason;
  final String? matchedPattern;

  const ShellSafetyCheck(
    this.level,
    this.reason, [
    this.matchedPattern,
  ]);

  const ShellSafetyCheck.safe([this.reason = 'Command appears safe'])
      : level = ShellSafetyLevel.safe,
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
  bool get needsConfirmation => level == ShellSafetyLevel.needsConfirmation;
  bool get isBlocked => level == ShellSafetyLevel.blocked;

  /// Analyzes a command line for dangerous operations and destructive mutations.
  static ShellSafetyCheck analyze(String command) {
    final cmd = command.trim();

    if (cmd.isEmpty) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Empty command',
      );
    }

    // Things we cannot safely reason about or that hide arbitrary code execution.
    if (_hasDangerousShellConstruct(cmd)) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'Command contains shell constructs that cannot be safely analyzed',
      );
    }

    // Inspect command substitutions $(...) and `...`
    final subcmdMatches = RegExp(r'\$\(([^)]+)\)|`([^`]+)`').allMatches(cmd);
    for (final m in subcmdMatches) {
      final inner = (m.group(1) ?? m.group(2) ?? '').trim();
      if (inner.isNotEmpty) {
        final innerResult = analyze(inner);
        if (innerResult.isBlocked) return innerResult;
        if (innerResult.needsConfirmation) return innerResult;
      }
    }

    for (final segment in _splitCommands(cmd)) {
      final result = _analyzeCommand(segment);

      if (result.isBlocked) return result;
      if (result.needsConfirmation) return result;
    }

    return const ShellSafetyCheck(
      ShellSafetyLevel.safe,
      'Command appears safe',
    );
  }

  static bool _hasDangerousShellConstruct(String cmd) {
    // Process substitution <(...) or >(...) executes commands via subshells/pipes.
    if (RegExp(r'(?:<|>)\s*\(').hasMatch(cmd)) {
      return true;
    }

    // eval/source/exec/. can hide arbitrary commands when invoked in command position.
    if (RegExp(
      r'(?:^|[;&|\n])\s*(?:eval|source|exec|\.)(?:\s+|$)',
      caseSensitive: false,
    ).hasMatch(cmd)) {
      return true;
    }

    // Classic fork bombs :(){ :|:& };:
    if (RegExp(
      r':\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:',
      caseSensitive: false,
    ).hasMatch(cmd)) {
      return true;
    }

    // Recursive function self-piping fork patterns: bomb() { bomb | bomb & }; bomb
    final recursiveFunctionFork = RegExp(
      r'([a-zA-Z_0-9]+)\s*\(\s*\)\s*\{\s*.*\b\1\s*\|\s*\1\b.*\}',
      caseSensitive: false,
    );
    if (recursiveFunctionFork.hasMatch(cmd)) {
      return true;
    }

    return false;
  }

  static List<String> _splitCommands(String command) {
    final result = <String>[];
    var start = 0;
    var quote = '';

    for (var i = 0; i < command.length; i++) {
      final c = command[i];

      if (c == '\\') {
        i++;
        continue;
      }

      if (quote.isNotEmpty) {
        if (c == quote) quote = '';
        continue;
      }

      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }

      // If '&' is part of '>&' or '&>', it's a redirect, not a command separator.
      if (c == '&' &&
          ((i > 0 && command[i - 1] == '>') ||
           (i + 1 < command.length && command[i + 1] == '>'))) {
        continue;
      }

      final isSeparator = c == ';' ||
          c == '\n' ||
          c == '|' ||
          c == '&';

      if (isSeparator) {
        final part = command.substring(start, i).trim();

        if (part.isNotEmpty) {
          result.add(part);
        }

        // Skip && / ||.
        if ((c == '&' || c == '|') &&
            i + 1 < command.length &&
            command[i + 1] == c) {
          i++;
        }

        start = i + 1;
      }
    }

    final last = command.substring(start).trim();
    if (last.isNotEmpty) result.add(last);

    return result;
  }

  static ShellSafetyCheck _analyzeCommand(String command) {
    var words = _tokenize(command);

    if (words.isEmpty) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Empty command',
      );
    }

    // Strip environment assignments (e.g. VAR=1 cmd).
    while (words.length > 1 && _isAssignment(words.first)) {
      words = words.sublist(1);
    }

    if (words.isEmpty) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Environment assignment only',
      );
    }

    // Shell control keywords (for, do, done, if, then, else, fi, while, until)
    final firstWord = words.first;
    if (firstWord == 'done' || firstWord == 'then' || firstWord == 'else' || firstWord == 'fi') {
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Shell syntax keyword',
      );
    }
    if (firstWord == 'for') {
      // Loop header: for var in ...
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Shell loop header',
      );
    }
    if (firstWord == 'do' || firstWord == 'if' || firstWord == 'while' || firstWord == 'until') {
      if (words.length > 1) {
        return _analyzeCommand(words.sublist(1).join(' '));
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Shell syntax keyword',
      );
    }

    // Treat unanalyzable variable expansion in executable/command position as untrusted.
    if (words.first.startsWith(r'$') ||
        RegExp(r'^\$\{[^}]+\}').hasMatch(words.first)) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Command uses dynamic variable expansion in executable position and cannot be statically verified',
      );
    }

    // Common command wrappers.
    const wrappers = {
      'sudo',
      'doas',
      'su',
      'nohup',
      'nice',
      'ionice',
      'timeout',
      'setsid',
      'stdbuf',
      'time',
    };

    final executable = _basename(words.first);

    // Block privilege escalation binaries even when prefixed by path.
    if (executable == 'sudo' ||
        executable == 'doas' ||
        executable == 'su' ||
        words.first.endsWith('/su') ||
        words.first.endsWith('/sudo') ||
        words.first.endsWith('/doas')) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'Privilege escalation is not allowed',
        'su/sudo',
      );
    }

    if (executable == 'env') {
      var idx = 1;
      while (idx < words.length) {
        final w = words[idx];
        if (w == '-i' || w == '--ignore-environment' || w == '-') {
          idx++;
        } else if (w == '-u' || w == '--unset') {
          idx += 2;
        } else if (w.startsWith('-u') || w.startsWith('--unset=')) {
          idx++;
        } else if (w.startsWith('-')) {
          idx++;
        } else if (_isAssignment(w)) {
          idx++;
        } else {
          break;
        }
      }
      if (idx < words.length) {
        return _analyzeCommand(words.sublist(idx).join(' '));
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Environment print only',
      );
    }

    if (wrappers.contains(executable)) {
      // Find the first obvious command after wrapper arguments.
      for (var i = 1; i < words.length; i++) {
        if (!words[i].startsWith('-') &&
            !_looksLikeWrapperValue(words[i])) {
          return _analyzeCommand(words.sublist(i).join(' '));
        }
      }

      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Unable to safely determine wrapped command',
      );
    }

    // sh -c "...", bash -c "...", etc.
    if ({
      'sh',
      'bash',
      'zsh',
      'dash',
      'ash',
      'ksh',
    }.contains(executable)) {
      final cIndex = words.indexOf('-c');

      if (cIndex >= 0 && cIndex + 1 < words.length) {
        final nested = words[cIndex + 1];

        for (final part in _splitCommands(nested)) {
          final result = _analyzeCommand(part);

          if (result.isBlocked) return result;
          if (result.needsConfirmation) return result;
        }

        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Nested shell command appears safe',
        );
      }

      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Shell invocation requires confirmation',
      );
    }

    // busybox rm ...
    if (executable == 'busybox' || executable == 'toybox') {
      if (words.length > 1) {
        return _analyzeCommand(words.sublist(1).join(' '));
      }
    }

    // command rm ...
    if (executable == 'command' && words.length > 1) {
      return _analyzeCommand(words.sublist(1).join(' '));
    }

    // xargs can turn a harmless-looking command into bulk deletion.
    if (executable == 'xargs') {
      final rm = words.any((w) {
        final base = _basename(w);
        return base == 'rm' || base == 'rmdir';
      });

      if (rm) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Automated bulk deletion via xargs ("xargs rm")',
          'xargs rm',
        );
      }

      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'xargs executes commands dynamically',
      );
    }

    return _analyzeDirectCommand(words);
  }

  // Inverted Allowlist of safe, non-destructive utilities in Android shell / Toybox.
  static const _safeAllowedCommands = <String>{
    // File / Directory navigation & inspection
    'ls', 'dir', 'vdir', 'pwd', 'cd', 'pushd', 'popd', 'dirs',
    'which', 'whereis', 'type', 'file', 'stat', 'whoami', 'id', 'groups',

    // File reading & text viewing
    'cat', 'head', 'tail', 'more', 'less', 'strings', 'nl', 'tac', 'rev',
    'od', 'hexdump', 'xxd', 'base64',

    // Searching, text processing & filtering
    'grep', 'egrep', 'fgrep', 'awk', 'cut', 'sort', 'uniq', 'wc',
    'tr', 'fold', 'paste', 'column', 'comm', 'cmp', 'diff', 'join', 'fmt',
    'pr', 'expand', 'unexpand', 'dos2unix', 'unix2dos',

    // Printing, flow, logic & math
    'echo', 'printf', 'true', 'false', 'test', '[', 'expr', 'seq', 'sleep',
    'usleep', 'bc', 'yes', 'exit', 'return',

    // Path manipulation & checksums
    'basename', 'dirname', 'realpath', 'readlink',
    'md5sum', 'sha1sum', 'sha224sum', 'sha256sum', 'sha384sum', 'sha512sum',
    'cksum', 'crc32',

    // Dates, times & system / network inspection (heavily used on Android)
    'date', 'cal', 'uptime', 'uname', 'hostname', 'arch', 'df', 'du',
    'ps', 'top', 'free', 'vmstat', 'iostat', 'netstat', 'ss', 'ip',
    'ifconfig', 'arp', 'route', 'printenv', 'export',

    // Safe compression / archiving
    'tar', 'gzip', 'gunzip', 'bzip2', 'bunzip2', 'xz', 'unxz', 'zip', 'unzip', 'zcat',

    // Android-specific system inspection
    'getprop', 'dumpsys', 'logcat',
  };

  static ShellSafetyCheck _analyzeDirectCommand(
    List<String> words,
  ) {
    final command = _basename(words.first);
    final args = words.sublist(1);

    // Commands that can obviously destroy/control the system.
    if ({
      'reboot',
      'shutdown',
      'poweroff',
      'halt',
      'mkfs',
      'wipefs',
      'blkdiscard',
      'fdisk',
      'parted',
      'sgdisk',
      'sfdisk',
      'mkswap',
    }.contains(command) || command.startsWith('mkfs.')) {
      return ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        '$command is not allowed',
        command,
      );
    }

    // Android/system property power control.
    if (command == 'setprop' && args.contains('sys.powerctl')) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'System power control is not allowed',
        'setprop sys.powerctl',
      );
    }

    // System state change via init 0 or init 6.
    if (command == 'init' && (args.contains('0') || args.contains('6'))) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'System state change via init is not allowed',
        'init',
      );
    }

    // dd to a block device or bulk overwrite.
    if (command == 'dd') {
      for (final arg in args) {
        if (arg.startsWith('of=')) {
          final target = arg.substring(3);

          if (_isBlockDevice(target)) {
            return const ShellSafetyCheck(
              ShellSafetyLevel.blocked,
              'dd writes directly to a block device',
              'dd',
            );
          }
        }
      }

      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'dd can overwrite large amounts of data',
        'dd',
      );
    }

    // Redirecting into a system path or block device.
    for (final target in _redirectTargets(words)) {
      if (_isBlockDevice(target)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Redirect writes directly to a block device',
          '> /dev/block',
        );
      }

      if (_isSystemPath(target)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Writing to a system path is not allowed',
          'system path write',
        );
      }
    }

    // File deletion (rm / rmdir)
    if (command == 'rm' || command == 'rmdir') {
      final targets = args
          .where((x) => !x.startsWith('-'))
          .toList();

      if (targets.any(_isSystemPath) || targets.any(_isBlockDevice)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Deleting system paths is not allowed',
          'rm on root/system path',
        );
      }

      if (_isScratchOnlyList(targets)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Scratch directory deletion',
        );
      }

      final recursive = args.any(
        (x) => x == '--recursive' || x.contains('r') || x.contains('R'),
      );

      final wildcard = targets.any(
        (x) => x.contains('*') || x.contains('?'),
      );

      if (recursive || wildcard) {
        return ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          recursive
              ? 'Recursive deletion of files or directories ("rm -r")'
              : 'Bulk deletion with wildcards ("rm *")',
          command,
        );
      }

      return ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Deletion of files or directories ("$command")',
        command,
      );
    }

    // File mutations / overwrites (mv, shred, truncate, cp)
    if (command == 'mv' ||
        command == 'shred' ||
        command == 'truncate' ||
        command == 'cp') {
      final targets = args.where((x) => !x.startsWith('-')).toList();

      // Block writing/mutating system paths or block devices.
      if (targets.any(_isSystemPath) || targets.any(_isBlockDevice)) {
        return ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Targeting root or system path is not allowed with $command',
          '$command on root/system path',
        );
      }

      if (_isScratchOnlyList(targets)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Scratch directory operation',
        );
      }

      // cp is only safe within scratch; anything else needs confirmation.
      // (No unconditional safe path — destination must be confined.)

      return ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        '$command can destroy or replace files',
        command,
      );
    }

    // Directory / file creation (mkdir, touch)
    if (command == 'mkdir' || command == 'touch') {
      final targets = args.where((x) => !x.startsWith('-')).toList();
      if (targets.any(_isSystemPath) || targets.any(_isBlockDevice)) {
        return ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Targeting root or system path is not allowed with $command',
          '$command on root/system path',
        );
      }
      // Safe only when confined to scratch; anything else needs confirmation.
      if (_isScratchOnlyList(targets)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Scratch directory creation',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Creating files/directories outside scratch requires confirmation',
      );
    }

    // In-place sed editing
    if (command == 'sed') {
      if (args.contains('-i')) {
        final targets = args.where((x) => !x.startsWith('-') && !x.startsWith('s/')).toList();
        if (targets.isNotEmpty && _isScratchOnlyList(targets)) {
          return const ShellSafetyCheck(
            ShellSafetyLevel.safe,
            'Scratch directory in-place editing',
          );
        }
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'In-place file editing ("sed -i")',
          'sed -i',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Streaming text processing ("sed")',
      );
    }

    // find -delete / find -exec
    if (command == 'find') {
      if (args.contains('-delete')) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Automated bulk file deletion ("find -delete")',
          'find -delete',
        );
      }
      if (args.contains('-exec') ||
          args.contains('-execdir') ||
          args.contains('-ok') ||
          args.contains('-okdir')) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'find can modify or delete many files',
          'find',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'File search ("find")',
      );
    }

    // date system time modification check
    if (command == 'date') {
      if (args.any((a) => a == '-s' || a.startsWith('-s') || a.startsWith('--set'))) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Setting system date/time requires confirmation',
          'date -s',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Date and time inspection',
      );
    }

    // Android package manager (pm)
    if (command == 'pm') {
      if (args.any((a) => a == 'install' || a == 'uninstall' || a == 'clear' || a == 'disable' || a == 'enable')) {
        return ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Package modification ("pm ${args.firstWhere((a) => a == 'install' || a == 'uninstall' || a == 'clear' || a == 'disable' || a == 'enable')}")',
          'pm mutate',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Package manager inspection ("pm")',
      );
    }

    // Android settings
    if (command == 'settings') {
      if (args.any((a) => a == 'put' || a == 'delete')) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Modifying system settings ("settings put/delete")',
          'settings put',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Settings inspection ("settings")',
      );
    }

    // Android command service (cmd)
    if (command == 'cmd') {
      if (args.contains('dump') || (args.isNotEmpty && args.first == 'package' && args.contains('list'))) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Android service inspection ("cmd")',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Android service command ("cmd")',
        'cmd',
      );
    }

    // Inverted Allowlist check: if command is known safe, allow it.
    if (_safeAllowedCommands.contains(command)) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Command appears safe',
      );
    }

    // Fallback: any unknown, third-party, or non-allowlisted binary fails closed into needsConfirmation.
    return ShellSafetyCheck(
      ShellSafetyLevel.needsConfirmation,
      'Unverified or non-allowlisted command ("$command") requires confirmation under Draft policy',
      command,
    );
  }

  static List<String> _tokenize(String command) {
    final matches = RegExp(r'''(?:[^\s"'\\]+|\\.|"[^"]*"|'[^']*')+''')
        .allMatches(command);

    return matches
        .map((m) => m.group(0)!)
        .map(_unquoteToken)
        .toList();
  }

  static List<String> _redirectTargets(List<String> words) {
    final result = <String>[];

    for (var i = 0; i < words.length; i++) {
      final word = words[i];

      if (word == '>' ||
          word == '>>' ||
          word == '<' ||
          word == '<<' ||
          word == '&>') {
        if (i + 1 < words.length) {
          result.add(_unquoteToken(words[i + 1]));
        }
        continue;
      }

      if (RegExp(r'^\d*(>>|>|<|<<)').hasMatch(word)) {
        final match = RegExp(r'^\d*(?:>>|>|<|<<)(.+)$')
            .firstMatch(word);

        if (match != null) {
          result.add(_unquoteToken(match.group(1)!));
        }
      }
    }

    return result;
  }

  static bool _isSystemPath(String path) {
    final p = _normalizePath(path);

    if (p == '/') return true;

    const roots = {
      '/system',
      '/system_ext',
      '/vendor',
      '/product',
      '/odm',
      '/apex',
      '/data',
      '/etc',
      '/bin',
      '/sbin',
      '/usr',
      '/lib',
      '/lib64',
      '/boot',
      '/recovery',
      '/root',
      '/var',
      '/opt',
    };

    return roots.any(
      (root) => p == root || p.startsWith('$root/'),
    );
  }

  static bool _isBlockDevice(String path) {
    final p = _normalizePath(path);

    if (!p.startsWith('/dev/')) return false;

    return RegExp(
      r'^/dev/(block|mtd|sda|sdb|sdc|sdd|nvme\d+n\d+|mmcblk\d+|'
      r'vda|vdb|vdc|loop\d+|dm-\d+|hd[a-z]|sr\d+|ram\d+)',
    ).hasMatch(p);
  }

  static String _normalizePath(String path) {
    var p = _unquoteToken(path.trim());

    // Remove obvious glob suffix.
    p = p.replaceFirst(RegExp(r'[\*\?]+$'), '');

    if (!p.startsWith('/')) {
      p = '/__cwd__/$p';
    }

    final parts = <String>[];

    for (final part in p.split('/')) {
      if (part.isEmpty || part == '.') continue;

      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }

    return '/${parts.join('/')}';
  }

  static String _basename(String path) {
    return _unquoteToken(path).split('/').last;
  }

  /// Removes shell quoting (single quotes, double quotes) and backslash escapes
  /// from a token, matching POSIX shell word expansion behavior.
  /// e.g. `"r"m` -> `rm`, `\rm` -> `rm`, `'r'm` -> `rm`, `r""m` -> `rm`.
  static String _unquoteToken(String value) {
    if (value.isEmpty) return value;
    final sb = StringBuffer();
    var inSingleQuote = false;
    var inDoubleQuote = false;

    for (var i = 0; i < value.length; i++) {
      final c = value[i];

      if (c == '\\' && !inSingleQuote) {
        if (i + 1 < value.length) {
          final next = value[i + 1];
          if (inDoubleQuote) {
            if (next == r'$' || next == '`' || next == '"' || next == '\\' || next == '\n') {
              sb.write(next);
              i++;
            } else {
              sb.write(c);
            }
          } else {
            sb.write(next);
            i++;
          }
        } else {
          sb.write(c);
        }
        continue;
      }

      if (c == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue;
      }

      if (c == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      sb.write(c);
    }

    return sb.toString();
  }

  static bool _isAssignment(String value) {
    return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(value);
  }

  static bool _looksLikeWrapperValue(String value) {
    return RegExp(r'^\d+(?:\.\d+)?(?:ms|s|m|h)?$').hasMatch(value);
  }

  static bool _isScratchOnlyList(List<String> targets) {
    if (targets.isEmpty) return false;
    return targets.every((token) {
      final clean = _unquoteToken(token.trim());
      return clean.contains('.scratch') ||
          clean.contains('/.scratch/') ||
          clean.contains('/scratch/');
    });
  }
}

/// Decision made for a destructive tool call that requires confirmation.
enum ConfirmationDecision {
  /// Execute this single command.
  accept,

  /// Deny execution of this command.
  deny,

  /// Auto-accept this and subsequent destructive commands for the active session.
  trust,
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
  /// keeps Command and Exit code in previews.
  String toFormattedOutput({String? command}) {
    final buffer = StringBuffer();
    if (command != null) {
      buffer.writeln('Command: $command');
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
