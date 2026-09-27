import 'package:errand/services/database.dart';
import 'package:errand/services/grant_flow_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GrantFlowService.nextStep (creation-time grant ordering)', () {
    test('asks exact alarm first when both grants missing', () {
      expect(
        GrantFlowService.nextStep(
          exactGranted: false,
          batteryExempt: false,
          exactPrompted: false,
          batteryPrompted: false,
        ),
        equals(GrantStep.exactAlarm),
      );
    });

    test('moves to battery once exact granted or prompted', () {
      expect(
        GrantFlowService.nextStep(
          exactGranted: true,
          batteryExempt: false,
          exactPrompted: false,
          batteryPrompted: false,
        ),
        equals(GrantStep.batteryExemption),
      );
      expect(
        GrantFlowService.nextStep(
          exactGranted: false,
          batteryExempt: false,
          exactPrompted: true,
          batteryPrompted: false,
        ),
        equals(GrantStep.batteryExemption),
      );
    });

    test('returns null when nothing left to ask', () {
      // All granted.
      expect(
        GrantFlowService.nextStep(
          exactGranted: true,
          batteryExempt: true,
          exactPrompted: false,
          batteryPrompted: false,
        ),
        isNull,
      );
      // All prompted (denied or skipped): never nags again here.
      expect(
        GrantFlowService.nextStep(
          exactGranted: false,
          batteryExempt: false,
          exactPrompted: true,
          batteryPrompted: true,
        ),
        isNull,
      );
      // Battery granted but exact denied: done (no re-ask).
      expect(
        GrantFlowService.nextStep(
          exactGranted: false,
          batteryExempt: true,
          exactPrompted: true,
          batteryPrompted: false,
        ),
        isNull,
      );
    });
  });

  group('GrantFlowService.rearmOnFailure', () {
    late ErrandDatabase db;

    setUp(() {
      db = ErrandDatabase.inMemory();
    });

    tearDown(() async {
      await db.close();
    });

    test('clears prompted flags in database so grant flows can re-trigger', () async {
      await db.setSetting('pref.grant.exact_alarm.prompted', '1');
      await db.setSetting('pref.grant.battery.prompted', '1');

      expect(await db.getSetting('pref.grant.exact_alarm.prompted'), '1');
      expect(await db.getSetting('pref.grant.battery.prompted'), '1');

      await GrantFlowService.rearmOnFailure(db);

      expect(await db.getSetting('pref.grant.exact_alarm.prompted'), isNull);
      expect(await db.getSetting('pref.grant.battery.prompted'), isNull);
    });

    test('rearmOnFailure preserves prompted flags for non-Doze failures (e.g. model or prompt errors)', () async {
      await db.setSetting('pref.grant.exact_alarm.prompted', '1');
      await db.setSetting('pref.grant.battery.prompted', '1');

      // Model or schema validation error should NOT re-arm grant prompts
      await GrantFlowService.rearmOnFailure(
        db,
        errorMessage: 'Invalid JSON response from model: missing field summary',
      );

      expect(await db.getSetting('pref.grant.exact_alarm.prompted'), '1');
      expect(await db.getSetting('pref.grant.battery.prompted'), '1');
    });

    test('rearmOnFailure clears prompted flags for Doze-suspected signatures (timeout, UnknownHost, socket errors)', () async {
      await db.setSetting('pref.grant.exact_alarm.prompted', '1');
      await db.setSetting('pref.grant.battery.prompted', '1');

      await GrantFlowService.rearmOnFailure(
        db,
        errorMessage: 'SocketException: Failed host lookup: api.openai.com (OS Error: No address associated with hostname)',
      );

      expect(await db.getSetting('pref.grant.exact_alarm.prompted'), isNull);
      expect(await db.getSetting('pref.grant.battery.prompted'), isNull);

      // Re-set and test isTimeout
      await db.setSetting('pref.grant.exact_alarm.prompted', '1');
      await db.setSetting('pref.grant.battery.prompted', '1');

      await GrantFlowService.rearmOnFailure(
        db,
        isTimeout: true,
      );

      expect(await db.getSetting('pref.grant.exact_alarm.prompted'), isNull);
      expect(await db.getSetting('pref.grant.battery.prompted'), isNull);
    });
  });
}
