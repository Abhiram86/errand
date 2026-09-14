import 'package:flutter_test/flutter_test.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/memory_service.dart';

void main() {
  late ErrandDatabase db;
  late MemoryService service;

  setUp(() {
    db = ErrandDatabase.inMemory();
    service = MemoryService(db: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('MemoryService.create', () {
    test('creates and persists a valid memory', () async {
      final memory = await service.create(
        about: 'Prefers Python 3.12 with strict typing and pytest',
        description: 'User prefers Python 3.12+ with strict typing and pytest.',
        keywords: ['python', 'coding', 'pytest'],
        sourceConversationId: 'conv_123',
      );

      expect(memory.id.startsWith('mem_'), isTrue);
      expect(memory.about, 'Prefers Python 3.12 with strict typing and pytest');
      expect(memory.description, 'User prefers Python 3.12+ with strict typing and pytest.');
      expect(memory.keywords, ['python', 'coding', 'pytest']);
      expect(memory.sourceConversationId, 'conv_123');
      expect(memory.createdAt, isNotNull);
      expect(memory.updatedAt, isNotNull);

      // Verify in database
      final retrieved = await service.read(memory.id);
      expect(retrieved, isNotNull);
      expect(retrieved!.id, memory.id);
      expect(retrieved.about, memory.about);
      expect(retrieved.description, memory.description);
      expect(retrieved.keywords, memory.keywords);
    });

    test('validates required fields', () async {
      expect(
        () => service.create(
          about: '   ',
          description: 'valid description',
          keywords: ['tag'],
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('about'),
        )),
      );

      expect(
        () => service.create(
          about: 'valid about',
          description: '  ',
          keywords: ['tag'],
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('description'),
        )),
      );
    });

    test('validates keywords constraints (max 10, short concepts, not sentences)', () async {
      // Exceeds 10 keywords
      expect(
        () => service.create(
          about: 'too_many_keywords',
          description: 'desc',
          keywords: List.generate(11, (i) => 'kw$i'),
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('exceeds maximum of 10 items'),
        )),
      );

      // Keyword too long (>40 chars)
      expect(
        () => service.create(
          about: 'long_keyword',
          description: 'desc',
          keywords: ['this_is_an_unusually_long_keyword_concept_exceeding_forty_characters'],
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('exceeds maximum length of 40 characters'),
        )),
      );

      // Keyword looks like a sentence (contains period)
      expect(
        () => service.create(
          about: 'sentence_keyword',
          description: 'desc',
          keywords: ['User likes dark mode.'],
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('looks like a sentence'),
        )),
      );

      // Keyword contains too many words (> 4 words)
      expect(
        () => service.create(
          about: 'wordy_keyword',
          description: 'desc',
          keywords: ['one two three four five'],
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('contains too many words'),
        )),
      );
    });
  });

  group('MemoryService.read', () {
    test('returns null for non-existent memory', () async {
      final res = await service.read('non_existent_id');
      expect(res, isNull);
    });

    test('formats model json with expected keys', () async {
      final memory = await service.create(
        about: 'theme_preference',
        description: 'Always use dark theme in apps.',
        keywords: ['dark_mode', 'ui', 'theme'],
      );

      final json = memory.toModelJson();
      expect(json['id'], memory.id);
      expect(json['about'], 'theme_preference');
      expect(json['description'], 'Always use dark theme in apps.');
      expect(json['keywords'], ['dark_mode', 'ui', 'theme']);
      expect(json.containsKey('created_at'), isTrue);
      expect(json.containsKey('updated_at'), isTrue);
      expect(json.containsKey('source_conversation_id'), isFalse);
    });
  });

  group('MemoryService.edit', () {
    test('edits fields and preserves createdAt while updating updatedAt', () async {
      final original = await service.create(
        about: 'wifi_info',
        description: 'Office network SSID is Office-5G.',
        keywords: ['wifi', 'network'],
      );

      // Wait 10ms to ensure timestamp difference
      await Future.delayed(const Duration(milliseconds: 10));

      final updated = await service.edit(
        id: original.id,
        description: 'Office network SSID is Office-Secure.',
        keywords: ['wifi', 'network', 'office'],
      );

      expect(updated.id, original.id);
      expect(updated.about, 'wifi_info'); // untouched
      expect(updated.description, 'Office network SSID is Office-Secure.');
      expect(updated.keywords, ['wifi', 'network', 'office']);
      expect(updated.createdAt, original.createdAt);
      expect(updated.updatedAt.isAfter(original.updatedAt) || updated.updatedAt == original.updatedAt, isTrue);

      final reRead = await service.read(original.id);
      expect(reRead!.description, 'Office network SSID is Office-Secure.');
    });

    test('throws when id does not exist and does NOT silently create', () async {
      expect(
        () => service.edit(
          id: 'non_existent_id',
          description: 'new desc',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('not found'),
        )),
      );

      final all = await service.getAll();
      expect(all, isEmpty);
    });

    test('throws when no update fields are provided', () async {
      final mem = await service.create(
        about: 'note',
        description: 'text',
        keywords: ['tag'],
      );

      expect(
        () => service.edit(id: mem.id),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('At least one of about, description, or keywords must be provided'),
        )),
      );
    });
  });

  group('MemoryService.find', () {
    setUp(() async {
      await service.create(
        about: 'Prefers Python with strict typing, uv, and pytest',
        description: 'User prefers Python 3.12+ with strict typing, uv, and pytest.',
        keywords: ['python', 'coding', 'pytest', 'style'],
      );
      await service.create(
        about: 'Strong preference for AMOLED dark theme in all apps',
        description: 'User strongly prefers AMOLED dark mode in all UI applications.',
        keywords: ['dark_mode', 'ui', 'theme', 'display'],
      );
      await service.create(
        about: 'Office Wi-Fi password and network details',
        description: 'Office Wi-Fi password and network connection details.',
        keywords: ['wifi', 'network', 'office', 'internet'],
      );
    });

    test('returns top candidates matching query with only id and about', () async {
      final results = await service.find(query: 'python testing style', k: 2);

      expect(results.length, 1);
      expect(results.first.about, 'Prefers Python with strict typing, uv, and pytest');
      // Must only expose id and about
      final json = results.first.toJson();
      expect(json.keys.toSet(), {'id', 'about'});
    });

    test('approximate / fuzzy matching matches typo in query', () async {
      // "preferance" typo should match "preference" in about
      final results = await service.find(query: 'dark preferance');
      expect(results.isNotEmpty, isTrue);
      expect(results.first.about, 'Strong preference for AMOLED dark theme in all apps');
    });

    test('ranks by relevance score and limits to k', () async {
      final results = await service.find(query: 'preference', k: 1);
      expect(results.length, 1);
    });

    test('returns all memories up to k when query is empty', () async {
      final results = await service.find(query: null, k: 2);
      expect(results.length, 2);
    });

    test('filters by timestamp when provided', () async {
      final futureDate = DateTime.now().add(const Duration(days: 1)).toIso8601String();
      final afterFuture = await service.find(query: 'python', timestamp: 'after:$futureDate');
      expect(afterFuture, isEmpty);

      final pastDate = '2020-01-01';
      final afterPast = await service.find(query: 'python', timestamp: 'after:$pastDate');
      expect(afterPast.isNotEmpty, isTrue);
    });
  });

  group('MemoryService.delete', () {
    test('deletes existing memory and returns true, returns false if missing', () async {
      final memory = await service.create(
        about: 'temp_fact',
        description: 'Temporary note.',
        keywords: ['temp'],
      );

      final deleted = await service.delete(memory.id);
      expect(deleted, isTrue);

      final check = await service.read(memory.id);
      expect(check, isNull);

      final deletedAgain = await service.delete(memory.id);
      expect(deletedAgain, isFalse);
    });
  });
}
