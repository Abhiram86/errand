import 'dart:convert';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../services/database.dart';
import '../types/memory.dart';

/// Service managing persistent, structured user memories across conversations.
///
/// Implements lexical/token-based approximate matching, strict validation rules,
/// and complete CRUD operations. Does not use embeddings, RAG, or vector DBs.
class MemoryService {
  final ErrandDatabase? _dbOverride;
  final Uuid _uuid;

  MemoryService({ErrandDatabase? db, Uuid? uuid})
      : _dbOverride = db,
        _uuid = uuid ?? const Uuid();

  ErrandDatabase get _db => _dbOverride ?? ErrandDatabase.instance;

  static final MemoryService instance = MemoryService();

  /// Converts a [MemoryRow] from the database into a domain [UserMemory].
  UserMemory _rowToMemory(MemoryRow row) {
    List<String> keywords = const [];
    if (row.keywords.isNotEmpty) {
      try {
        final decoded = jsonDecode(row.keywords);
        if (decoded is List) {
          keywords = decoded.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
        }
      } catch (_) {}
    }
    return UserMemory(
      id: row.id,
      about: row.about,
      description: row.description,
      keywords: keywords,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      sourceConversationId: row.sourceConversationId,
    );
  }

  /// Finds potentially relevant memories using lexical and token-based approximate scoring.
  ///
  /// Matches approximately against `about`, `keywords`, and `description`.
  /// Supports optional timestamp filtering.
  /// Returns ONLY the top [k] candidate memories (default 3), containing only `id` and `about`.
  Future<List<MemoryFindResult>> find({
    String? query,
    String? timestamp,
    int k = 3,
  }) async {
    final effectiveK = math.max(1, math.min(k, 50));
    final rows = await _db.loadAllMemories();
    if (rows.isEmpty) return const [];

    final memories = rows.map(_rowToMemory).toList();

    // 1. Timestamp filtering if provided
    final filtered = <UserMemory>[];
    for (final memory in memories) {
      if (timestamp != null && timestamp.trim().isNotEmpty) {
        if (!_matchesTimestamp(memory.createdAt, memory.updatedAt, timestamp.trim())) {
          continue;
        }
      }
      filtered.add(memory);
    }

    if (filtered.isEmpty) return const [];

    // 2. Lexical / token-based scoring
    final trimmedQuery = query?.trim().toLowerCase();
    if (trimmedQuery == null || trimmedQuery.isEmpty) {
      // No query: return top k ordered by recency
      return filtered
          .take(effectiveK)
          .map((m) => MemoryFindResult(id: m.id, about: m.about))
          .toList();
    }

    final queryTokens = _tokenize(trimmedQuery);
    final scored = <({UserMemory memory, double score})>[];

    for (final memory in filtered) {
      final score = _scoreMemory(memory, trimmedQuery, queryTokens);
      if (score > 0) {
        // Recency tie-breaker
        final recencyBoost = memory.updatedAt.millisecondsSinceEpoch / 1e16;
        scored.add((memory: memory, score: score + recencyBoost));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored
        .take(effectiveK)
        .map((entry) => MemoryFindResult(id: entry.memory.id, about: entry.memory.about))
        .toList();
  }

  /// Retrieves a single complete memory by its ID.
  Future<UserMemory?> read(String id) async {
    final trimmedId = id.trim();
    if (trimmedId.isEmpty) return null;
    final row = await _db.getMemoryById(trimmedId);
    if (row == null) return null;
    return _rowToMemory(row);
  }

  /// Creates and saves a new structured user memory.
  ///
  /// Validates:
  /// - `about` and `description` are non-empty.
  /// - `keywords` length <= 10.
  /// - Keywords are short generic concepts, not sentences.
  /// Sets `createdAt` and `updatedAt` automatically.
  Future<UserMemory> create({
    required String about,
    required String description,
    required List<String> keywords,
    String? sourceConversationId,
  }) async {
    final trimmedAbout = about.trim();
    if (trimmedAbout.isEmpty) {
      throw ArgumentError('The "about" field is required and cannot be empty.');
    }

    final trimmedDesc = description.trim();
    if (trimmedDesc.isEmpty) {
      throw ArgumentError('The "description" field is required and cannot be empty.');
    }

    final validatedKeywords = _validateKeywords(keywords);

    final id = 'mem_${_uuid.v4().replaceAll('-', '').substring(0, 12)}';
    final now = DateTime.fromMillisecondsSinceEpoch(
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000,
    );

    final memory = UserMemory(
      id: id,
      about: trimmedAbout,
      description: trimmedDesc,
      keywords: validatedKeywords,
      createdAt: now,
      updatedAt: now,
      sourceConversationId: sourceConversationId?.trim(),
    );

    await _db.insertMemoryRow(
      MemoryRow(
        id: memory.id,
        about: memory.about,
        description: memory.description,
        keywords: jsonEncode(memory.keywords),
        createdAt: memory.createdAt,
        updatedAt: memory.updatedAt,
        sourceConversationId: memory.sourceConversationId,
      ),
    );

    return memory;
  }

  /// Edits an existing memory by its ID.
  ///
  /// Rules:
  /// - `id` required.
  /// - At least ONE of `about`, `description`, or `keywords` must be provided.
  /// - Only provided fields are updated; null/omitted fields remain unchanged.
  /// - Updates `updatedAt` automatically; `createdAt` is never modified.
  /// - Throws if the ID does not exist (never silently creates).
  Future<UserMemory> edit({
    required String id,
    String? about,
    String? description,
    List<String>? keywords,
  }) async {
    final trimmedId = id.trim();
    if (trimmedId.isEmpty) {
      throw ArgumentError('The "id" field is required to edit memory.');
    }

    final existingRow = await _db.getMemoryById(trimmedId);
    if (existingRow == null) {
      throw ArgumentError('Memory with id "$trimmedId" not found.');
    }

    if (about == null && description == null && keywords == null) {
      throw ArgumentError(
        'At least one of about, description, or keywords must be provided to edit memory.',
      );
    }

    String updatedAbout = existingRow.about;
    if (about != null) {
      final trimmedAbout = about.trim();
      if (trimmedAbout.isEmpty) {
        throw ArgumentError('The "about" field cannot be empty when editing.');
      }
      updatedAbout = trimmedAbout;
    }

    String updatedDesc = existingRow.description;
    if (description != null) {
      final trimmedDesc = description.trim();
      if (trimmedDesc.isEmpty) {
        throw ArgumentError('The "description" field cannot be empty when editing.');
      }
      updatedDesc = trimmedDesc;
    }

    List<String> updatedKeywords;
    if (keywords != null) {
      updatedKeywords = _validateKeywords(keywords);
    } else {
      updatedKeywords = _rowToMemory(existingRow).keywords;
    }

    final now = DateTime.fromMillisecondsSinceEpoch(
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000,
    );
    final updatedMemory = UserMemory(
      id: existingRow.id,
      about: updatedAbout,
      description: updatedDesc,
      keywords: updatedKeywords,
      createdAt: existingRow.createdAt,
      updatedAt: now,
      sourceConversationId: existingRow.sourceConversationId,
    );

    await _db.updateMemoryRow(
      MemoryRow(
        id: updatedMemory.id,
        about: updatedMemory.about,
        description: updatedMemory.description,
        keywords: jsonEncode(updatedMemory.keywords),
        createdAt: updatedMemory.createdAt,
        updatedAt: updatedMemory.updatedAt,
        sourceConversationId: updatedMemory.sourceConversationId,
      ),
    );

    return updatedMemory;
  }

  /// Deletes a memory by its ID. Returns true if removed, false if not found.
  Future<bool> delete(String id) async {
    final trimmedId = id.trim();
    if (trimmedId.isEmpty) return false;
    final rowsAffected = await _db.deleteMemoryRow(trimmedId);
    return rowsAffected > 0;
  }

  /// Loads all stored memories ordered by updated recency.
  Future<List<UserMemory>> getAll() async {
    final rows = await _db.loadAllMemories();
    return rows.map(_rowToMemory).toList();
  }

  // -- Validation Helpers ---------------------------------------------------

  static List<String> _validateKeywords(List<dynamic> rawKeywords) {
    if (rawKeywords.length > 10) {
      throw ArgumentError(
        'Keywords list exceeds maximum of 10 items (got ${rawKeywords.length}).',
      );
    }

    final cleaned = <String>[];
    for (final item in rawKeywords) {
      final kw = item.toString().trim();
      if (kw.isEmpty) continue;

      if (kw.length > 40) {
        throw ArgumentError(
          'Keyword "$kw" exceeds maximum length of 40 characters. '
          'Keywords should be short generic concepts.',
        );
      }

      if (kw.contains(RegExp(r'[\.\!\?\n]'))) {
        throw ArgumentError(
          'Keyword "$kw" looks like a sentence. '
          'Keywords should be short generic concepts, not sentences (e.g. "dark_mode", "python").',
        );
      }

      final wordCount = kw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      if (wordCount > 4) {
        throw ArgumentError(
          'Keyword "$kw" contains too many words ($wordCount). '
          'Keywords should be short generic concepts (maximum 4 words).',
        );
      }

      cleaned.add(kw);
    }

    return cleaned;
  }

  // -- Token-based scoring & fuzzy matching ---------------------------------

  static List<String> _tokenize(String text) {
    return RegExp(r'[a-z0-9]+')
        .allMatches(text.toLowerCase())
        .map((m) => m.group(0)!)
        .where((t) => t.isNotEmpty)
        .toList();
  }

  static double _scoreMemory(
    UserMemory memory,
    String normalizedQuery,
    List<String> queryTokens,
  ) {
    double score = 0.0;
    final aboutLower = memory.about.toLowerCase();
    final descLower = memory.description.toLowerCase();
    final keywordsLower = memory.keywords.map((k) => k.toLowerCase()).toList();

    // Full query substring match bonuses
    if (aboutLower.contains(normalizedQuery)) {
      score += 10.0;
    }
    if (descLower.contains(normalizedQuery)) {
      score += 5.0;
    }

    final aboutWords = _tokenize(aboutLower);
    final descWords = _tokenize(descLower);

    for (final q in queryTokens) {
      // 1. Check against about (highest weight)
      if (aboutWords.contains(q)) {
        score += 4.0;
      } else if (aboutLower.contains(q)) {
        score += 2.0;
      } else {
        // Approximate / fuzzy match on about words
        for (final w in aboutWords) {
          if (w.length >= 4 && q.length >= 4 && _levenshtein(q, w) <= 1) {
            score += 2.0;
            break;
          }
        }
      }

      // 2. Check against keywords (high weight)
      for (final kw in keywordsLower) {
        final kwWords = _tokenize(kw);
        if (kw == q || kwWords.contains(q)) {
          score += 5.0;
        } else if (kw.contains(q) || q.contains(kw)) {
          score += 3.0;
        } else if (kw.length >= 4 && q.length >= 4 && _levenshtein(q, kw) <= 1) {
          score += 2.5;
        }
      }

      // 3. Check against description (contextual weight)
      if (descWords.contains(q)) {
        score += 2.0;
      } else if (descLower.contains(q)) {
        score += 1.0;
      } else {
        // Substring / prefix check
        for (final dw in descWords) {
          if (dw.startsWith(q) || q.startsWith(dw)) {
            score += 0.8;
            break;
          }
        }
      }
    }

    return score;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if ((a.length - b.length).abs() > 2) return 999;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    List<int> curr = List.filled(b.length + 1, 0);

    for (int i = 0; i < a.length; i++) {
      curr[0] = i + 1;
      for (int j = 0; j < b.length; j++) {
        int cost = a[i] == b[j] ? 0 : 1;
        curr[j + 1] = math.min(
          curr[j] + 1,
          math.min(prev[j + 1] + 1, prev[j] + cost),
        );
      }
      prev.setAll(0, curr);
    }
    return curr[b.length];
  }

  // -- Timestamp filtering helper -------------------------------------------

  static bool _matchesTimestamp(
    DateTime createdAt,
    DateTime updatedAt,
    String filter,
  ) {
    final trimmed = filter.trim();
    final lower = trimmed.toLowerCase();

    // Range: start..end
    if (lower.contains('..')) {
      final parts = trimmed.split('..');
      if (parts.length == 2) {
        final start = DateTime.tryParse(parts[0].trim());
        final end = DateTime.tryParse(parts[1].trim());
        if (start != null && end != null) {
          final startEpoch = start.millisecondsSinceEpoch;
          final endEpoch = end.millisecondsSinceEpoch;
          final cEpoch = createdAt.millisecondsSinceEpoch;
          final uEpoch = updatedAt.millisecondsSinceEpoch;
          return (cEpoch >= startEpoch && cEpoch <= endEpoch) ||
              (uEpoch >= startEpoch && uEpoch <= endEpoch);
        }
      }
    }

    // After / since / >= / >
    if (lower.startsWith('after:') ||
        lower.startsWith('since:') ||
        lower.startsWith('>=') ||
        lower.startsWith('>')) {
      final raw = trimmed
          .replaceFirst(RegExp(r'^(after:|since:|>=|>)', caseSensitive: false), '')
          .trim();
      final dt = DateTime.tryParse(raw);
      if (dt != null) {
        final dtEpoch = dt.millisecondsSinceEpoch;
        return createdAt.millisecondsSinceEpoch >= dtEpoch ||
            updatedAt.millisecondsSinceEpoch >= dtEpoch;
      }
      return false;
    }

    // Before / <= / <
    if (lower.startsWith('before:') ||
        lower.startsWith('<=') ||
        lower.startsWith('<')) {
      final raw = trimmed
          .replaceFirst(RegExp(r'^(before:|<=|<)', caseSensitive: false), '')
          .trim();
      final dt = DateTime.tryParse(raw);
      if (dt != null) {
        final dtEpoch = dt.millisecondsSinceEpoch;
        return createdAt.millisecondsSinceEpoch <= dtEpoch ||
            updatedAt.millisecondsSinceEpoch <= dtEpoch;
      }
      return false;
    }

    // Exact or prefix date matching (e.g. "2026-09-14")
    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) {
      if (trimmed.length == 10) {
        // Date only (YYYY-MM-DD): match anything within that day
        final dayStart = DateTime(parsed.year, parsed.month, parsed.day);
        final dayEnd = dayStart.add(const Duration(days: 1));
        final startEpoch = dayStart.millisecondsSinceEpoch;
        final endEpoch = dayEnd.millisecondsSinceEpoch;
        final cEpoch = createdAt.millisecondsSinceEpoch;
        final uEpoch = updatedAt.millisecondsSinceEpoch;
        return (cEpoch >= startEpoch && cEpoch < endEpoch) ||
            (uEpoch >= startEpoch && uEpoch < endEpoch);
      }
      final parsedEpoch = parsed.millisecondsSinceEpoch;
      return createdAt.millisecondsSinceEpoch == parsedEpoch ||
          updatedAt.millisecondsSinceEpoch == parsedEpoch;
    }

    // Unrecognized timestamp format: pass through rather than filter out
    return true;
  }
}
