import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const kTavilyApiKey = String.fromEnvironment('TAVILY_API_KEY');
const _tavilyTimeout = Duration(seconds: 15);

class TavilyClient {
  final String apiKey;
  final http.Client _client;
  final bool _ownsClient;

  TavilyClient({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  Future<Map<String, dynamic>> search(
    String query, {
    int maxResults = 5,
  }) async {
    return _post('/search', {
      'query': query,
      'search_depth': 'basic',
      'max_results': maxResults,
      'include_answer': false,
      'include_raw_content': false,
    });
  }

  Future<Map<String, dynamic>> extract({
    required String url,
    String? query,
  }) async {
    return _post('/extract', {
      'urls': [url],
      'extract_depth': 'basic',
      'format': 'markdown',
      'include_images': false,
      if (query != null && query.isNotEmpty) 'query': query,
    });
  }

  Future<Map<String, dynamic>> _post(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    if (apiKey.trim().isEmpty) {
      throw const TavilyException('TAVILY_API_KEY is not configured.');
    }

    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('https://api.tavily.com$endpoint'),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(_tavilyTimeout);
    } on TimeoutException {
      throw TavilyException('Tavily request timed out after ${_tavilyTimeout.inSeconds}s');
    }

    final decoded = _decodeResponse(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded?['detail'] ?? decoded?['message'];
      throw TavilyException(
        'Tavily HTTP ${response.statusCode}: ${message ?? response.body}',
      );
    }
    if (decoded == null) {
      throw const TavilyException('Tavily returned an invalid response.');
    }
    return decoded;
  }

  Map<String, dynamic>? _decodeResponse(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class TavilyException implements Exception {
  final String message;

  const TavilyException(this.message);

  @override
  String toString() => message;
}
