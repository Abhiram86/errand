import 'dart:async';

import 'package:errand/utils/coalescing_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sequential runs each execute once', () async {
    final writer = CoalescingWriter();
    var executions = 0;
    await writer.run(() async => executions++);
    await writer.run(() async => executions++);
    expect(executions, equals(2));
  });

  test('settled completes immediately when idle', () async {
    final writer = CoalescingWriter();
    await expectLater(writer.settled, completes);
  });

  test('burst coalesces into initial plus one trailing run with latest state', () async {
    final writer = CoalescingWriter();
    var version = 0;
    final seen = <int>[];
    final gate = Completer<void>();
    var first = true;

    Future<void> write() async {
      seen.add(version);
      if (first) {
        first = false;
        await gate.future;
      }
    }

    final a = writer.run(write);
    // A is parked inside write (sync prefix ran through to the gate).
    version = 1;
    final b = writer.run(write);
    version = 2;
    final c = writer.run(write);
    gate.complete();

    await Future.wait([a, b, c]);
    // One initial + exactly one trailing run, and the trailing run observed
    // the latest state — intermediate arrivals coalesce, none is lost.
    expect(seen, equals([0, 2]));
  });

  test('waiter is released only after the trailing run finishes', () async {
    final writer = CoalescingWriter();
    final order = <String>[];
    final gate = Completer<void>();
    var first = true;

    Future<void> write() async {
      if (first) {
        first = false;
        order.add('initial-start');
        await gate.future;
        order.add('initial-end');
      } else {
        order.add('trailing');
      }
    }

    final a = writer.run(write);
    final b = writer.run(write).then((_) => order.add('waiter-released'));
    gate.complete();
    await Future.wait([a, b]);

    expect(order, equals(['initial-start', 'initial-end', 'trailing', 'waiter-released']));
  });

  test('write error releases waiters without hanging and writer stays usable', () async {
    final writer = CoalescingWriter();
    final gate = Completer<void>();
    var first = true;

    Future<void> failingWrite() async {
      if (first) {
        first = false;
        await gate.future;
        throw StateError('db down');
      }
    }

    final a = writer.run(failingWrite);
    final b = writer.run(() async {});
    gate.complete();

    await expectLater(a, throwsStateError);
    // Waiter resolves normally (trailing skipped on error, same as before).
    await expectLater(b, completes);

    var recovered = false;
    await writer.run(() async => recovered = true);
    expect(recovered, isTrue);
  });
}
