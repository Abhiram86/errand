import 'dart:async';

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
    final lat = map['latitude'];
    final lng = map['longitude'];
    if (lat is! num || lng is! num) {
      throw const FormatException('Invalid location payload');
    }
    Map<String, dynamic> address = const {};
    try {
      final raw = map['address'];
      if (raw is Map) {
        address = Map<String, dynamic>.fromEntries(
          raw.entries.map((e) => MapEntry(e.key.toString(), e.value)),
        );
      }
    } catch (_) {
      address = const {};
    }
    return LocationData(
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      accuracy: (map['accuracy'] as num?)?.toDouble(),
      altitude: (map['altitude'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      bearing: (map['bearing'] as num?)?.toDouble(),
      timestamp: (map['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      provider: map['provider'] as String? ?? 'unknown',
      address: address,
    );
  }

  String? get city => address['city']?.toString();
  String? get state => address['state']?.toString();
  String? get country => address['country']?.toString();
  String? get street => address['street']?.toString();
  String? get formattedAddress => address['formatted']?.toString();

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

  /// Coarse locality for the system prompt: city/state/country plus
  /// city-level (~2 decimal) coordinates. Avoids leaking street address
  /// and full-precision GPS on every turn; the full `location` tool
  /// still serves exact coordinates on demand.
  String toCoarseSummary() {
    final parts = <String>[];
    if (city != null && city!.isNotEmpty) parts.add(city!);
    if (state != null && state!.isNotEmpty) parts.add(state!);
    if (country != null && country!.isNotEmpty) parts.add(country!);
    final place = parts.isNotEmpty ? parts.join(', ') : null;
    final coordStr =
        '${latitude.toStringAsFixed(2)}, ${longitude.toStringAsFixed(2)}';
    if (place != null) return '$place (~$coordStr)';
    return '~$coordStr';
  }
}

/// Native Android location service via MethodChannel('location').
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const _channel = MethodChannel('location');

  LocationData? _lastKnown;
  LocationData? get lastKnown => _lastKnown;
  Future<LocationData?>? _inFlight;

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

  Future<LocationData?> getLocation({bool requestIfMissing = true}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _fetchLocation(requestIfMissing: requestIfMissing);
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<LocationData?> _fetchLocation({bool requestIfMissing = true}) async {
    try {
      var permitted = await hasPermission();
      if (!permitted && requestIfMissing) {
        permitted = await requestPermission();
      }
      if (!permitted) {
        return null;
      }

      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getLocation')
          .timeout(const Duration(seconds: 12));
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
