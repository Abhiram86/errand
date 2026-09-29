import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/system_prompt.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/services/shell_service.dart';
import 'package:errand/services/workspace.dart';
import 'package:errand/tools/bash_tool.dart';
import 'package:errand/tools/file_tools.dart';

void main() {
  group('ShellSafetyCheck', () {
    // Real-dir confinement context: relative `.scratch/...` paths resolve
    // under /ws, which is the scratch dir itself.
    const testScratch = '/ws/.scratch';
    const testCwd = '/ws';

    test('identifies safe commands', () {
      final safeCommands = [
        'echo "hello world"',
        'ls -la',
        'pwd',
        'cat README.md',
        'grep -rn "TODO" .',
        'mkdir -p .scratch/test_dir/sub',
        'touch .scratch/file.txt',
        'cp .scratch/a.txt .scratch/b.txt',
        'mv .scratch/a.txt .scratch/b.txt',
        'rm .scratch/single_file.txt',
        'rm -rf .scratch',
        'df -h',
        'ps -ef',
        'tar -tzf archive.tar.gz',
        'unzip -l archive.zip',
        'gzip -dc file.gz',
        "awk '{print \$2}'",
        'ip addr show',
        'ip link show up',
        'ifconfig',
        'ls 2>&1',
        'echo "a > b"',
        'sed s/a/e/ file.txt',
      ];

      for (final cmd in safeCommands) {
        final check = ShellSafetyCheck.analyze(
          cmd,
          scratchPath: testScratch,
          workingDirectory: testCwd,
        );
        expect(check.isSafe, isTrue, reason: 'Command "$cmd" should be safe');
        expect(check.isBlocked, isFalse);
        expect(check.needsConfirmation, isFalse);
      }
    });

    test('confines mutation commands to scratch (13.6.1 follow-up)', () {
      // Outside scratch: must require confirmation, never safe.
      final needsConfirm = [
        'mkdir -p test_dir/sub',
        'touch file.txt',
        'cp a.txt b.txt',
        'cp a.txt /sdcard/evil.txt',
        'mkdir /sdcard/evil',
      ];
      for (final cmd in needsConfirm) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'Non-scratch mutation "$cmd" must require confirmation');
        expect(check.isSafe, isFalse);
      }

      // Inside scratch: safe.
      final scratchSafe = [
        'mkdir -p .scratch/sub',
        'touch .scratch/f.txt',
        'cp .scratch/a.txt .scratch/b.txt',
      ];
      for (final cmd in scratchSafe) {
        final check = ShellSafetyCheck.analyze(
          cmd,
          scratchPath: testScratch,
          workingDirectory: testCwd,
        );
        expect(check.isSafe, isTrue,
            reason: 'Scratch-confined mutation "$cmd" must be safe');
      }
    });

    test('worst-of: early confirm never shadows later blocked verdict', () {
      ShellSafetyCheck check;
      check = ShellSafetyCheck.analyze(
        'touch outside.txt; rm -rf /sdcard/DCIM',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      // Confirm inside a substitution plus blocked in a later segment.
      check = ShellSafetyCheck.analyze(
        'echo \$(touch outside.txt); rm -rf /sdcard/DCIM',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);
    });

    test('balanced substitution scan: nested payloads blocked, benign nesting safe', () {
      var check = ShellSafetyCheck.analyze(
        'echo \$(echo \$(rm -rf /sdcard/DCIM))',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      check = ShellSafetyCheck.analyze(
        'echo \$(echo hi)',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isSafe, isTrue);

      check = ShellSafetyCheck.analyze(
        'sh -c \'echo \$(rm -rf /sdcard/DCIM)\'',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);
    });

    test('cd nulls cwd: later relative paths fail closed, lone cd stays safe', () {
      var check = ShellSafetyCheck.analyze(
        'cd /tmp && rm -rf someday',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);
      expect(check.isSafe, isFalse);

      check = ShellSafetyCheck.analyze(
        'cd /tmp',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isSafe, isTrue);
    });

    test('chain keywords recurse: then/!/do cannot smuggle blocked verbs', () {
      for (final cmd in [
        'then rm -rf /sdcard/DCIM',
        '! rm -rf /sdcard/DCIM',
        'do eval echo hi',
      ]) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: '"$cmd" should be blocked');
      }
      expect(ShellSafetyCheck.analyze('then').isSafe, isTrue);
      expect(ShellSafetyCheck.analyze('for').isSafe, isTrue);
    });

    test('loader env assignments confirm like PATH mutations', () {
      for (final cmd in [
        'LD_PRELOAD=/x ls',
        'LD_LIBRARY_PATH=/x ls',
        'BASH_ENV=/x bash -c true',
        'ENV=/x sh -c true',
        'export LD_PRELOAD=/x',
        'export PATH=/evil',
      ]) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: '"$cmd" should require confirmation');
      }
      expect(ShellSafetyCheck.analyze('export FOO=bar').isSafe, isTrue);
    });

    test('storage aliases resolve to protected roots', () {
      for (final cmd in [
        'rm -rf /storage/emulated/0/DCIM',
        'rm -rf /mnt/sdcard/DCIM',
        'rm -rf /storage/self/primary/DCIM',
      ]) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue, reason: '"$cmd" should be blocked');
      }
    });

    test('rm flag parsing: targets are not recursive, -R is', () {
      var check = ShellSafetyCheck.analyze(
        'rm mybar',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);
      expect(check.reason ?? '', isNot(contains('Recursive')));

      check = ShellSafetyCheck.analyze(
        'rm -R mybar',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);
      expect(check.reason ?? '', contains('Recursive'));
    });

    test('sed in-place variants and script writes', () {
      ShellSafetyCheck check;
      check = ShellSafetyCheck.analyze('sed -i.bak s/a/b/ f.txt');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('sed --in-place s/a/b/ f.txt');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('sed --in-place= s/a/b/ f.txt');
      expect(check.needsConfirmation, isTrue);
      // Pure streaming substitutions stay safe, even with e/w letters.
      check = ShellSafetyCheck.analyze('sed s/a/e/ f.txt');
      expect(check.isSafe, isTrue);
      // w/e script commands fail closed.
      check = ShellSafetyCheck.analyze('sed /pat/w /tmp/out.txt');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('sed s/a/b/e f.txt');
      expect(check.needsConfirmation, isTrue);
    });

    test('date positional clock-set needs confirmation', () {
      expect(ShellSafetyCheck.analyze('date').isSafe, isTrue);
      expect(ShellSafetyCheck.analyze('date -u').isSafe, isTrue);
      expect(
          ShellSafetyCheck.analyze('date 090112302026').needsConfirmation,
          isTrue);
    });

    test('pm/cmd-package verbs: reads safe, mutates confirm, critical blocked', () {
      expect(ShellSafetyCheck.analyze('pm list packages').isSafe, isTrue);
      expect(ShellSafetyCheck.analyze('cmd package list packages').isSafe,
          isTrue);
      expect(
          ShellSafetyCheck.analyze('pm revoke com.foo.bar').needsConfirmation,
          isTrue);
      expect(
          ShellSafetyCheck.analyze('cmd package install x.apk')
              .needsConfirmation,
          isTrue);
      expect(
          ShellSafetyCheck.analyze('pm disable com.errand.errand').isBlocked,
          isTrue);
    });

    test('settings: reads safe, put/delete/reset confirm', () {
      expect(
          ShellSafetyCheck.analyze('settings get global x').isSafe, isTrue);
      expect(ShellSafetyCheck.analyze('settings list global').isSafe, isTrue);
      expect(
          ShellSafetyCheck.analyze('settings put global x 1')
              .needsConfirmation,
          isTrue);
      expect(ShellSafetyCheck.analyze('settings reset global x')
          .needsConfirmation, isTrue);
    });

    test('stateful logcat/dumpsys/sort options confirm, reads stay safe', () {
      expect(ShellSafetyCheck.analyze('logcat').isSafe, isTrue);
      expect(ShellSafetyCheck.analyze('logcat -c').needsConfirmation, isTrue);
      expect(
          ShellSafetyCheck.analyze('logcat -f /tmp/x').needsConfirmation,
          isTrue);
      expect(
          ShellSafetyCheck.analyze('dumpsys battery set x').needsConfirmation,
          isTrue);
      expect(ShellSafetyCheck.analyze('sort -n f').isSafe, isTrue);
      expect(
          ShellSafetyCheck.analyze('sort -o out f').needsConfirmation, isTrue);
    });

    test('awk: system() and file redirects confirm, processing stays safe', () {
      expect(
          ShellSafetyCheck.analyze('awk \'BEGIN{system("id")}\'')
              .needsConfirmation,
          isTrue);
      expect(
          ShellSafetyCheck.analyze('awk \'{print > "f"}\'').needsConfirmation,
          isTrue);
      expect(
          ShellSafetyCheck.analyze("awk '{print \$1}'").isSafe, isTrue);
    });

    test('archives: extraction confirms, inspection stays safe', () {
      ShellSafetyCheck check;
      check = ShellSafetyCheck.analyze('tar -xzf a.tgz');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('tar -tzf a.tgz');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('tar -cf a.tar f');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('unzip -o a.zip');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('unzip a.zip');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('unzip -l a.zip');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('gunzip a.gz');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('gzip -dc a.gz');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('gzip f');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('zip a.zip f');
      expect(check.needsConfirmation, isTrue);
    });

    test('network verbs: reconfiguration confirms, inspection stays safe', () {
      ShellSafetyCheck check;
      check = ShellSafetyCheck.analyze('ip link set wlan0 down');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('ip addr');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('ip link show up');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('ifconfig wlan0 up');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('ifconfig');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('route -n');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('route add default gw 1.2.3.4');
      expect(check.needsConfirmation, isTrue);
    });

    test('redirects: outside-scratch writes confirm, sinks/fd-dups/tests stay safe', () {
      ShellSafetyCheck check;
      check = ShellSafetyCheck.analyze(
        'echo hi > /sdcard/Download/n.txt',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze(
        'echo hi>out.txt',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze(
        'echo hi > .scratch/n.txt',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('ls 2>&1');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('echo x > /dev/null');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('echo "a > b"');
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze('[ "\$a" > "\$b" ]');
      expect(check.isSafe, isTrue);
    });

    test('heredocs and subshells stay usable (confirm, never blocked)', () {
      var check = ShellSafetyCheck.analyze('cat <<EOF');
      expect(check.isBlocked, isFalse);
      check = ShellSafetyCheck.analyze('(cd /tmp && echo hi)');
      expect(check.isBlocked, isFalse);
    });

    test('double-quoted substitutions are scanned (no quote bypass)', () {
      // Exact protected root inside dq substitution: blocked.
      var check = ShellSafetyCheck.analyze(
        'echo "\$(rm -rf /sdcard/DCIM)"',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      // Subdir payload inside dq substitution: scanned (confirm-tier),
      // which is what the bypass would have downgraded to safe.
      check = ShellSafetyCheck.analyze(
        'echo "\$(rm -rf /sdcard/DCIM/x)"',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);

      // Single quotes genuinely suppress expansion.
      check = ShellSafetyCheck.analyze(
        'echo \'\$(rm -rf /sdcard/DCIM/x)\'',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isSafe, isTrue);

      check = ShellSafetyCheck.analyze(
        'echo "nested \$(echo \$(rm -rf /sdcard/DCIM/x)) done"',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.needsConfirmation, isTrue);
    });

    test('pm unknown verbs fail closed', () {
      for (final cmd in [
        'pm grant com.foo.bar android.permission.CAMERA',
        'pm remove-user 10',
        'pm set-installer com.foo.bar com.other.app',
        'pm',
      ]) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: '"$cmd" should require confirmation');
        expect(check.isSafe, isFalse);
      }
    });

    test('awk exec forms: getline pipes, print pipes, -f confirm', () {
      ShellSafetyCheck check;
      check = ShellSafetyCheck.analyze('awk \'BEGIN{"rm x" | getline}\'');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('awk \'{print | "sort"}\'');
      expect(check.needsConfirmation, isTrue);
      check = ShellSafetyCheck.analyze('awk -f prog.awk data.txt');
      expect(check.needsConfirmation, isTrue);
      // Comparisons and logical-or stay safe.
      check = ShellSafetyCheck.analyze("awk '\$1>5'");
      expect(check.isSafe, isTrue);
      check = ShellSafetyCheck.analyze("awk '\$1==1 || \$2==2'");
      expect(check.isSafe, isTrue);
    });

    test('redirects cannot hide behind keywords, wrappers, or sh -c', () {
      var check = ShellSafetyCheck.analyze(
        'for f in *; do echo \$f; done > /sdcard/DCIM/x',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      // Subdir of a protected root: confirm-tier (exact roots block).
      expect(check.needsConfirmation, isTrue);
      expect(check.isBlocked, isFalse);

      check = ShellSafetyCheck.analyze(
        'for f in *; do echo \$f; done > /sdcard/DCIM',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      check = ShellSafetyCheck.analyze(
        'sh -c \'echo hi\' > /system/etc/foo',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      check = ShellSafetyCheck.analyze(
        'done > .scratch/x',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isSafe, isTrue);
    });

    test('groups classify by payload: destructive blocked, benign usable', () {
      var check = ShellSafetyCheck.analyze(
        '{ rm -rf /sdcard/DCIM; }',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      check = ShellSafetyCheck.analyze(
        '(rm -rf /sdcard/DCIM)',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isBlocked, isTrue);

      check = ShellSafetyCheck.analyze('(cd /tmp && echo hi)');
      expect(check.isBlocked, isFalse);

      check = ShellSafetyCheck.analyze('{ echo hi; }');
      expect(check.isSafe, isTrue);
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
        'rm single_file.txt',
        'rmdir empty_dir',
        'mv a.txt b.txt',
        'sed -i "s/foo/bar/g" config.txt',
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

    test('blocks catastrophic nuke commands early without prompting user', () {
      final nukes = [
        'rm -rf /sdcard',
        'rm -rf /sdcard/',
        'rm -rf /sdcard/*',
        'rm -rf /storage/emulated/0',
        'rm -rf /storage/emulated/0/*',
        'rm -rf /sdcard/DCIM',
        'rm -rf /sdcard/DCIM/*',
        'rm -rf /storage/emulated/0/Pictures',
        'rm -rf /storage/emulated/0/Pictures/*',
        'rm -rf /sdcard/Android',
        'am broadcast -a android.intent.action.MASTER_CLEAR',
        'recovery --wipe_data',
        'wipe data',
        'pm disable com.android.systemui',
        'pm uninstall com.errand.errand',
        'echo c > /proc/sysrq-trigger',
        'setprop ctl.stop zygote',
      ];

      for (final cmd in nukes) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue,
            reason: 'Nuke command "$cmd" must be hard blocked');
      }
    });

    test('fails closed on variable expansion in command position (P12.2 regression)', () {
      final varExpansionCommands = [
        r'$X',
        r'${X}',
        r'X="rm -rf /sdcard"; $X',
        r'CMD="reboot"; $CMD',
        r'FOO=1 $DYNAMIC_COMMAND',
      ];

      for (final cmd in varExpansionCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'Variable in command position "$cmd" must fail closed and require confirmation');
        expect(check.isSafe, isFalse);
      }
    });

    test('analyzes env wrapper and unwraps target commands (P12.2 regression)', () {
      final destructiveEnvCommands = [
        'env rm -rf /sdcard',
        'env FOO=bar rm -rf /storage/emulated/0/Download/old',
        'env -i rm -rf /data',
        'env -u PATH rm -f /storage/emulated/0/*.bak',
      ];

      for (final cmd in destructiveEnvCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isSafe, isFalse,
            reason: 'Destructive env command "$cmd" must not be considered safe');
        expect(check.needsConfirmation || check.isBlocked, isTrue,
            reason: 'Destructive env command "$cmd" should require confirmation or be blocked');
      }

      final safeEnvCommands = [
        'env',
        'env VAR=1',
        'env echo "hello"',
        'env -i ls -la',
      ];

      for (final cmd in safeEnvCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isSafe, isTrue,
            reason: 'Safe env command "$cmd" should be considered safe');
      }
    });

    test('normalizes quoting and backslash-escapes on executables and targets (C1, 13.6.1)', () {
      final quotedDestructive = [
        r'\rm file.txt',
        r'"r"m file.txt',
        r"'r'm file.txt",
        r'r""m file.txt',
        r'\r\m file.txt',
        r'"rm" file.txt',
        r"'rm' file.txt",
        r'"/bin/rm" file.txt',
        r'"/bin/"r"m" file.txt',
        r'"m"v a.txt b.txt',
        r'\mv a.txt b.txt',
        r'"s"hred file.txt',
        r'\truncate -s 0 file.txt',
      ];

      for (final cmd in quotedDestructive) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'Quoted command "$cmd" should require confirmation');
        expect(check.isSafe, isFalse);
      }

      final quotedSystemBlocks = [
        r'\rm -rf /',
        r'"r"m -rf /system',
        r'\cp file.txt /system/bin/foo',
        r'"c"p file.txt /system/bin/foo',
        r'\mv file.txt /system/bin/foo',
        r'"m"v file.txt /system/bin/foo',
        r'\shred /system/build.prop',
        r'\truncate -s 0 /system/build.prop',
      ];

      for (final cmd in quotedSystemBlocks) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue,
            reason: 'Quoted command targeting system "$cmd" must be blocked');
      }
    });

    test('blocks process substitution <() and >() (H10, 13.6.1)', () {
      final procSubCommands = [
        'diff <(cat a) <(cat b)',
        'bash <(echo rm -rf /)',
        'cat <(echo hi)',
        'echo hi > (cat)',
      ];

      for (final cmd in procSubCommands) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue,
            reason: 'Process substitution "$cmd" must be blocked');
      }
    });

    test('blocks system path mutations for mv, cp, shred, truncate (H9, 13.6.1)', () {
      final systemMutations = [
        'cp file.txt /system/bin/foo',
        'cp file.txt /vendor/lib/foo.so',
        'cp file.txt /data/local/tmp/foo',
        'mv file.txt /system/bin/foo',
        'shred /system/bin/foo',
        'truncate -s 0 /system/build.prop',
      ];

      for (final cmd in systemMutations) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue,
            reason: 'System mutation "$cmd" must be blocked');
      }

      final safeCopies = [
        'cp .scratch/file.txt .scratch/copy.txt',
      ];
      for (final cmd in safeCopies) {
        final check = ShellSafetyCheck.analyze(
          cmd,
          scratchPath: testScratch,
          workingDirectory: testCwd,
        );
        expect(check.isSafe, isTrue,
            reason: 'Workspace copy "$cmd" must be safe');
      }
    });

    test('enforces inverted allowlist and classifies Android shell utilities (13.6.1)', () {
      final safeAndroid = [
        'date',
        'date "+%Y-%m-%d %H:%M:%S"',
        'cal',
        'uptime',
        'getprop ro.build.version.release',
        'dumpsys battery',
        'logcat -d',
        'pm list packages',
        'settings get system screen_brightness',
      ];

      for (final cmd in safeAndroid) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isSafe, isTrue,
            reason: 'Safe Android utility "$cmd" should be safe');
      }

      final mutatingAndroid = [
        'date -s "2026-01-01"',
        'pm uninstall com.example',
        'pm clear com.example',
        'settings put system screen_brightness 100',
      ];

      for (final cmd in mutatingAndroid) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'Mutating command "$cmd" should require confirmation');
      }

      final unknown = [
        'unknown_custom_script.sh',
        'some_binary --flag',
      ];

      for (final cmd in unknown) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'Unknown executable "$cmd" must fail closed to needsConfirmation');
      }
    });

    test('blocks token-level catastrophes regardless of quoting (rewrite)', () {
      final catastrophes = [
        'am broadcast -a android.intent.action.MASTER_CLEAR',
        'am broadcast -a "android.intent.action.MASTER_CLEAR"',
        'recovery --wipe_data',
        'wipe data',
        'pm disable com.android.systemui',
        'pm "disable" com.errand.errand',
        'pm uninstall com.google.android.gms',
        'svc power reboot',
        'svc power shutdown',
        'echo c > /proc/sysrq-trigger',
        'setprop ctl.stop zygote',
        'setprop ctl.restart zygote',
      ];
      for (final cmd in catastrophes) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue,
            reason: 'Catastrophe "$cmd" must be blocked');
      }

      // Benign near-misses stay out of the block set.
      expect(ShellSafetyCheck.analyze('pm enable com.android.systemui').isBlocked,
          isFalse);
      expect(ShellSafetyCheck.analyze('svc wifi enable').isBlocked, isFalse);
    });

    test('PATH mutation always requires confirmation (rewrite)', () {
      for (final cmd in [
        'PATH=/evil ls',
        'export PATH=/evil',
        'export PATH=/evil; ls',
        'env PATH=/evil ls',
      ]) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.needsConfirmation, isTrue,
            reason: 'PATH mutation "$cmd" must require confirmation');
        expect(check.isSafe, isFalse);
      }
      // Non-PATH exports stay safe via the allowlist.
      expect(ShellSafetyCheck.analyze('export FOO=bar').isSafe, isTrue);
    });

    test('redirect gaps closed: &>>, >|, herestrings skipped (rewrite)', () {
      for (final cmd in [
        'echo x &>> /system/build.prop',
        'echo x >| /system/build.prop',
      ]) {
        final check = ShellSafetyCheck.analyze(cmd);
        expect(check.isBlocked, isTrue,
            reason: 'Redirect "$cmd" must be blocked');
      }
      // Herestring content is literal, not a path — must not false-block.
      expect(ShellSafetyCheck.analyze('cat <<< hello').isSafe, isTrue);
    });

    test('scratch confinement uses real dirs, not substrings (rewrite)', () {
      // Folders merely named like scratch are NOT scratch.
      for (final cmd in [
        'rm -rf my.scratch/',
        'rm -rf /sdcard/scratch/',
        'cp a.txt scratchpad/b.txt',
      ]) {
        final check = ShellSafetyCheck.analyze(
          cmd,
          scratchPath: testScratch,
          workingDirectory: testCwd,
        );
        expect(check.isSafe, isFalse,
            reason: 'Lookalike "$cmd" must not be scratch-safe');
      }
      // Real confinement resolves through cwd, including .. segments.
      final check = ShellSafetyCheck.analyze(
        'cp /ws/.scratch/a.txt /ws/.scratch/sub/../b.txt',
        scratchPath: testScratch,
        workingDirectory: testCwd,
      );
      expect(check.isSafe, isTrue);
      // Unknown scratch context fails closed, never safe.
      expect(ShellSafetyCheck.analyze('rm -rf .scratch').isSafe, isFalse);
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

    test('throws ShellDraftConfirmationException for recursive deletion outside scratch', () async {
      // Recursive deletion outside scratch requires confirmation (not blocked).
      expect(
        () => service.execute('rm -rf test_dir', workingDirectory: tempDir),
        throwsA(isA<ShellDraftConfirmationException>()),
      );

      expect(
        () => service.execute('rm *.log', workingDirectory: tempDir),
        throwsA(isA<ShellDraftConfirmationException>()),
      );
    });

    test('hard-blocks deletion of protected paths', () async {
      // Common destructive absolute paths are blocked outright.
      expect(
        () => service.execute('rm -rf /sdcard/DCIM', workingDirectory: tempDir),
        throwsA(isA<ShellSecurityException>()),
      );
      expect(
        () => service.execute('rm -rf /storage/emulated/0/Pictures', workingDirectory: tempDir),
        throwsA(isA<ShellSecurityException>()),
      );
    });

    test('throws ShellDraftConfirmationException for non-recursive deletion outside scratch', () async {
      // Single-file deletion (no -r, no wildcard) still requires confirmation.
      expect(
        () => service.execute('rm file.txt', workingDirectory: tempDir),
        throwsA(isA<ShellDraftConfirmationException>()),
      );
    });

    test('allows destructive mutations when confirmDestructive is true', () async {
      final fileToDelete = File('${tempDir.path}/to_delete.txt');
      await fileToDelete.writeAsString('bye');

      final result = await service.execute(
        'rm -f "${tempDir.path}/to_delete.txt"',
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

    test('bashTool prompts via onConfirmCommand and executes when accepted', () async {
      final testFile = File('${tempDir.path}/prompt_accept.txt');
      await testFile.writeAsString('to be deleted');

      var promptCalled = false;
      final customTool = bashTool(
        workingDirectory: workingDir,
        onConfirmCommand: ({required command, required title, reason}) async {
          promptCalled = true;
          expect(command, contains('prompt_accept.txt'));
          return ConfirmationDecision.accept;
        },
      );
      addTearDown(() => customTool.dispose());

      final result = await customTool.handler(
        ToolCall(
          id: 'call-accept',
          name: 'bash',
          arguments: {'command': 'rm "${testFile.path}"'},
        ),
      );

      expect(promptCalled, isTrue);
      expect(result.ok, isTrue);
      expect(await testFile.exists(), isFalse);
    });

    test('bashTool prompts via onConfirmCommand even if confirm_destructive: true is passed by agent', () async {
      final testFile = File('${tempDir.path}/prompt_agent_self_confirm.txt');
      await testFile.writeAsString('should not bypass modal');

      var promptCalled = false;
      final customTool = bashTool(
        workingDirectory: workingDir,
        onConfirmCommand: ({required command, required title, reason}) async {
          promptCalled = true;
          return ConfirmationDecision.accept;
        },
      );
      addTearDown(() => customTool.dispose());

      final result = await customTool.handler(
        ToolCall(
          id: 'call-self-confirm',
          name: 'bash',
          arguments: {
            'command': 'rm "${testFile.path}"',
            'confirm_destructive': true,
          },
        ),
      );

      // Must STILL prompt the user via onConfirmCommand even though agent passed confirm_destructive: true
      expect(promptCalled, isTrue);
      expect(result.ok, isTrue);
      expect(await testFile.exists(), isFalse);
    });

    test('bashTool refuses execution when onConfirmCommand returns deny', () async {
      final testFile = File('${tempDir.path}/prompt_deny.txt');
      await testFile.writeAsString('keep me');

      var promptCalled = false;
      final customTool = bashTool(
        workingDirectory: workingDir,
        onConfirmCommand: ({required command, required title, reason}) async {
          promptCalled = true;
          return ConfirmationDecision.deny;
        },
      );
      addTearDown(() => customTool.dispose());

      final result = await customTool.handler(
        ToolCall(
          id: 'call-deny',
          name: 'bash',
          arguments: {'command': 'rm "${testFile.path}"'},
        ),
      );

      expect(promptCalled, isTrue);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('User denied execution of command'));
      expect(result.error?.type, 'user_denied');
      expect(await testFile.exists(), isTrue);
    });

    test('bashTool bypasses confirmation when isSessionTrusted returns true', () async {
      final testFile = File('${tempDir.path}/trusted_delete.txt');
      await testFile.writeAsString('trusted');

      var promptCalled = false;
      final customTool = bashTool(
        workingDirectory: workingDir,
        isSessionTrusted: () => true,
        onConfirmCommand: ({required command, required title, reason}) async {
          promptCalled = true;
          return ConfirmationDecision.accept;
        },
      );
      addTearDown(() => customTool.dispose());

      final result = await customTool.handler(
        ToolCall(
          id: 'call-trusted',
          name: 'bash',
          arguments: {'command': 'rm "${testFile.path}"'},
        ),
      );

      expect(promptCalled, isFalse);
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

    test('bashTool automatically creates missing execDir when executing', () async {
      final nonExistentDir = Directory('${tempDir.path}/auto_created_dir');
      expect(await nonExistentDir.exists(), isFalse);

      final customWorkingDir = WorkingDirectory(tempDir, current: nonExistentDir);
      final customTool = bashTool(workingDirectory: customWorkingDir);
      addTearDown(() => customTool.dispose());

      final res = await customTool.handler(
        const ToolCall(
          id: 'call-auto-create',
          name: 'bash',
          arguments: {'command': 'pwd'},
        ),
      );

      expect(res.ok, isTrue);
      expect(await nonExistentDir.exists(), isTrue);
      expect(res.output, contains('auto_created_dir'));
    });
  });

  group('Workspace & Directory Hygiene', () {
    test('Workspace exposes root, documentsDir, scratchDir, and defaultDir', () {
      final ws = Workspace.instance;
      expect(ws.root.path, isNotEmpty);
      expect(ws.documentsDir.path, contains('Documents'));
      expect(ws.scratchDir.path, contains('scratch'));
      expect(ws.defaultDir.path, equals(ws.documentsDir.path));
    });

    test('ensureDefaultDirectories creates directory structure', () async {
      final ws = Workspace.instance;
      await ws.ensureDefaultDirectories();
      expect(await ws.documentsDir.exists(), isTrue);
      expect(await ws.scratchDir.exists(), isTrue);
    });

    test('systemPromptFor includes working directory, scratch directory, and hygiene rules', () {
      final workDir = Directory('/storage/emulated/0/Documents/Errand');
      final scratch = Directory('/storage/emulated/0/Documents/Errand/.scratch');
      final prompt = systemPromptFor(
        workDir,
        scratchDir: scratch,
        a11ySupported: false,
      );

      expect(prompt, contains('Current working directory: ${workDir.path}'));
      expect(prompt, contains('Scratch directory: ${scratch.path}'));
      expect(prompt, contains('Filesystem & Output Hygiene:'));
      expect(prompt, contains('NEVER write or dump files directly into storage root'));
    });
  });
}
