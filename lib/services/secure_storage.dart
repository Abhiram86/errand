import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _apiKeyKey = 'openai_api_key';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<void> saveApiKeyDB(String apiKey) async {
    // TODO: implement saveApiKeyDB
    throw UnimplementedError();
  }

  Future<void> saveApiKey(String apiKey) async {
    await _storage.write(
      key: _apiKeyKey,
      value: apiKey,
    );
  }

  Future<String?> getApiKey() async {
    return _storage.read(key: _apiKeyKey);
  }

  Future<void> deleteApiKey() async {
    await _storage.delete(key: _apiKeyKey);
  }

  Future<bool> hasApiKey() async {
    return await _storage.containsKey(key: _apiKeyKey);
  }
}