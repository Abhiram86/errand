import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Encrypts/decrypts short secrets (API keys) with AES-256-GCM.
///
/// Key management is deliberately simple: a random 32-byte key is generated
/// once and written to `<app-support>/errand.key`. The key file lives OUTSIDE
/// the database file, so a copied/backed-up errand.db alone contains nothing
/// readable. The threat model matches the app's on-device philosophy: it
/// protects against casual DB inspection and backup extraction — not against
/// a rooted device with file-level access to app-private storage.
///
/// Ciphertext format: base64(nonce ‖ cipherText ‑ mac). GCM authenticates,
/// so tampered rows fail with [SecretStoreException] instead of decoding to
/// garbage.
final class SecretStore {
  SecretStore._();

  static final SecretStore instance = SecretStore._();

  static const _keyFileName = 'errand.key';
  static final _algorithm = AesGcm.with256bits();

  Uint8List? _key;

  /// Loads (or creates) the encryption key. Idempotent; call once at startup
  /// before any secret access.
  Completer<void>? _keyInit;

  Future<void> ensureKey() async {
    if (_key != null) return;
    // Serialize concurrent initializers: without this, two callers can both
    // generate and write different keys, leaving memory and disk mismatched.
    var init = _keyInit;
    if (init != null) {
      await init.future;
      return;
    }
    init = Completer<void>();
    _keyInit = init;
    try {
      await _ensureKeyLocked();
    } finally {
      if (identical(_keyInit, init)) _keyInit = null;
      init.complete();
    }
  }

  Future<void> _ensureKeyLocked() async {
    final keyFile = await _keyFile();
    if (await keyFile.exists()) {
      final stored = await keyFile.readAsBytes();
      if (stored.length == 32) {
        _key = Uint8List.fromList(stored);
        return;
      }
      // Corrupt/legacy key file: regenerate rather than crash. Existing
      // ciphertext becomes undecryptable — callers surface that as "not set".
    }
    final newKey = await (await _algorithm.newSecretKey()).extractBytes();
    await keyFile.parent.create(recursive: true);
    await keyFile.writeAsBytes(newKey, flush: true);
    _key = Uint8List.fromList(newKey);
  }

  /// Visible for tests: injects a known key so round-trips are deterministic
  /// without touching the filesystem.
  void debugWithKey(List<int> keyBytes) {
    assert(keyBytes.length == 32, 'AES-256 needs a 32-byte key');
    _key = Uint8List.fromList(keyBytes);
  }

  /// Encrypts [plaintext]; returns a self-contained base64 token.
  Future<String> encryptString(String plaintext) async {
    await ensureKey();
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(_key!),
      nonce: nonce,
    );
    final packed = Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
    return base64Encode(packed);
  }

  /// Reverses [token] from [encryptString]. Throws [SecretStoreException]
  /// when the key changed or the payload was tampered with.
  Future<String> decryptString(String token) async {
    await ensureKey();
    late Uint8List packed;
    try {
      packed = base64Decode(token);
    } on FormatException {
      throw SecretStoreException('Malformed secret payload.');
    }
    const nonceLen = 12;
    const macLen = 16;
    if (packed.length < nonceLen + macLen) {
      throw SecretStoreException('Secret payload too short.');
    }
    final nonce = packed.sublist(0, nonceLen);
    final cipherText = packed.sublist(nonceLen, packed.length - macLen);
    final mac = Mac(packed.sublist(packed.length - macLen));
    List<int> clearBytes;
    try {
      clearBytes = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: SecretKey(_key!),
      );
    } on SecretBoxAuthenticationError {
      throw const SecretStoreException('Secret failed authentication.');
    }
    return utf8.decode(clearBytes);
  }

  Future<File> _keyFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _keyFileName));
  }
}

final class SecretStoreException implements Exception {
  final String message;

  const SecretStoreException(this.message);

  @override
  String toString() => message;
}
