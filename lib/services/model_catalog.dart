import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../llm/llm_client.dart' show cleanErrorMessage;
import '../models/model_option.dart';

const _catalogTimeout = Duration(seconds: 15);
const _testConnectionTimeout = Duration(seconds: 8);

class ConnectionTestResult {
  final bool success;
  final String message;
  final int modelCount;

  const ConnectionTestResult({
    required this.success,
    required this.message,
    this.modelCount = 0,
  });
}

class ModelCatalogService {
  static final Map<String, List<ModelOption>> _cache = {};
  static final Map<String, Future<List<ModelOption>>> _inFlight = {};

  final http.Client _client;

  ModelCatalogService({http.Client? client})
    : _client = client ?? http.Client();

  /// Loads models for the given endpoint and caches the result.
  Future<List<ModelOption>> load({
    required String baseUrl,
    required String apiKey,
    String? defaultProvider,
    bool? isOpenRouter,
    bool forceRefresh = false,
  }) {
    final cacheKey = _normalizeBaseUrl(baseUrl);
    if (!forceRefresh) {
      final cached = _cache[cacheKey];
      if (cached != null) return Future.value(cached);
    }

    final pending = _inFlight[cacheKey];
    if (pending != null && !forceRefresh) return pending;

    final request = _fetch(
      baseUrl: cacheKey,
      apiKey: apiKey,
      defaultProvider: defaultProvider,
      isOpenRouter: isOpenRouter,
    );
    _inFlight[cacheKey] = request;
    return request.whenComplete(() => _inFlight.remove(cacheKey));
  }

  /// Clears in-memory catalog cache (for all or a specific base URL).
  static void clearCache({String? baseUrl}) {
    if (baseUrl != null) {
      _cache.remove(_normalizeBaseUrl(baseUrl));
    } else {
      _cache.clear();
    }
  }

  /// Returns cached models for the given base URL if present in session memory.
  static List<ModelOption>? getCachedModels(String baseUrl) {
    return _cache[_normalizeBaseUrl(baseUrl)];
  }

  /// Whether models are currently cached for the given base URL.
  static bool hasCachedModels(String baseUrl) {
    return _cache.containsKey(_normalizeBaseUrl(baseUrl));
  }

  /// Tests connectivity and authentication to an OpenAI-compatible endpoint.
  Future<ConnectionTestResult> testConnection({
    required String baseUrl,
    required String apiKey,
    String? defaultProvider,
    bool? isOpenRouter,
  }) async {
    final normalized = _normalizeBaseUrl(baseUrl);
    final useOpenRouter = isOpenRouter ??
        (defaultProvider == null ||
            defaultProvider.toLowerCase().contains('openrouter') ||
            normalized.contains('openrouter.ai'));

    final Uri uri;
    try {
      final query = useOpenRouter ? '?output_modalities=text' : '';
      uri = Uri.parse('$normalized/models$query');
    } on FormatException catch (e) {
      return ConnectionTestResult(
        success: false,
        message: 'Invalid base URL: $e',
      );
    }

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(_testConnectionTimeout);

      if (response.statusCode == 200) {
        String? firstModelId;
        var count = 0;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['data'] is List) {
            final list = decoded['data'] as List;
            count = list.length;
            for (final item in list) {
              if (item is Map && item['id'] is String && (item['id'] as String).isNotEmpty) {
                firstModelId = item['id'] as String;
                break;
              }
            }
          } else if (decoded is List) {
            count = decoded.length;
            for (final item in decoded) {
              if (item is Map && item['id'] is String && (item['id'] as String).isNotEmpty) {
                firstModelId = item['id'] as String;
                break;
              }
            }
          }
        } catch (_) {}

        // If an API key was provided, verify authentication against /chat/completions.
        // Many endpoints (such as OpenCode Zen and OpenRouter) provide a public /models
        // route that returns HTTP 200 regardless of the key, but /chat/completions strictly validates it.
        if (apiKey.trim().isNotEmpty) {
          try {
            final chatUri = Uri.parse('$normalized/chat/completions');
            final authResponse = await _client
                .post(
                  chatUri,
                  headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    'Authorization': 'Bearer $apiKey',
                  },
                  body: jsonEncode({
                    'model': firstModelId ?? 'gpt-4o',
                    'messages': [
                      {'role': 'user', 'content': 'ping'}
                    ],
                    'max_tokens': 1,
                  }),
                )
                .timeout(_testConnectionTimeout);

            if (authResponse.statusCode == 401 || authResponse.statusCode == 403) {
              String authErr = 'Invalid API key or unauthorized';
              try {
                final errDecoded = jsonDecode(authResponse.body);
                if (errDecoded is Map) {
                  final errObj = errDecoded['error'];
                  if (errObj is Map && errObj['message'] != null) {
                    authErr = errObj['message'].toString();
                  } else if (errObj is String) {
                    authErr = errObj;
                  } else if (errDecoded['message'] != null) {
                    authErr = errDecoded['message'].toString();
                  }
                }
              } catch (_) {
                if (authResponse.body.isNotEmpty && authResponse.body.length < 120) {
                  authErr = authResponse.body;
                }
              }
              return ConnectionTestResult(
                success: false,
                message: 'Authentication failed (HTTP ${authResponse.statusCode}): $authErr',
              );
            }
          } catch (_) {
            // Non-fatal if /chat/completions ping has a connection issue, provided /models passed.
          }
        }

        final keyNotice = apiKey.trim().isEmpty ? ' (no key provided)' : '';
        return ConnectionTestResult(
          success: true,
          message: count > 0
              ? 'Connected & authenticated ($count models available$keyNotice)'
              : 'Connected & authenticated$keyNotice',
          modelCount: count,
        );
      }

      // If query parameters failed on a non-OpenRouter provider, retry clean
      if (useOpenRouter && (response.statusCode == 400 || response.statusCode == 404)) {
        return await testConnection(
          baseUrl: baseUrl,
          apiKey: apiKey,
          defaultProvider: defaultProvider,
          isOpenRouter: false,
        );
      }

      return ConnectionTestResult(
        success: false,
        message: cleanErrorMessage(response.statusCode, response.body),
      );
    } on TimeoutException {
      return const ConnectionTestResult(
        success: false,
        message: 'Connection timed out',
      );
    } on http.ClientException catch (e) {
      return ConnectionTestResult(
        success: false,
        message: 'Network error: ${e.message}',
      );
    } catch (e) {
      return ConnectionTestResult(
        success: false,
        message: 'Error: $e',
      );
    }
  }

  Future<List<ModelOption>> _fetch({
    required String baseUrl,
    required String apiKey,
    String? defaultProvider,
    bool? isOpenRouter,
  }) async {
    final useOpenRouter = isOpenRouter ??
        (defaultProvider == null ||
            defaultProvider.toLowerCase().contains('openrouter') ||
            baseUrl.contains('openrouter.ai'));

    final Uri uri;
    try {
      final query = useOpenRouter ? '?output_modalities=text' : '';
      uri = Uri.parse('$baseUrl/models$query');
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
      throw ModelCatalogException(
        'Model catalog request timed out after ${_catalogTimeout.inSeconds}s',
      );
    } on http.ClientException catch (e) {
      throw ModelCatalogException('Network error: ${e.message}');
    } catch (e) {
      throw ModelCatalogException('Network error: $e');
    }

    // If query parameter was rejected, retry without it
    if (useOpenRouter &&
        (response.statusCode == 400 || response.statusCode == 404)) {
      return _fetch(
        baseUrl: baseUrl,
        apiKey: apiKey,
        defaultProvider: defaultProvider,
        isOpenRouter: false,
      );
    }

    if (response.statusCode != 200) {
      throw ModelCatalogException(
        cleanErrorMessage(response.statusCode, response.body),
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

    List<dynamic> rawList = const [];
    if (decoded is Map<String, dynamic> && decoded['data'] is List) {
      rawList = decoded['data'] as List;
    } else if (decoded is List) {
      rawList = decoded;
    } else {
      throw const ModelCatalogException('Invalid model catalog response');
    }

    try {
      final models = <ModelOption>[];
      for (final rawModel in rawList) {
        if (rawModel is! Map) continue;
        final id = rawModel['id'];
        if (id is! String || id.isEmpty) continue;
        if (_isDeprecated(id, rawModel)) continue;

        final rawName = rawModel['name'];
        final name = rawName is String && rawName.isNotEmpty ? rawName : id;
        final modalityInfo = _inputModalitiesFor(id, rawModel);

        models.add(
          ModelOption(
            id: id,
            name: name,
            provider: _providerFor(id, defaultProvider: defaultProvider),
            inputModalities: modalityInfo.modalities,
            hasExplicitModalities: modalityInfo.explicit,
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

  static const Set<String> _knownDeprecatedModelIds = {
    'deepseek-v4-flash-free',
  };

  static bool _isDeprecated(String id, Map rawModel) {
    if (_knownDeprecatedModelIds.contains(id.toLowerCase().trim())) {
      return true;
    }
    final status = rawModel['status']?.toString().toLowerCase().trim();
    if (status == 'deprecated' || status == 'inactive' || status == 'disabled') {
      return true;
    }
    final deprecated = rawModel['deprecated'];
    if (deprecated == true || deprecated == 1 || deprecated == 'true') {
      return true;
    }
    final isDeprecated = rawModel['is_deprecated'];
    if (isDeprecated == true || isDeprecated == 1 || isDeprecated == 'true') {
      return true;
    }
    return false;
  }

  static String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Extracts input modalities.
  ///
  /// If OpenRouter's `architecture.input_modalities` is present, honors it.
  /// If absent, infers vision capabilities from well-known model family patterns.
  static ({List<String> modalities, bool explicit}) _inputModalitiesFor(
    String id,
    Map rawModel,
  ) {
    final architecture = rawModel['architecture'];
    if (architecture is Map) {
      final modalities = architecture['input_modalities'];
      if (modalities is List) {
        final result = <String>[
          for (final modality in modalities)
            if (modality is String && modality.isNotEmpty) modality,
        ];
        final list = result.contains('text') ? result : ['text', ...result];
        return (modalities: list, explicit: true);
      }
    }

    return (modalities: const ['text'], explicit: false);
  }

  /// Whether [modelId] claims support for an input modality.
  ///
  /// Returns true/false when positively known; null when unknown / unverified
  /// ("allow the attempt").
  static bool? supportsInput(String modelId, String modality, {String? baseUrl}) {
    if (baseUrl != null) {
      final key = _normalizeBaseUrl(baseUrl);
      final models = _cache[key];
      if (models == null) return null;
      for (final option in models) {
        if (option.id != modelId) continue;
        if (option.supportsInput(modality)) return true;
        if (option.hasExplicitModalities) return false;
        return null;
      }
      return null;
    }

    for (final models in _cache.values) {
      for (final option in models) {
        if (option.id != modelId) continue;
        if (option.supportsInput(modality)) return true;
        if (option.hasExplicitModalities) return false;
        return null;
      }
    }
    return null;
  }

  static String _providerFor(String id, {String? defaultProvider}) {
    final separator = id.indexOf('/');
    if (separator <= 0) {
      return (defaultProvider != null && defaultProvider.trim().isNotEmpty)
          ? defaultProvider.trim()
          : 'OpenRouter';
    }
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
