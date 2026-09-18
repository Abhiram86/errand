import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Structured location and reverse-geocoded address.
class LocationData {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? altitude;
  final double? speed;
  final double? bearing;
  final int timestamp;
  final String provider;
  final Map<String, dynamic> address;

  LocationData({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.altitude,
    this.speed,
    this.bearing,
    required this.timestamp,
    required this.provider,
    this.address = const {},
  });

  factory LocationData.fromMap(Map<dynamic, dynamic> map) {
    return LocationData(
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      accuracy: (map['accuracy'] as num?)?.toDouble(),
      altitude: (map['altitude'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      bearing: (map['bearing'] as num?)?.toDouble(),
      timestamp: (map['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      provider: map['provider'] as String? ?? 'unknown',
      address: Map<String, dynamic>.from(map['address'] as Map? ?? {}),
    );
  }

  String? get city => address['city'] as String?;
  String? get state => address['state'] as String?;
  String? get country => address['country'] as String?;
  String? get street => address['street'] as String?;
  String? get formattedAddress => address['formatted'] as String?;

  String toSummary() {
    final parts = <String>[];
    if (street != null && street!.isNotEmpty) parts.add(street!);
    if (city != null && city!.isNotEmpty) parts.add(city!);
    if (state != null && state!.isNotEmpty) parts.add(state!);
    if (country != null && country!.isNotEmpty) parts.add(country!);

    final place = parts.isNotEmpty ? parts.join(', ') : null;
    final coordStr = '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
    if (place != null) {
      return '$place ($coordStr)';
    }
    return coordStr;
  }
}

/// Native Android location service via MethodChannel('location').
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const _channel = MethodChannel('location');

  LocationData? _lastKnown;
  LocationData? get lastKnown => _lastKnown;

  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<LocationData?> getLocation({bool requestIfMissing = true}) async {
    try {
      var permitted = await hasPermission();
      if (!permitted && requestIfMissing) {
        permitted = await requestPermission();
      }
      if (!permitted) {
        return null;
      }

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getLocation');
      if (result != null) {
        _lastKnown = LocationData.fromMap(result);
        return _lastKnown;
      }
    } catch (e) {
      debugPrint('LocationService: error fetching location: $e');
    }
    return null;
  }
}
