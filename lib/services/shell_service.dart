import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

/// Redirect target plus whether the operator writes (`>`, `>>`, `&>`,
/// `&>>`, `>|`) as opposed to reading (`<`, `<<`, heredoc delimiters).
typedef _ShellRedirect = ({String target, bool output});

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

  static ShellSafetyCheck _worst(ShellSafetyCheck a, ShellSafetyCheck b) =>
      b.level.index > a.level.index ? b : a; // safe < confirm < blocked

  /// Bodies of top-level $(...) spans, for recursive analysis. Balanced
  /// scan (not a flat regex) so nested substitutions resolve
  /// innermost-first instead of being misread or missed.
  /// Only single quotes suppress expansion: `"$(...)"` executes in shell
  /// and must be scanned; skipping it was a real bypass.
  static List<String> _substitutionBodies(String cmd) {
    final bodies = <String>[];
    var i = 0;
    final n = cmd.length;
    var inDouble = false;
    while (i < n) {
      final c = cmd[i];
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '"') {
        inDouble = !inDouble;
        i++;
        continue;
      }
      if (c == "'" && !inDouble) {
        final end = cmd.indexOf("'", i + 1);
        if (end == -1) break;
        i = end + 1;
        continue;
      }
      if (c == r'$' && i + 1 < n && cmd[i + 1] == '(') {
        var depth = 1;
        var j = i + 2;
        var q2 = '';
        var closed = -1;
        while (j < n) {
          final d = cmd[j];
          if (q2.isNotEmpty) {
            if (d == '\\' && q2 == '"') {
              j += 2;
              continue;
            }
            if (d == q2) q2 = '';
            j++;
            continue;
          }
          if (d == '\\') {
            j += 2;
            continue;
          }
          if (d == "'" || d == '"') {
            q2 = d;
            j++;
            continue;
          }
          if (d == '(') depth++;
          if (d == ')') {
            depth--;
            if (depth == 0) {
              closed = j;
              break;
            }
          }
          j++;
        }
        if (closed != -1) {
          bodies.add(cmd.substring(i + 2, closed));
          i = closed + 1;
          continue;
        }
        // Unbalanced: stop here; outer analysis fails closed on the fragment.
        break;
      }
      i++;
    }
    return bodies;
  }

  /// Analyzes a command line for dangerous operations and destructive mutations.
  ///
  /// Decision pipeline (in order — do not add new layers, extend the matching
  /// section instead):
  ///   1. HARD BLOCK: dangerous constructs, catastrophic expressions,
  ///      destructive binaries, system/block-device/protected targets.
  ///      Blocked means tool failure, never a permission prompt.
  ///   2. ALLOW: scratch-confined mutations and known read-only verbs.
  ///   3. CONFIRM: everything else fails closed into Draft confirmation.
  ///
  /// Standing rules:
  /// - Match on normalized tokens ([_unquoteToken]), never raw text, so
  ///   quoting/backslash tricks cannot dodge a check.
  /// - A verb being allowlisted says nothing about its arguments; any
  ///   allowlisted verb that gains an argument-interpreting mode needs
  ///   re-review (see the `echo`/payload note at the allowlist).
  /// - [scratchPath]/[workingDirectory] confine scratch checks to real dirs.
  ///   When absent, scratch checks fail closed (confirmation, never safe).
  static ShellSafetyCheck analyze(
    String command, {
    String? scratchPath,
    String? workingDirectory,
  }) {
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

    // Worst result wins across substitutions and segments: an early
    // confirm must never shadow a later blocked verdict.
    var worst = const ShellSafetyCheck.safe();

    // Command substitutions $(...) — balanced scan, innermost-first via recursion.
    for (final inner in _substitutionBodies(cmd)) {
      if (inner.trim().isEmpty) continue;
      worst = _worst(
        worst,
        analyze(inner,
            scratchPath: scratchPath, workingDirectory: workingDirectory),
      );
      if (worst.isBlocked) return worst;
    }

    // Backticks do not nest (POSIX); flat scan suffices.
    for (final m in RegExp(r'`([^`]+)`').allMatches(cmd)) {
      final inner = (m.group(1) ?? '').trim();
      if (inner.isEmpty) continue;
      worst = _worst(
        worst,
        analyze(inner,
            scratchPath: scratchPath, workingDirectory: workingDirectory),
      );
      if (worst.isBlocked) return worst;
    }

    // After any cd/pushd/popd the real cwd is unknown, so later relative
    // paths must not resolve against the original one (fail closed).
    String? cwd = workingDirectory;
    for (final segment in _splitCommands(cmd)) {
      worst = _worst(
        worst,
        _analyzeCommand(segment,
            scratchPath: scratchPath, workingDirectory: cwd),
      );
      if (worst.isBlocked) return worst;
      if (RegExp(r'\b(?:cd|pushd|popd)\b').hasMatch(segment)) cwd = null;
    }
    return worst;
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
    // Group depth: separators inside (...) / {...} do not split, so a
    // group reaches _analyzeCommand whole for payload analysis.
    var depth = 0;

    for (var i = 0; i < command.length; i++) {
      final c = command[i];

      if (c == '\\' && quote != "'") { // backslash is literal inside '...'
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

      if (c == '(' || c == '{' || c == '[') {
        depth++;
        continue;
      }
      if ((c == ')' || c == '}' || c == ']') && depth > 0) {
        depth--;
        continue;
      }

      // If '&' is part of '>&' or '&>', it's a redirect, not a command separator.
      if (c == '&' &&
          ((i > 0 && command[i - 1] == '>') ||
           (i + 1 < command.length && command[i + 1] == '>'))) {
        continue;
      }

      // If '|' is part of '>|' (noclobber override), it's a redirect target,
      // not a pipe.
      if (c == '|' && i > 0 && command[i - 1] == '>') {
        continue;
      }

      final isSeparator = depth == 0 &&
          (c == ';' ||
              c == '\n' ||
              c == '|' ||
              c == '&');

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

  static ShellSafetyCheck _analyzeCommand(
    String command, {
    String? scratchPath,
    String? workingDirectory,
  }) {
    var words = _tokenize(command);

    if (words.isEmpty) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Empty command',
      );
    }

    // PATH mutation poisons every lookup later in the segment (e.g.
    // `PATH=/evil ls` would otherwise analyze as harmless `ls`). Always
    // confirm; plain `export FOO=bar` stays on the allowlist path.
    // Generalized: loader and shell-option assignments (LD_PRELOAD,
    // BASH_ENV, IFS, ...) are equally lookup-poisoning.
    final leading = words.takeWhile(_isAssignment);
    final pathMutated = words.first == 'export'
        ? words.skip(1).any(_isDangerousAssign)
        : leading.any(_isDangerousAssign);
    if (pathMutated) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'PATH mutation can redirect subsequent command lookups',
        'PATH assignment',
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

    // Redirects are checked here — not in _analyzeDirectCommand — so
    // keywords (`done > /protected/x`), wrappers, and `sh -c` cannot
    // smuggle a write past verb analysis. Returns early on any hit.
    final redirectHit = _checkRedirects(
      words,
      scratchPath: scratchPath,
      workingDirectory: workingDirectory,
    );
    if (redirectHit != null) return redirectHit;

    // Group/subshell contents execute, so analyze them directly:
    // `(rm ...)` and `{ rm ...; }` classify by payload, while benign
    // groups like `(cd /tmp && echo hi)` stay usable.
    final inner = _stripGroup(command.trim());
    if (inner != null) {
      return analyze(inner,
          scratchPath: scratchPath, workingDirectory: workingDirectory);
    }

    // Shell control keywords (for, do, done, if, then, else, elif, fi, while,
  // until, !). Chain words recurse into the remainder so `then rm -rf /`
  // still blocks; bare keywords are inert.
    final firstWord = words.first;
    if (firstWord == 'done' || firstWord == 'fi') {
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
    const chain = {'do', 'if', 'while', 'until', 'then', 'else', 'elif', '!'};
    if (chain.contains(firstWord)) {
      if (words.length > 1) {
        return _analyzeCommand(words.sublist(1).join(' '), scratchPath: scratchPath, workingDirectory: workingDirectory);
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
        // Loader/shell-option assignments smuggled through env still poison
        // lookup — the recursion below would otherwise see only the remainder.
        if (words.sublist(1, idx).any(_isDangerousAssign)) {
          return const ShellSafetyCheck(
            ShellSafetyLevel.needsConfirmation,
            'PATH mutation can redirect subsequent command lookups',
            'PATH assignment',
          );
        }
        return _analyzeCommand(words.sublist(idx).join(' '), scratchPath: scratchPath, workingDirectory: workingDirectory);
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
          return _analyzeCommand(words.sublist(i).join(' '), scratchPath: scratchPath, workingDirectory: workingDirectory);
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
        // Full re-analysis: the nested string gets substitution scanning,
        // splitting, and worst-of treatment exactly like a top-level command.
        return analyze(words[cIndex + 1],
            scratchPath: scratchPath, workingDirectory: workingDirectory);
      }

      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Shell invocation requires confirmation',
      );
    }

    // busybox rm ...
    if (executable == 'busybox' || executable == 'toybox') {
      if (words.length > 1) {
        return _analyzeCommand(words.sublist(1).join(' '), scratchPath: scratchPath, workingDirectory: workingDirectory);
      }
    }

    // command rm ...
    if (executable == 'command' && words.length > 1) {
      return _analyzeCommand(words.sublist(1).join(' '), scratchPath: scratchPath, workingDirectory: workingDirectory);
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

    return _analyzeDirectCommand(words, scratchPath: scratchPath, workingDirectory: workingDirectory);
  }

  // Inverted Allowlist of safe, non-destructive utilities in Android shell / Toybox.
  static const _safeAllowedCommands = <String>{
    // File / Directory navigation & inspection
    'ls', 'dir', 'vdir', 'pwd', 'cd', 'pushd', 'popd', 'dirs',
    'which', 'whereis', 'type', 'file', 'stat', 'whoami', 'id', 'groups',

    // File reading & text viewing
    'cat', 'head', 'tail', 'more', 'less', 'strings', 'nl', 'tac', 'rev',
    'od', 'hexdump', 'xxd', 'base64',

    // Searching, text processing & filtering.
    // `awk` has its own branch (system()/redirect modes); `dos2unix` /
    // `unix2dos` rewrite files in place and fail closed into confirmation.
    'grep', 'egrep', 'fgrep', 'cut', 'sort', 'uniq', 'wc',
    'tr', 'fold', 'paste', 'column', 'comm', 'cmp', 'diff', 'join', 'fmt',
    'pr', 'expand', 'unexpand',

    // Printing, flow, logic & math
    'echo', 'printf', 'true', 'false', 'test', '[', 'expr', 'seq', 'sleep',
    'usleep', 'bc', 'yes', 'exit', 'return',

    // Path manipulation & checksums
    'basename', 'dirname', 'realpath', 'readlink',
    'md5sum', 'sha1sum', 'sha224sum', 'sha256sum', 'sha384sum', 'sha512sum',
    'cksum', 'crc32',

    // Dates, times & system inspection (heavily used on Android).
    // Network verbs (`ip`, `ifconfig`, `arp`, `route`) and archive verbs
    // have their own branches: read-only modes stay safe, mutating or
    // file-writing modes fail closed into confirmation.
    'date', 'cal', 'uptime', 'uname', 'hostname', 'arch', 'df', 'du',
    'ps', 'top', 'free', 'vmstat', 'iostat', 'netstat', 'ss',
    'printenv', 'export',

    // Decompress-to-stdout only; everything else has its own branch.
    'zcat',

    // Android-specific system inspection
    'getprop', 'dumpsys', 'logcat',
  };

  // ---------------------------------------------------------------------------
  // Single decision pipeline per command segment. Order is load-bearing:
  //   1. HARD BLOCKS (deny-list): destructive binaries, catastrophic
  //      expressions, system/block-device/protected targets. Blocked means
  //      tool failure — never a permission prompt.
  //   2. ALLOW: scratch-confined mutations and known read-only verbs.
  //   3. CONFIRM: everything else fails closed into Draft confirmation.
  // ---------------------------------------------------------------------------
  static ShellSafetyCheck _analyzeDirectCommand(
    List<String> words, {
    String? scratchPath,
    String? workingDirectory,
  }) {
    final command = _basename(words.first);
    final args = words.sublist(1);
    // Absolute, normalized view of every non-flag target for the checks
    // below. Unresolvable tokens (bare `~`, relative paths with unknown
    // cwd) fall back to lexical normalization at each check site.
    List<String> resolved(Iterable<String> tokens) => tokens
        .map((t) => _resolveTarget(t, workingDirectory) ?? _normalizePath(t))
        .toList();

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

    // eval/exec/source/. in any reachable command position (e.g. after
    // do/then via keyword recursion) hide arbitrary commands — block outright.
    if (const {'eval', 'exec', 'source', '.'}.contains(command)) {
      return ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        '$command is not allowed',
        command,
      );
    }

    // Android/system property power control, and zygote lifecycle.
    // `setprop` anything else is unknown → confirm fallback below.
    if (command == 'setprop' &&
        (args.contains('sys.powerctl') ||
            (args.any((a) => a.startsWith('ctl.')) &&
                args.any((a) => a.contains('zygote'))))) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'System power control / zygote lifecycle is not allowed',
        'setprop power/zygote',
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

    // Device wipe / factory reset: matched on normalized tokens (quoting
    // cannot dodge these, unlike raw-text regexes).
    if (command == 'am' && args.any((a) => a.contains('MASTER_CLEAR'))) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'Factory reset / device wipe commands are strictly prohibited',
        'device wipe',
      );
    }
    if (command == 'recovery' && args.any((a) => a.contains('wipe'))) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'Factory reset / device wipe commands are strictly prohibited',
        'device wipe',
      );
    }
    if (command == 'wipe') {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'Factory reset / device wipe commands are strictly prohibited',
        'device wipe',
      );
    }
    if (command == 'svc' &&
        args.contains('power') &&
        (args.contains('reboot') || args.contains('shutdown'))) {
      return const ShellSafetyCheck(
        ShellSafetyLevel.blocked,
        'System power control via svc is not allowed',
        'svc power',
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

    // Redirecting into a system path, protected dir, block device, or the
    // kernel sysrq trigger is handled by _checkRedirects inside
    // _analyzeCommand (before verb dispatch), so keywords, wrappers, and
    // `sh -c` cannot bypass it.

    // File deletion (rm / rmdir)
    if (command == 'rm' || command == 'rmdir') {
      final targets = resolved(args.where((x) => !x.startsWith('-')));

      if (targets.any(_isSystemPath) ||
          targets.any(_isBlockDevice) ||
          targets.any(_isProtectedPath)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Deleting system or protected paths is not allowed',
          'rm on system/protected path',
        );
      }

      if (_isScratchOnlyList(targets, scratchPath)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Scratch directory deletion',
        );
      }

      final recursive = args.any((x) =>
          x == '--recursive' ||
          (x.startsWith('-') &&
              !x.startsWith('--') &&
              (x.contains('r') || x.contains('R'))));
      final wildcard = args.any(
          (x) => !x.startsWith('-') && (x.contains('*') || x.contains('?')));

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
      final targets = resolved(args.where((x) => !x.startsWith('-')));

      // Block writing/mutating system paths, block devices, or protected dirs.
      if (targets.any(_isSystemPath) ||
          targets.any(_isBlockDevice) ||
          targets.any(_isProtectedPath)) {
        return ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Targeting system or protected path is not allowed with $command',
          '$command on system/protected path',
        );
      }

      if (_isScratchOnlyList(targets, scratchPath)) {
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
      final targets = resolved(args.where((x) => !x.startsWith('-')));
      if (targets.any(_isSystemPath) ||
          targets.any(_isBlockDevice) ||
          targets.any(_isProtectedPath)) {
        return ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Targeting system or protected path is not allowed with $command',
          '$command on system/protected path',
        );
      }
      // Safe only when confined to scratch; anything else needs confirmation.
      if (_isScratchOnlyList(targets, scratchPath)) {
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
      final inPlace = args.any((a) =>
          a == '--in-place' ||
          a.startsWith('--in-place=') ||
          (a.startsWith('-') && !a.startsWith('--') && a.contains('i')));
      if (inPlace) {
        final targets = resolved(
            args.where((x) => !x.startsWith('-') && !x.startsWith('s/')));
        if (targets.isNotEmpty && _isScratchOnlyList(targets, scratchPath)) {
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
      // `w file` writes files, `e [command]` executes shell commands.
      // Fail closed; anchored so s/a/e/ and s/x/w/ (replacement text)
      // stay safe: a real w/e command is never followed by '/'.
      final scriptWrites = args.any((a) =>
          !a.startsWith('-') &&
          RegExp(r'(?:^|[;{}/])\s*[we](?:\s|$)').hasMatch(a));
      if (scriptWrites) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'sed script may write files or execute commands',
          'sed w/e',
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

    // date system time modification check (flags and positional set)
    if (command == 'date') {
      if (args.any((a) =>
          a == '-s' ||
          a.startsWith('-s') ||
          a.startsWith('--set') ||
          RegExp(r'^\d{8,12}(\.\d\d)?$').hasMatch(a))) {
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

    // Android package manager (pm), including `cmd package` spellings.
    // Disabling/uninstalling critical packages bricks the device or the
    // app itself — blocked outright, never confirmable (token-level, so
    // `"disable"` quoting variants are covered too).
    final isPm = command == 'pm' ||
        (command == 'cmd' && args.isNotEmpty && args.first == 'package');
    if (isPm) {
      // `enable` is excluded: re-enabling a critical package is restore, not harm.
      const criticalPackages = {
        'com.android.settings',
        'com.google.android.gms',
        'com.android.systemui',
        'com.errand.errand',
      };
      const harmful = {
        'install',
        'uninstall',
        'clear',
        'disable',
        'disable-user',
        'disable-until-used',
        'hide',
        'suspend',
        'revoke',
        'reset-permissions',
        'trim-caches',
      };
      const readVerbs = {
        'list',
        'path',
        'dump',
        'resolve-activity',
        'get-install-location',
        'has-feature',
      };
      final hitsHarmful = args.any(harmful.contains);
      bool isMutatingWord(String a) => harmful.contains(a) || a == 'enable';
      final mutating = args.any(isMutatingWord);
      if (hitsHarmful &&
          args.any((a) => criticalPackages.any((pkg) => a.contains(pkg)))) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Disabling or modifying critical system services or Errand is strictly prohibited',
          'system package tamper',
        );
      }
      if (!hitsHarmful && args.any(readVerbs.contains)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Package manager inspection',
        );
      }
      if (mutating) {
        return ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Package modification ("pm ${args.firstWhere(isMutatingWord, orElse: () => 'mutate')}")',
          'pm mutate',
        );
      }
      // Unknown verbs (grant, remove-user, set-installer, ...) fail closed:
      // pm can do far more than list, and silence is not inspection.
      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Unrecognized package manager verb',
        'pm unknown',
      );
    }

    // Android settings: read verbs only stay safe; put/delete/reset
    // (previously only put/delete were caught) need confirmation.
    if (command == 'settings') {
      if (args.any(const {'get', 'list', 'help'}.contains) &&
          !args.any(const {'put', 'delete', 'reset'}.contains)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Settings inspection ("settings")',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Modifying system settings',
        'settings',
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

    // Stateful or file-writing options on otherwise read-only verbs.
    const statefulArgs = {
      'logcat': {'-c', '--clear', '-f'},
      'dumpsys': {'set', 'reset', 'unplug'},
    };
    final bad = statefulArgs[command];
    if ((bad != null && args.any(bad.contains)) ||
        (command == 'sort' &&
            args.any((a) =>
                a.startsWith('--output') ||
                (a.startsWith('-') &&
                    !a.startsWith('--') &&
                    a.contains('o'))))) {
      return ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        '$command with a state-changing or file-writing option',
        command,
      );
    }

    // awk: several program forms escape into shell or files. Plain text
    // processing stays safe; comparisons like `$1>5` must not confirm.
    if (command == 'awk') {
      final program = args.join(' ');
      if (RegExp(r'system\s*\(').hasMatch(program)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'awk program can execute shell commands ("system()")',
          'awk system',
        );
      }
      if (args.any((a) => a == '-f' || a == '--file')) {
        // Program comes from a file: invisible to static analysis.
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'awk program read from a file ("-f")',
          'awk file',
        );
      }
      if (RegExp(r'(print|printf)\s*>>?\s*[^0-9\s=]').hasMatch(program)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'awk program may write files ("print >")',
          'awk redirect',
        );
      }
      // Pipes execute commands (`"cmd" | getline`, `print | "sort"`).
      // Strip double-quoted strings first so `||` and comparisons stay
      // safe; any remaining lone `|` is a pipe operator. (A literal "|"
      // inside quotes was already stripped by the tokenizer, so it
      // conservatively confirms — rare and fail-closed.)
      final dequoted = program.replaceAll(RegExp(r'"[^"]*"'), '');
      if (RegExp(r'(?<!\|)\|(?!\|)').hasMatch(dequoted)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'awk program may pipe to shell commands ("|")',
          'awk pipe',
        );
      }
      return const ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Streaming text processing ("awk")',
      );
    }

    // Archive tools: extraction/overwrite modes fail closed; explicit
    // read-only modes (list, test, decompress-to-stdout) stay safe.
    if (const {
      'tar',
      'gzip',
      'gunzip',
      'bzip2',
      'bunzip2',
      'xz',
      'unxz',
      'zip',
      'unzip',
    }.contains(command)) {
      var extracting = false;
      var readOnly = false;
      // unzip inspect modes (-l/-t/-Z/-p/-c) make operands pure inputs;
      // without one, a bare archive operand means extract.
      final unzipInspect = command == 'unzip' &&
          args.any((b) =>
              b == '-l' || b == '-t' || b == '-Z' || b == '-p' || b == '-c');
      for (final a in args) {
        if (command == 'tar') {
          if (a == '--extract' || a == '--delete') {
            extracting = true;
            break;
          }
          if (a.startsWith('-') && !a.startsWith('--')) {
            final flags = a.substring(1);
            // Bundled short flags: -x/-c create or extract, -t lists.
            // Extract wins on mixed bundles (fail closed).
            if (RegExp(r'[xcdruA]').hasMatch(flags) &&
                !flags.contains('t')) {
              extracting = true;
              break;
            }
            if (flags.contains('t')) readOnly = true;
          } else if (a == '--list' || a == '--diff' || a == '--compare') {
            readOnly = true;
          }
        } else if (command == 'unzip') {
          if (a == '-o' ||
              a == '-n' ||
              a == '-f' ||
              a == '-u' ||
              a == '-j') {
            extracting = true;
            break;
          }
          if (unzipInspect) {
            // Inspect mode: operands and other flags are inputs only.
            readOnly = true;
          } else if (!a.startsWith('-')) {
            // Archive operand alone means extract.
            extracting = true;
            break;
          } else {
            // Unknown unzip flag without inspect mode: fail closed.
            extracting = true;
            break;
          }
        } else if (command == 'zip') {
          // zip always writes/updates an archive file.
          extracting = true;
          break;
        } else {
          // gzip/bzip2/xz family: bare -d deletes originals; -c/-t/-l/-k
          // preserve them (stdout/test/list/keep). Bundled flags honored:
          // preserve wins, since decompress-to-stdout never deletes.
          if (a == '-d' || a == '--decompress' || a == '--uncompress') {
            extracting = true;
            break;
          }
          if (a.startsWith('-') && !a.startsWith('--')) {
            final flags = a.substring(1);
            if (flags.contains('c') ||
                flags.contains('t') ||
                flags.contains('l') ||
                flags.contains('k')) {
              readOnly = true;
              continue;
            }
            if (flags.contains('d')) {
              extracting = true;
              break;
            }
          }
          if (a == '-c' ||
              a == '--stdout' ||
              a == '--to-stdout' ||
              a == '-t' ||
              a == '--test' ||
              a == '-l' ||
              a == '--list' ||
              a == '--keep') {
            readOnly = true;
          }
        }
      }
      if (extracting) {
        return ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Archive extraction or modification ("$command")',
          command,
        );
      }
      if (readOnly) {
        return ShellSafetyCheck(
          ShellSafetyLevel.safe,
          'Archive inspection ("$command")',
          command,
        );
      }
      return ShellSafetyCheck(
        ShellSafetyLevel.needsConfirmation,
        'Archive operation ("$command")',
        command,
      );
    }

    // Network tools: read-only inspection stays safe; anything that
    // reconfigures interfaces, addresses, or routes needs confirmation.
    // (`up`/`down` count only for ifconfig, where they are the mutation
    // verbs — `ip link show up` is a read-only filter and stays safe.)
    if (const {'ip', 'ifconfig', 'arp', 'route'}.contains(command)) {
      const mutate = {
        'add',
        'del',
        'delete',
        'set',
        'change',
        'replace',
        'flush',
        'tunnel',
        '-s',
        '-d',
      };
      final reconfigures = args.any(mutate.contains) ||
          (command == 'ifconfig' &&
              args.any((a) => a == 'up' || a == 'down'));
      if (reconfigures) {
        return ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Network reconfiguration ("$command")',
          command,
        );
      }
      return ShellSafetyCheck(
        ShellSafetyLevel.safe,
        'Network inspection ("$command")',
        command,
      );
    }

    // Inverted allowlist: read-only verbs that are unconditionally safe.
    // A verb being here says NOTHING about its arguments — every branch
    // above already ran, so any argument-interpreting mode (write flags,
    // exec modes, URL/destination operands) must be classified in its own
    // branch BEFORE this point. Never add a verb here that can act on its
    // arguments without re-reviewing those modes.
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
    final matches = RegExp(r'''(?:[^\s"'\\]+|\\.|"(?:[^"\\]|\\.)*"|'[^']*')+''')
        .allMatches(command);

    return matches
        .map((m) => m.group(0)!)
        .map(_unquoteToken)
        .toList();
  }

  /// Device-null sinks: redirecting here discards output and is inert.
  static const _redirectSinks = {'/dev/null', '/dev/stdout', '/dev/stderr'};

  /// Redirect target plus whether the operator writes (`>`, `>>`, `&>`,
  /// `&>>`, `>|`) as opposed to reading (`<`, `<<`, heredoc delimiters).
  static List<_ShellRedirect> _redirectTargets(List<String> words) {
    final result = <_ShellRedirect>[];

    bool isOutputOp(String op) => op != '<' && op != '<<';

    for (var i = 0; i < words.length; i++) {
      final word = words[i];

      if (word == '>' ||
          word == '>>' ||
          word == '<' ||
          word == '<<' ||
          word == '&>' ||
          word == '&>>' ||
          word == '>|' ||
          RegExp(r'^\d+(&>>|&>|>>|>)$').hasMatch(word)) {
        if (i + 1 < words.length) {
          final next = _unquoteToken(words[i + 1]);
          if (!_redirectSinks.contains(next)) {
            result.add((target: next, output: isOutputOp(word)));
          }
        }
        continue;
      }

      // `<<<` is a herestring: following text is literal content, not a path.
      if (word == '<<<' || word.startsWith('<<<')) {
        continue;
      }

      // Glued forms: `x>/f`, `2>file`, `x&>f`, `x>|f`. A token containing
      // a literal space came from quotes (`echo "a > b"`) and is skipped.
      if (!word.contains(' ')) {
        final glued =
            RegExp(r'^(.*?)(\d*)(&>>|&>|>>|>\||>|<|<<)(.+)$')
                .firstMatch(word);
        if (glued != null) {
          final op = glued.group(3)!;
          final target = _unquoteToken(glued.group(4)!);
          // `>&N` / `2>&N` / `>&-`: fd duplication/close, not a file write.
          // (A real filename never takes the `&N` shape unquoted.)
          if (RegExp(r'^&(\d+|-)$').hasMatch(target)) {
            continue;
          }
          if (_redirectSinks.contains(target)) continue;
          result.add((target: target, output: isOutputOp(op)));
        }
      }
    }

    return result;
  }

  /// Redirect verdict for one segment: blocked on system/protected/block/
  /// sysrq targets, confirmation on ordinary output writes outside scratch.
  /// Input redirects and `[`/`[[`/`test` comparisons never write. Null
  /// means "no hit" — the caller continues with verb analysis.
  static ShellSafetyCheck? _checkRedirects(
    List<String> words, {
    String? scratchPath,
    String? workingDirectory,
  }) {
    if (words.isEmpty) return null;
    final command = _basename(words.first);
    for (final redirect in _redirectTargets(words)) {
      final target = redirect.target;
      final resolved =
          _resolveTarget(target, workingDirectory) ?? _normalizePath(target);
      if (resolved == '/proc/sysrq-trigger') {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Triggering kernel sysrq commands is strictly prohibited',
          'sysrq trigger',
        );
      }
      if (_isBlockDevice(resolved)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Redirect writes directly to a block device',
          '> /dev/block',
        );
      }

      if (_isSystemPath(resolved) || _isProtectedPath(resolved)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.blocked,
          'Writing to a system or protected path is not allowed',
          'system/protected path write',
        );
      }

      if (redirect.output &&
          command != '[' &&
          command != '[[' &&
          command != 'test' &&
          // awk/expr comparisons (`$1>5`, `\(a \> b`) are not writes;
          // a bare numeric target there is a comparison operand.
          !(RegExp(r'^\d').hasMatch(target) &&
              (command == 'awk' || command == 'expr')) &&
          !_isScratchOnlyList([resolved], scratchPath)) {
        return const ShellSafetyCheck(
          ShellSafetyLevel.needsConfirmation,
          'Redirect writes a file outside scratch (">")',
          'redirect outside scratch',
        );
      }
    }
    return null;
  }

  /// Strips one outer group layer — `( ... )` or `{ ...; }` — returning the
  /// inner text for direct analysis, or null when not a clean group.
  /// Groups execute their contents, so payload decides: destructive groups
  /// block, benign ones stay usable (no blanket block on subshells).
  static String? _stripGroup(String cmd) {
    if (cmd.length < 3) return null;
    final first = cmd[0];
    if (first != '(' && first != '{') return null;
    var depth = 0;
    var quote = '';
    var i = 0;
    final n = cmd.length;
    while (i < n) {
      final c = cmd[i];
      if (quote.isNotEmpty) {
        if (c == '\\' && quote == '"') {
          i += 2;
          continue;
        }
        if (c == quote) quote = '';
        i++;
        continue;
      }
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        i++;
        continue;
      }
      if (c == '(' || c == '{') depth++;
      if (c == ')' || c == '}') {
        depth--;
        if (depth == 0) {
          final rest = cmd.substring(i + 1).trim();
          if (rest.isEmpty || rest == ';') {
            return cmd.substring(1, i).trim();
          }
          return null;
        }
      }
      i++;
    }
    return null;
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

  /// Well-known storage roots and top-level user directories that must never
  /// be wiped or destroyed wholesale — blocked outright, never sent to confirmation.
  static bool _isProtectedPath(String path) {
    final p = _normalizePath(path);
    const roots = [
      '/sdcard',
      '/storage/emulated/0',
      '/sdcard/DCIM',
      '/sdcard/Pictures',
      '/sdcard/Movies',
      '/sdcard/Music',
      '/sdcard/Documents',
      '/sdcard/Download',
      '/sdcard/Android',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Android',
    ];
    return roots.any((root) => p == root || p == '$root/');
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

    final out = '/${parts.join('/')}';
    // Canonicalize Android storage aliases so /storage/emulated/0/...,
    // /mnt/sdcard, etc. hit the same /sdcard/... protected roots.
    return out.replaceFirst(
      RegExp(r'^/(?:storage/(?:emulated/\d+|self/primary)|mnt/sdcard|mnt/user/\d+/primary)(?=/|$)'),
      '/sdcard',
    );
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

  /// Loader and shell-option assignments poison command lookup exactly
  /// like PATH mutations (LD_PRELOAD, BASH_ENV, IFS, ...).
  static bool _isDangerousAssign(String w) => RegExp(
          r'^(?:PATH|IFS|ENV|BASH_ENV|SHELLOPTS|LD_[A-Z_]+)=')
      .hasMatch(w);

  static bool _looksLikeWrapperValue(String value) {
    return RegExp(r'^\d+(?:\.\d+)?(?:ms|s|m|h)?$').hasMatch(value);
  }

  /// Scratch confinement against real directories: every target must
  /// resolve inside [scratchPath]. Unknown scratch (null) fails closed.
  /// Replaces the old substring heuristic (any path merely containing
  /// ".scratch" used to pass).
  static bool _isScratchOnlyList(List<String> targets, String? scratchPath) {
    if (targets.isEmpty) return false;
    // Unresolvable expansions cannot be confined statically — fail closed.
    if (targets.any((t) => RegExp(r'[$`~{(]').hasMatch(t))) return false;
    final scratch = scratchPath?.trim();
    if (scratch == null || scratch.isEmpty) return false;
    final scratchAbs = p.normalize(scratch);
    return targets.every((t) {
      final abs = p.normalize(t);
      return abs == scratchAbs || p.isWithin(scratchAbs, abs);
    });
  }

  /// Resolves a raw token to an absolute normalized path, or null when it
  /// cannot be resolved statically (`~`-prefixed, or relative with unknown
  /// cwd). Callers fall back to lexical normalization (old behavior) on null.
  static String? _resolveTarget(String token, String? cwd) {
    final clean = _unquoteToken(token.trim());
    if (clean.isEmpty) return null;
    if (clean.startsWith('~')) return null;
    if (p.isAbsolute(clean)) return p.normalize(clean);
    if (cwd == null || cwd.isEmpty) return null;
    return p.normalize(p.join(cwd, clean));
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
  ///
  /// [scratchPath] confines scratch checks to the real scratch dir; when null
  /// they fail closed (confirmation). Kept as a parameter (not a Workspace
  /// lookup) so this service stays dependency-free and testable.
  Future<ShellResult> execute(
    String command, {
    Directory? workingDirectory,
    String? scratchPath,
    Duration? timeout,
    CancelToken? cancelToken,
    bool confirmDestructive = false,
  }) async {
    // 1. Safety check
    final safetyCheck = ShellSafetyCheck.analyze(
      command,
      scratchPath: scratchPath,
      workingDirectory: workingDirectory?.path,
    );
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
