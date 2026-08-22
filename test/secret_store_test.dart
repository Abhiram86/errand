import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/secret_store.dart';

void main() {
  final key = List<int>.generate(32, (i) => i);

  test('encrypt → decrypt round-trips', () async {
    final store = SecretStore.instance..debugWithKey(key);
    const secret = 'sk-or-v1-abc123def456';

    final token = await store.encryptString(secret);
    expect(token, isNot(contains(secret)), reason: 'ciphertext is base64');

    expect(await store.decryptString(token), secret);
  });

  test('each encryption uses a fresh nonce', () async {
    final store = SecretStore.instance..debugWithKey(key);
    final a = await store.encryptString('same input');
    final b = await store.encryptString('same input');
    expect(a, isNot(b));
  });

  test('tampered payload throws instead of decoding to garbage', () async {
    final store = SecretStore.instance..debugWithKey(key);
    var token = await store.encryptString('do not tamper');
    final bytes = List<int>.of(token.codeUnits);
    bytes[10] = bytes[10] == 65 ? 66 : 65; // flip one base64 char
    token = String.fromCharCodes(bytes);

    await expectLater(
      store.decryptString(token),
      throwsA(isA<SecretStoreException>()),
    );
  });

  test('wrong key fails authentication', () async {
    final writer = SecretStore.instance..debugWithKey(key);
    final token = await writer.encryptString('locked');

    final otherKey = List<int>.generate(32, (i) => 31 - i);
    final reader = SecretStore.instance..debugWithKey(otherKey);
    await expectLater(
      reader.decryptString(token),
      throwsA(isA<SecretStoreException>()),
    );
  });
}
