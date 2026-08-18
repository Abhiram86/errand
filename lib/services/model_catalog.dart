import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/model_option.dart';

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
    final uri = Uri.parse('$baseUrl/models?output_modalities=text');
    final response = await _client.get(
      uri,
      headers: {
        'Accept': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
    );

    if (response.statusCode != 200) {
      throw ModelCatalogException(
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
      throw const ModelCatalogException('Invalid model catalog response');
    }

    final models = <ModelOption>[];
    for (final rawModel in decoded['data'] as List) {
      if (rawModel is! Map) continue;
      final id = rawModel['id'];
      if (id is! String || id.isEmpty) continue;

      final rawName = rawModel['name'];
      final name = rawName is String && rawName.isNotEmpty ? rawName : id;
      models.add(ModelOption(id: id, name: name, provider: _providerFor(id)));
    }

    if (models.isEmpty) {
      throw const ModelCatalogException('Model catalog was empty');
    }

    final result = List<ModelOption>.unmodifiable(models);
    _cache[_normalizeBaseUrl(baseUrl)] = result;
    return result;
  }

  static String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
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
