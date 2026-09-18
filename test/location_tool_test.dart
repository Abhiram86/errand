import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/services/location_service.dart';
import 'package:errand/tools/location_tool.dart';

class FakeLocationService implements LocationService {
  bool permitted = true;
  LocationData? mockLocation;

  @override
  LocationData? get lastKnown => mockLocation;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<LocationData?> getLocation({bool requestIfMissing = true}) async {
    if (!permitted) return null;
    return mockLocation;
  }
}

void main() {
  group('LocationTool', () {
    late FakeLocationService fakeService;
    late Tool tool;

    setUp(() {
      fakeService = FakeLocationService();
      tool = locationTool(locationService: fakeService);
    });

    test('has valid tool metadata and schema', () {
      expect(tool.name, 'location');
      expect(tool.parameters['type'], 'object');
      expect(tool.parameters['properties']['action'], isNotNull);
    });

    test('returns failure when permission is denied', () async {
      fakeService.permitted = false;

      final result = await tool.handler(
        const ToolCall(
          id: 'call_1',
          name: 'location',
          arguments: {'action': 'get_location'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.type, 'permission_denied');
    });

    test('returns full location summary by default', () async {
      fakeService.permitted = true;
      fakeService.mockLocation = LocationData(
        latitude: 37.7749,
        longitude: -122.4194,
        accuracy: 12.5,
        altitude: 15.0,
        speed: 0.0,
        bearing: 0.0,
        timestamp: DateTime.utc(2026, 9, 18, 12, 0).millisecondsSinceEpoch,
        provider: 'gps',
        address: {
          'street': 'Market St',
          'city': 'San Francisco',
          'state': 'CA',
          'country': 'USA',
          'formatted': 'Market St, San Francisco, CA, USA',
        },
      );

      final result = await tool.handler(
        const ToolCall(
          id: 'call_2',
          name: 'location',
          arguments: {'action': 'get_location'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('37.7749'));
      expect(result.output, contains('-122.4194'));
      expect(result.output, contains('Market St, San Francisco, CA, USA'));
      expect(result.output, contains('gps'));
    });

    test('formats coordinates only when action is get_coordinates', () async {
      fakeService.permitted = true;
      fakeService.mockLocation = LocationData(
        latitude: 12.9716,
        longitude: 77.5946,
        accuracy: 5.0,
        timestamp: 1600000000000,
        provider: 'network',
      );

      final result = await tool.handler(
        const ToolCall(
          id: 'call_3',
          name: 'location',
          arguments: {'action': 'get_coordinates'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Latitude: 12.9716'));
      expect(result.output, contains('Longitude: 77.5946'));
      expect(result.output, contains('Accuracy: ±5.0 m'));
      expect(result.output, isNot(contains('Address:')));
    });

    test('formats address only when action is get_address', () async {
      fakeService.permitted = true;
      fakeService.mockLocation = LocationData(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: 1600000000000,
        provider: 'network',
        address: {
          'city': 'Bengaluru',
          'state': 'Karnataka',
          'country': 'India',
        },
      );

      final result = await tool.handler(
        const ToolCall(
          id: 'call_4',
          name: 'location',
          arguments: {'action': 'get_address'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('City: Bengaluru'));
      expect(result.output, contains('State: Karnataka'));
      expect(result.output, contains('Country: India'));
      expect(result.output, isNot(contains('Coordinates:')));
    });
  });
}
