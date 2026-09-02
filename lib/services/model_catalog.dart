import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/model_option.dart';

const _catalogTimeout = Duration(seconds: 15);

class ModelCatalogService {
  static final Map<String, List<ModelOption>> _cache = {};
  static final Map<String, Future<List<ModelOption>>> _inFlight = {};

  final http.Client _client;

  ModelCatalogService({http.Client? client})
    : _client = client ?? http.Client();

  Future<List<ModelOption>> load({
    required String baseUrl,
    required String apiKey,
  }) {
    final cacheKey = _normalizeBaseUrl(baseUrl);
    final cached = _cache[cacheKey];
    if (cached != null) return Future.value(cached);

    final pending = _inFlight[cacheKey];
    if (pending != null) return pending;

    final request = _fetch(baseUrl: cacheKey, apiKey: apiKey);
    _inFlight[cacheKey] = request;
    return request.whenComplete(() => _inFlight.remove(cacheKey));
  }

  Future<List<ModelOption>> _fetch({
    required String baseUrl,
    required String apiKey,
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse('$baseUrl/models?output_modalities=text');
    } on FormatException catch (e) {
      throw ModelCatalogException('Invalid base URL "$baseUrl": $e');
    }

    http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(_catalogTimeout);
    } on TimeoutException {
      throw ModelCatalogException('Model catalog request timed out after ${_catalogTimeout.inSeconds}s');
    } on http.ClientException catch (e) {
      throw ModelCatalogException('Network error: ${e.message}');
    } catch (e) {
      throw ModelCatalogException('Network error: $e');
    }

    if (response.statusCode != 200) {
      throw ModelCatalogException(
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw ModelCatalogException('Invalid JSON in model catalog response: $e');
    } catch (e) {
      throw ModelCatalogException('Failed to parse model catalog response: $e');
    }
    if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
      throw const ModelCatalogException('Invalid model catalog response');
    }

    try {
      final models = <ModelOption>[];
      for (final rawModel in decoded['data'] as List) {
        if (rawModel is! Map) continue;
        final id = rawModel['id'];
        if (id is! String || id.isEmpty) continue;

        final rawName = rawModel['name'];
        final name = rawName is String && rawName.isNotEmpty ? rawName : id;
        models.add(
          ModelOption(
            id: id,
            name: name,
            provider: _providerFor(id),
            inputModalities: _inputModalitiesFor(rawModel),
          ),
        );
      }

      if (models.isEmpty) {
        throw const ModelCatalogException('Model catalog was empty');
      }

      final result = List<ModelOption>.unmodifiable(models);
      _cache[_normalizeBaseUrl(baseUrl)] = result;
      return result;
    } catch (e) {
      if (e is ModelCatalogException) rethrow;
      throw ModelCatalogException('Failed to process model catalog: $e');
    }
  }

  static String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Extracts `architecture.input_modalities` (["text","image","audio",
  /// "video","file"]); defaults to ["text"] when absent or malformed.
  static List<String> _inputModalitiesFor(Map rawModel) {
    final architecture = rawModel['architecture'];
    if (architecture is! Map) return const ['text'];
    final modalities = architecture['input_modalities'];
    if (modalities is! List) return const ['text'];
    final result = <String>[
      for (final modality in modalities)
        if (modality is String && modality.isNotEmpty) modality,
    ];
    return result.contains('text') ? result : ['text', ...result];
  }

  /// Whether [modelId] claims support for an input modality.
  ///
  /// When [baseUrl] is provided (normalized), only that catalog is consulted —
  /// O(n) in the target catalog. Without it, every cached catalog is scanned
  /// — O(total). Prefer the baseUrl form on the hot path (tool calls).
  ///
  /// Returns true/false from catalog knowledge; null when the model isn't in
  /// the consulted cache(s) (custom endpoints that don't report architecture)
  /// — callers should treat null as "allow the attempt".
  static bool? supportsInput(String modelId, String modality, {String? baseUrl}) {
    if (baseUrl != null) {
      final key = _normalizeBaseUrl(baseUrl);
      final models = _cache[key];
      if (models == null) return null;
      var seen = false;
      for (final option in models) {
        if (option.id != modelId) continue;
        seen = true;
        if (option.supportsInput(modality)) return true;
      }
      return seen ? false : null;
    }
    var seen = false;
    for (final models in _cache.values) {
      for (final option in models) {
        if (option.id != modelId) continue;
        seen = true;
        if (option.supportsInput(modality)) return true;
      }
    }
    return seen ? false : null;
  }

  static String _providerFor(String id) {
    final separator = id.indexOf('/');
    if (separator <= 0) return 'OpenRouter';
    return id.substring(0, separator);
  }

  void close() => _client.close();
}

class ModelCatalogException implements Exception {
  final String message;

  const ModelCatalogException(this.message);

  @override
  String toString() => message;
}
