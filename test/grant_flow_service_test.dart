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
}
