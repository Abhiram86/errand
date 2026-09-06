import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service for querying model specifications and context limits from models.dev.
///
/// Models.dev provides provider-agnostic model metadata including context limits
/// (limit.context in tokens) across hundreds of open-source and proprietary models.
class ModelsDevService {
  static const String modelsDevUrl = 'https://models.dev/models.json';
  static const Duration _fetchTimeout = Duration(seconds: 10);

  /// In-memory cache of normalized model identifier -> context limit in tokens.
  static final Map<String, int> _cache = {};
  static bool _hasLoaded = false;
  static Future<void>? _inFlight;

  final http.Client _client;

  ModelsDevService({http.Client? client}) : _client = client ?? http.Client();

  /// Pre-seeded context limits for prominent models to ensure instant availability
  /// even before network requests complete or in offline environments.
  static final Map<String, int> _seedLimits = {
    // Anthropic
    'claude-3-7-sonnet': 200000,
    'claude-3-5-sonnet': 200000,
    'claude-3-5-haiku': 200000,
    'claude-3-opus': 200000,
    'claude-sonnet-4-6': 1000000,
    'claude-opus-5': 1000000,
    // OpenAI
    'gpt-4o': 128000,
    'gpt-4o-mini': 128000,
    'gpt-4-turbo': 128000,
    'gpt-3.5-turbo': 16384,
    'o1': 200000,
    'o1-mini': 128000,
    'o3-mini': 200000,
    'gpt-5': 1000000,
    'gpt-5.4': 1000000,
    'gpt-6': 1000000,
    // Google
    'gemini-2.0-flash': 1048576,
    'gemini-2.0-flash-lite': 1048576,
    'gemini-2.0-pro': 2097152,
    'gemini-1.5-pro': 2097152,
    'gemini-1.5-flash': 1048576,
    // Meta Llama
    'llama-3.3-70b': 128000,
    'llama-3.1-70b': 128000,
    'llama-3.1-8b': 128000,
    'llama-3.2-3b': 128000,
    'llama-3.2-1b': 128000,
    'llama-3-70b': 8192,
    'llama-3-8b': 8192,
    // Mistral
    'mixtral-8x7b': 32768,
    'mistral-large': 128000,
    'mistral-small': 32768,
    // OpenCode & Others
    'nemotron-3.5-lightning': 131072,
    'ling-3.0-flash': 128000,
    'qwen-2.5-72b': 131072,
    'deepseek-chat': 64000,
    'deepseek-reasoner': 64000,
    'deepseek-v3': 64000,
    'deepseek-r1': 64000,
  };

  /// Preloads the catalog in the background if not yet loaded.
  static void preload({http.Client? client}) {
    if (_hasLoaded || _inFlight != null) return;
    unawaited(ModelsDevService(client: client).load().catchError((_) {}));
  }

  /// Clears the models.dev memory cache (primarily used for testing).
  static void clearCache() {
    _cache.clear();
    _hasLoaded = false;
    _inFlight = null;
  }

  /// Fetches model definitions from models.dev and populates the cache.
  Future<void> load({bool forceRefresh = false}) async {
    if (_hasLoaded && !forceRefresh) return;
    if (_inFlight != null && !forceRefresh) return _inFlight!;

    final future = _fetch();
    _inFlight = future;
    try {
      await future;
      _hasLoaded = true;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _fetch() async {
    try {
      final response = await _client
          .get(
            Uri.parse(modelsDevUrl),
            headers: {
              'Accept': 'application/json',
              'User-Agent': 'handy_flutter/1.0',
            },
          )
          .timeout(_fetchTimeout);

      if (response.statusCode != 200) return;

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return;

      for (final entry in decoded.entries) {
        final val = entry.value;
        if (val is! Map) continue;
        final limit = val['limit'];
        if (limit is Map && limit['context'] is num) {
          final ctx = (limit['context'] as num).toInt();
          if (ctx > 0) {
            final key = entry.key.toLowerCase().trim();
            _cache[key] = ctx;
          }
        }
      }
    } catch (_) {
      // Non-fatal: if models.dev is unreachable, seeded limits and provider metadata apply.
    }
  }

  /// Looks up the native context limit in tokens for [modelId].
  ///
  /// Evaluates in order:
  /// 1. Dynamic cache from models.dev (exact key match)
  /// 2. Normalized slug match (dots replaced with dashes)
  /// 3. Model basename match (excluding provider prefix e.g. "anthropic/claude-3.7-sonnet" -> "claude-3-7-sonnet")
  /// 4. Qualifier-stripped fuzzy match (removing "-instruct", "-versatile", dates, etc.)
  /// 5. Pre-seeded fallback limits
  ///
  /// Returns `null` if no context limit could be inferred.
  static int? lookupContextTokens(String modelId) {
    final raw = modelId.trim().toLowerCase();
    if (raw.isEmpty) return null;

    // 1. Exact match in models.dev cache
    if (_cache.containsKey(raw)) return _cache[raw];

    final normalized = _normalizeSlug(raw);
    if (_cache.containsKey(normalized)) return _cache[normalized];

    // 2. Base name match without provider prefix
    final baseName = _baseName(normalized);
    for (final entry in _cache.entries) {
      if (_baseName(_normalizeSlug(entry.key)) == baseName) {
        return entry.value;
      }
    }

    // 3. Qualifier-stripped matching against models.dev
    final cleanQuery = _stripQualifiers(baseName);
    for (final entry in _cache.entries) {
      final cleanKey = _stripQualifiers(_baseName(_normalizeSlug(entry.key)));
      if (cleanKey.isNotEmpty && (cleanKey == cleanQuery || cleanKey.contains(cleanQuery) || cleanQuery.contains(cleanKey))) {
        return entry.value;
      }
    }

    // 4. Pre-seeded table matching
    for (final entry in _seedLimits.entries) {
      final seedNorm = _normalizeSlug(entry.key.toLowerCase());
      final seedClean = _stripQualifiers(seedNorm);
      if (baseName == seedNorm ||
          baseName.contains(seedNorm) ||
          seedNorm.contains(baseName) ||
          cleanQuery == seedClean ||
          cleanQuery.contains(seedClean) ||
          seedClean.contains(cleanQuery)) {
        return entry.value;
      }
    }

    // 5. Check if model name has an explicit token indicator (e.g. "32k", "128k", "1m")
    final nameIndicator = _extractContextFromName(raw);
    if (nameIndicator != null) return nameIndicator;

    return null;
  }

  static String _normalizeSlug(String s) => s.replaceAll('.', '-');

  static String _baseName(String s) {
    final slash = s.lastIndexOf('/');
    return slash >= 0 ? s.substring(slash + 1) : s;
  }

  static String _stripQualifiers(String s) {
    var result = s;
    final qualifiers = [
      '-instruct',
      '-versatile',
      '-instant',
      '-preview',
      '-latest',
      '-free',
      '-chat',
      '-fin',
      '-lightning',
    ];
    for (final q in qualifiers) {
      result = result.replaceAll(q, '');
    }
    // Remove date stamps like -20250219 or -2024-05-13, and revision suffixes like -001, -002
    result = result.replaceAll(RegExp(r'-\d{8}\b'), '');
    result = result.replaceAll(RegExp(r'-\d{4}-\d{2}-\d{2}\b'), '');
    result = result.replaceAll(RegExp(r'-\d{3,4}\b'), '');
    return result;
  }

  static int? _extractContextFromName(String s) {
    final match = RegExp(r'(\d+)(k|m)\b', caseSensitive: false).firstMatch(s);
    if (match != null) {
      final numVal = int.tryParse(match.group(1) ?? '');
      final unit = match.group(2)?.toLowerCase();
      if (numVal != null && numVal > 0) {
        if (unit == 'k') return numVal * 1024;
        if (unit == 'm') return numVal * 1024 * 1024;
      }
    }
    return null;
  }
}
