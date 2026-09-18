import '../agent/tool.dart';
import '../services/location_service.dart';
import '../types/tool.dart';

/// Exposes device GPS coordinates and reverse-geocoded physical address
/// to the LLM agent.
Tool locationTool({LocationService? locationService}) {
  final service = locationService ?? LocationService.instance;

  return Tool(
    name: 'location',
    description:
        'Get the user\'s current GPS coordinates and reverse-geocoded physical address '
        '(city, state, country, street). Use this whenever the user asks about local context, '
        'weather, nearby places, directions, or current position.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['get_location', 'get_coordinates', 'get_address'],
          'description':
              'What location information to return. "get_location" returns both coordinates '
              'and resolved address. "get_coordinates" returns numeric GPS lat/long only. '
              '"get_address" returns the street, city, state, country name only.',
        },
      },
    },
    handler: (call) async {
      final action = call.arguments['action'] as String? ?? 'get_location';

      final permitted = await service.hasPermission();
      if (!permitted) {
        final granted = await service.requestPermission();
        if (!granted) {
          return ToolCallResult.failure(
            call.id,
            'Location permission is not granted on the device. Ask the user to grant location access in device Settings.',
            type: 'permission_denied',
          );
        }
      }

      final loc = await service.getLocation(requestIfMissing: false);
      if (loc == null) {
        return ToolCallResult.failure(
          call.id,
          'Unable to retrieve location. Ensure location services (GPS or Network) are turned on in Android Settings.',
          type: 'location_unavailable',
        );
      }

      final buffer = StringBuffer();
      final dt = DateTime.fromMillisecondsSinceEpoch(loc.timestamp).toUtc().toIso8601String();

      switch (action) {
        case 'get_coordinates':
          buffer.writeln('Coordinates:');
          buffer.writeln('  Latitude: ${loc.latitude}');
          buffer.writeln('  Longitude: ${loc.longitude}');
          if (loc.accuracy != null) {
            buffer.writeln('  Accuracy: ±${loc.accuracy!.toStringAsFixed(1)} m');
          }
          if (loc.altitude != null && loc.altitude != 0) {
            buffer.writeln('  Altitude: ${loc.altitude!.toStringAsFixed(1)} m');
          }
          buffer.writeln('  Timestamp: $dt');
          break;

        case 'get_address':
          buffer.writeln('Address:');
          if (loc.street != null && loc.street!.isNotEmpty) {
            buffer.writeln('  Street: ${loc.street}');
          }
          if (loc.city != null && loc.city!.isNotEmpty) {
            buffer.writeln('  City: ${loc.city}');
          }
          if (loc.state != null && loc.state!.isNotEmpty) {
            buffer.writeln('  State: ${loc.state}');
          }
          if (loc.country != null && loc.country!.isNotEmpty) {
            buffer.writeln('  Country: ${loc.country}');
          }
          if (loc.formattedAddress != null && loc.formattedAddress!.isNotEmpty) {
            buffer.writeln('  Formatted: ${loc.formattedAddress}');
          }
          break;

        case 'get_location':
        default:
          buffer.writeln('Location Summary: ${loc.toSummary()}');
          buffer.writeln('Coordinates: ${loc.latitude}, ${loc.longitude} (±${loc.accuracy?.toStringAsFixed(1) ?? "?"}m)');
          if (loc.formattedAddress != null && loc.formattedAddress!.isNotEmpty) {
            buffer.writeln('Address: ${loc.formattedAddress}');
          }
          buffer.writeln('Provider: ${loc.provider} (Timestamp: $dt)');
          break;
      }

      return ToolCallResult(
        id: call.id,
        ok: true,
        output: buffer.toString().trim(),
      );
    },
  );
}
