import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:meta/meta.dart';

import '../types/conversation.dart';
import '../types/message.dart';

part 'database.g.dart';

@DataClassName('ConversationRow')
class Conversations extends Table {
  TextColumn get id => text()();

  TextColumn get localSystemPrompt => text().nullable()();

  TextColumn get title => text().withDefault(const Constant(''))();

  TextColumn get currentDir => text()();

  TextColumn get provider => text().nullable()();

  TextColumn get model => text().nullable()();

  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ConversationMessageRow')
class ConversationMessages extends Table {
  IntColumn get localId => integer().autoIncrement()();

  TextColumn get conversationId => text().references(Conversations, #id)();

  TextColumn get messageId => text()();

  IntColumn get sortOrder => integer()();

  TextColumn get messageType => text()();

  TextColumn get messageText => text()();

  TextColumn get toolName => text().nullable()();

  TextColumn get toolArgumentsJson => text().nullable()();

  TextColumn get result => text().nullable()();

  TextColumn get reasoning => text().nullable()();

  TextColumn get reasoningDetailsJson => text().nullable()();

  TextColumn get error => text().nullable()();

  TextColumn get attachedUrisJson => text().nullable()();

  TextColumn get model => text().nullable()();

  TextColumn get provider => text().nullable()();
}

@DataClassName('ConversationAttachmentRow')
class ConversationAttachments extends Table {
  TextColumn get conversationId => text().references(Conversations, #id)();

  TextColumn get uri => text()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, uri};
}

/// Generic on-device key/value store (schema v3). Holds runtime app config:
/// encrypted API secrets (OpenRouter / Tavily keys, base-URL override) and
/// plain preferences (voice locale, prompt-dismissed flags). Replaces the
/// former shared_preferences usage so everything lives in one SQLite file.
///
/// Values are opaque strings here — encryption is applied by the caller
/// ([AppSettingsService]/[SecretStore]), keeping this table dumb.
@DataClassName('AppSettingRow')
class AppSettings extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(
  tables: [Conversations, ConversationMessages, ConversationAttachments, AppSettings],
)
final class ErrandDatabase extends _$ErrandDatabase {
  ErrandDatabase._([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'errand'));

  static final ErrandDatabase instance = ErrandDatabase._();

  /// Creates an isolated in-memory database for tests.
  @visibleForTesting
  factory ErrandDatabase.inMemory() =>
      ErrandDatabase._(NativeDatabase.memory());

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createMessageIndexes(m);
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // v2 adds a UNIQUE index on (conversation_id, message_id). Pre-v2
        // databases may already contain duplicates (the merge-based save was
        // not transactional), so dedupe first — keep the oldest row.
        await customStatement('''
          DELETE FROM conversation_messages
          WHERE local_id NOT IN (
            SELECT MIN(local_id) FROM conversation_messages
            GROUP BY conversation_id, message_id
          )
        ''');
        await _createMessageIndexes(m);
      }
      if (from < 3) {
        // v3 adds the app-settings key/value store.
        await m.createTable(appSettings);
      }
      if (from < 4) {
        await m.addColumn(conversationMessages, conversationMessages.attachedUrisJson);
      }
      if (from < 5) {
        await m.addColumn(conversationMessages, conversationMessages.model);
        await m.addColumn(conversationMessages, conversationMessages.provider);
      }
    },
  );

  /// Indexes backing every message query in this file:
  /// - unique (conversation_id, message_id): makes the merge-based save
  ///   idempotent under overlapping saves and keeps `getSingleOrNull`
  ///   lookups (loadOlderMessages anchor, replaceMessage) safe;
  /// - (conversation_id, sort_order): windowed loads and sortOrder scans.
  Future<void> _createMessageIndexes(Migrator m) async {
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_conv_msg_unique '
      'ON conversation_messages (conversation_id, message_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_conv_msg_sort '
      'ON conversation_messages (conversation_id, sort_order)',
    );
  }

  // -- Writes -------------------------------------------------------------

  /// Persists a conversation together with its messages and attachments.
  ///
  /// Draft conversations (without an id) are not persisted.
  ///
  /// OPT-01: single upsert + bulk `batch` for children.
  ///
  /// OPT-07: the in-memory history may be a *window* (only the newest N
  /// messages loaded from disk). Messages are therefore merged by
  /// [ConversationMessages.messageId] instead of delete-all+reinsert, so
  /// rows outside the loaded window survive. New messages are appended
  /// after the current max sortOrder; known messages are updated in place,
  /// keeping their original position. Rows intentionally removed from
  /// memory (e.g. a failed working bubble) must be deleted explicitly via
  /// [deleteMessage].
  ///
  /// The whole merge runs inside a transaction and relies on the UNIQUE
  /// index over (conversation_id, message_id), so overlapping saves can
  /// never produce duplicate message rows.
  Future<void> saveConversation(Conversation conversation) async {
    final id = conversation.id;
    if (id == null) return;

    await transaction(() async {
      // Upsert the conversation row first (conflict on id).
      await into(conversations)
          .insertOnConflictUpdate(_conversationToRow(conversation));

      // The merge only needs identity + position of existing rows — not
      // their full payloads (tool results can be many KB each).
      final existingRows = await (selectOnly(conversationMessages)
            ..addColumns([
              conversationMessages.localId,
              conversationMessages.messageId,
              conversationMessages.sortOrder,
            ])
            ..where(conversationMessages.conversationId.equals(id)))
          .get();
      final rowByMessageId = <String, ({int localId, int sortOrder})>{
        for (final row in existingRows)
          row.read(conversationMessages.messageId)! : (
            localId: row.read(conversationMessages.localId)!,
            sortOrder: row.read(conversationMessages.sortOrder)!,
          ),
      };
      var nextSortOrder = rowByMessageId.values.fold<int>(
        -1,
        (maxSoFar, row) => math.max(maxSoFar, row.sortOrder),
      );

      await batch((b) {
        for (final message in conversation.messages) {
          final existingRow = rowByMessageId[message.id];
          if (existingRow == null) {
            nextSortOrder += 1;
            b.insert(
              conversationMessages,
              _messageCompanion(id, nextSortOrder, message),
            );
          } else {
            b.update(
              conversationMessages,
              _messageCompanion(id, existingRow.sortOrder, message),
              where: (tbl) => tbl.localId.equals(existingRow.localId),
            );
          }
        }
      });

      // Attachments are small and fully derived from the composer state;
      // rewriting them stays correct.
      final attachmentCompanions = <ConversationAttachmentsCompanion>[
        for (final uri in conversation.attachedFileUris)
          ConversationAttachmentsCompanion.insert(conversationId: id, uri: uri),
      ];
      await batch((b) {
        b.deleteWhere(
          conversationAttachments,
          (a) => a.conversationId.equals(id),
        );
        if (attachmentCompanions.isNotEmpty) {
          b.insertAll(conversationAttachments, attachmentCompanions);
        }
      });
    });
  }

  /// Completely replaces stored messages of [conversationId] with [messages] in
  /// exact sequential sortOrder (0, 1, 2, ...).
  ///
  /// WINDOW-SAFETY CONTRACT: [messages] must be the conversation's COMPLETE
  /// history — never a loaded window subset. Anything absent is permanently
  /// deleted. Prefer [saveConversation] (merge by messageId) whenever older
  /// pages may be unloaded; reserve this for explicit purges with proven
  /// completeness.
  ///
  /// Currently uncalled: compaction persists its divider via [saveConversation]
  /// merge and retains pre-divider rows as an audit trail (never re-sent
  /// thanks to the effective-history slice). Kept for a future explicit
  /// DB-hygiene pass.
  Future<void> replaceAllMessages(String conversationId, List<Message> messages) async {
    await transaction(() async {
      await (delete(conversationMessages)
            ..where((m) => m.conversationId.equals(conversationId)))
          .go();
      await batch((b) {
        for (var i = 0; i < messages.length; i++) {
          b.insert(
            conversationMessages,
            _messageCompanion(conversationId, i, messages[i]),
          );
        }
      });
    });
  }

  /// Deletes a conversation together with its messages and attachments.
  Future<void> deleteConversation(String id) async {
    await transaction(() async {
      await (delete(
        conversationMessages,
      )..where((message) => message.conversationId.equals(id))).go();
      await (delete(
        conversationAttachments,
      )..where((attachment) => attachment.conversationId.equals(id))).go();
      await (delete(conversations)..where((c) => c.id.equals(id))).go();
    });
  }

  /// Bumps [Conversation.updatedAt] for the given conversation so it floats
  /// to the top of the recency-ordered list.
  Future<void> touchConversation(String id) async {
    await (update(conversations)..where((c) => c.id.equals(id))).write(
      ConversationsCompanion(updatedAt: Value(DateTime.now())),
    );
  }

  // -- App settings (key/value) ---------------------------------------------

  /// Reads a settings value; null when the key is absent.
  Future<String?> getSetting(String key) async {
    final row = await (select(
      appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// Inserts or overwrites a settings value.
  Future<void> setSetting(String key, String value) async {
    await into(appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: key, value: value),
    );
  }

  /// Removes a settings key. No-op when absent.
  Future<void> deleteSetting(String key) async {
    await (delete(appSettings)..where((s) => s.key.equals(key))).go();
  }


  // -- Message CRUD --------------------------------------------------------

  /// Loads the messages of a conversation, in stored order.
  Future<List<Message>> loadMessages(String conversationId) {
    return _loadMessages(conversationId);
  }

  /// Appends [message] to the conversation; inserts a fresh row even if a
  /// message with the same id already exists.
  Future<void> insertMessage(String conversationId, Message message) async {
    final maxId = conversationMessages.sortOrder.max();
    final query = selectOnly(conversationMessages)
      ..addColumns([maxId])
      ..where(conversationMessages.conversationId.equals(conversationId));
    final row = await query.getSingle();

    final nextSortOrder = (row.read(maxId) ?? -1) + 1;
    await into(conversationMessages)
        .insert(_messageCompanion(conversationId, nextSortOrder, message));
  }

  /// Replaces the stored message identified by [messageId] with [message],
  /// keeping its position. If no such message exists, it is appended.
  Future<void> replaceMessage(
    String conversationId,
    String messageId,
    Message message,
  ) async {
    final existing =
        await (select(conversationMessages)..where(
              (m) =>
                  m.conversationId.equals(conversationId) &
                  m.messageId.equals(messageId),
            ))
            .getSingleOrNull();
    if (existing == null) {
      await insertMessage(conversationId, message);
      return;
    }
    await (update(conversationMessages)
          ..where((m) => m.localId.equals(existing.localId)))
        .write(_messageCompanion(conversationId, existing.sortOrder, message));
  }

  /// Removes a single message from a conversation.
  Future<void> deleteMessage(String conversationId, String messageId) async {
    await (delete(conversationMessages)..where(
          (m) =>
              m.conversationId.equals(conversationId) &
              m.messageId.equals(messageId),
        ))
        .go();
  }

  // -- Reads --------------------------------------------------------------

  /// Loads a single conversation summary (no messages, no attachments).
  /// Used to refresh one sidebar row without hydrating its history.
  Future<Conversation?> loadConversationSummary(String id) async {
    final row = await (select(
      conversations,
    )..where((conversation) => conversation.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _rowToConversation(row, const [], const []);
  }

  /// Loads a single conversation with all of its messages and attachments.
  ///
  /// With [messageLimit], only the newest [messageLimit] messages are
  /// loaded (still in chronological order) — the window for OPT-07
  /// history windowing. Older pages are fetched via [loadOlderMessages].
  Future<Conversation?> loadConversation(String id, {int? messageLimit}) async {
    final row = await (select(
      conversations,
    )..where((conversation) => conversation.id.equals(id))).getSingleOrNull();
    if (row == null) return null;

    return _rowToConversation(
      row,
      await _loadMessages(id, limit: messageLimit),
      await _loadAttachmentUris(id),
    );
  }

  /// Loads up to [limit] messages strictly older than [beforeMessageId],
  /// in chronological order. Returns an empty list when [beforeMessageId]
  /// is unknown or nothing older exists.
  Future<List<Message>> loadOlderMessages(
    String conversationId, {
    required String beforeMessageId,
    required int limit,
  }) async {
    final anchor =
        await (select(conversationMessages)..where(
              (m) =>
                  m.conversationId.equals(conversationId) &
                  m.messageId.equals(beforeMessageId),
            ))
            .getSingleOrNull();
    if (anchor == null) return const [];

    final query = select(conversationMessages)
      ..where(
        (m) =>
            m.conversationId.equals(conversationId) &
            m.sortOrder.isSmallerThanValue(anchor.sortOrder),
      )
      ..orderBy([(m) => OrderingTerm.desc(m.sortOrder)])
      ..limit(limit);

    final rows = await query.get();
    return [for (final row in rows.reversed) _rowToMessage(row)];
  }

  Future<void> pinConversation(String id) async {
    // Single-statement toggle: no read-modify-write race between the two
    // queries, and no need for a transaction.
    await customStatement(
      'UPDATE conversations SET is_pinned = NOT is_pinned WHERE id = ?',
      [id],
    );
    // Raw SQL bypasses drift's table-update tracking, so the sidebar watch
    // streams would never re-run without this explicit notification.
    markTablesUpdated([conversations]);
  }

  /// Renames a conversation. Sidebar rows update via the existing watch
  /// streams; already-loaded older pages are refreshed by the caller.
  Future<void> renameConversation(String id, String title) async {
    await (update(conversations)..where((c) => c.id.equals(id))).write(
      ConversationsCompanion(title: Value(title)),
    );
  }

  /// Deterministic sidebar ordering: (updatedAt desc, id desc). The id
  /// tiebreaker makes the order total, so cursor-based pages line up with
  /// the watched first page even when updatedAt values collide.
  List<OrderClauseGenerator<$ConversationsTable>> _summaryOrdering() => [
    (c) => OrderingTerm.desc(c.updatedAt),
    (c) => OrderingTerm.desc(c.id),
  ];

  /// Emits the sorted conversation list (without message bodies) whenever
  /// the conversation table changes. Suitable for driving a sidebar.
  ///
  /// With [limit], only the [limit] most recently updated conversations are
  /// emitted — page one of the OPT-07 sidebar pagination. Older pages are
  /// fetched on demand via [loadOlderConversations].
  Stream<List<Conversation>> watchConversationSummaries({int? limit}) {
    final query = select(conversations)..orderBy(_summaryOrdering());
    if (limit != null) query.limit(limit);
    return query.watch().map(
      (rows) => [
        for (final row in rows) _rowToConversation(row, const [], const []),
      ],
    );
  }

  /// Loads up to [limit] conversation summaries strictly older than the
  /// (updatedAt, id) cursor — the next page after the watched first page.
  ///
  /// Cursor-based instead of offset-based on purpose: an offset computed
  /// from what the UI shows drifts whenever a conversation is created or
  /// touched mid-session (the watched page shifts, skipping or duplicating
  /// a row). A strict tuple comparison cannot skip rows.
  Future<List<Conversation>> loadOlderConversations({
    required DateTime beforeUpdatedAt,
    required String beforeId,
    required int limit,
  }) async {
    final query = select(conversations)
      ..where(
        (c) =>
            c.updatedAt.isSmallerThanValue(beforeUpdatedAt) |
            (c.updatedAt.equals(beforeUpdatedAt) &
                c.id.isSmallerThanValue(beforeId)),
      )
      ..orderBy(_summaryOrdering())
      ..limit(limit);
    final rows = await query.get();
    return [
      for (final row in rows) _rowToConversation(row, const [], const []),
    ];
  }

  Stream<List<Conversation>> watchPinnedConversations() {
    final query = select(conversations)
      ..where((conversation) => conversation.isPinned.equals(true))
      ..orderBy(_summaryOrdering());
    return query.watch().map(
      (rows) => [
        for (final row in rows) _rowToConversation(row, const [], const []),
      ],
    );
  }

  Future<List<Message>> _loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    final query = select(conversationMessages)
      ..where((message) => message.conversationId.equals(conversationId));

    if (limit != null) {
      query
        ..orderBy([
          (message) => OrderingTerm.desc(message.sortOrder),
        ])
        ..limit(limit);
    } else {
      query.orderBy([
        (message) => OrderingTerm.asc(message.sortOrder),
      ]);
    }

    final rows = await query.get();

    final orderedRows = limit != null
        ? rows.reversed.toList()
        : rows;

    return [for (final row in orderedRows) _rowToMessage(row)];
  }

  Future<List<String>> _loadAttachmentUris(String conversationId) async {
    final rows =
        await (select(conversationAttachments)..where(
              (attachment) => attachment.conversationId.equals(conversationId),
            ))
            .get();
    return [for (final row in rows) row.uri];
  }

  // -- Mapping ------------------------------------------------------------

  ConversationRow _conversationToRow(Conversation conversation) {
    return ConversationRow(
      id: conversation.id!,
      localSystemPrompt: conversation.localSystemPrompt,
      title: conversation.title,
      currentDir: conversation.currentDir.path,
      provider: conversation.provider,
      model: conversation.model,
      isPinned: conversation.isPinned,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
    );
  }

  Conversation _rowToConversation(
    ConversationRow row,
    List<Message> messages,
    List<String> attachedFileUris,
  ) {
    return Conversation(
      id: row.id,
      localSystemPrompt: row.localSystemPrompt,
      messages: messages,
      currentDir: Directory(row.currentDir),
      attachedFileUris: attachedFileUris,
      title: row.title,
      provider: row.provider,
      model: row.model,
      isPinned: row.isPinned,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  ConversationMessagesCompanion _messageCompanion(
    String conversationId,
    int sortOrder,
    Message message,
  ) {
    return ConversationMessagesCompanion.insert(
      conversationId: conversationId,
      messageId: message.id,
      sortOrder: sortOrder,
      messageType: _messageTypeOf(message),
      messageText: message.text,
      toolName: Value(message is ToolMessage ? message.tool.name : null),
      toolArgumentsJson: Value(
        message is ToolMessage ? jsonEncode(message.tool.args) : null,
      ),
      result: Value(
        message is ToolMessage
            ? message.result
            : message is CompactedNoticeMessage
                ? message.summary
                : null,
      ),
      reasoning: Value(message is ToolMessage ? message.reasoning : null),
      reasoningDetailsJson: Value(
        message is ToolMessage && message.reasoningDetails.isNotEmpty
            ? jsonEncode(message.reasoningDetails)
            : null,
      ),
      error: Value(message is ErrorMessage ? message.error : null),
      attachedUrisJson: Value(
        message is UserMessage && message.attachedUris.isNotEmpty
            ? jsonEncode(message.attachedUris)
            : null,
      ),
      model: Value(message is AssistantMessage ? message.model : null),
      provider: Value(message is AssistantMessage ? message.provider : null),
    );
  }

  Message _rowToMessage(ConversationMessageRow row) {
    switch (row.messageType) {
      case _userType:
        return UserMessage(
          id: row.messageId,
          text: row.messageText,
          attachedUris: _decodeStringList(row.attachedUrisJson),
        );
      case _assistantType:
        return AssistantMessage(
          id: row.messageId,
          text: row.messageText,
          model: row.model,
          provider: row.provider,
        );
      case _toolType:
        return ToolMessage(
          id: row.messageId,
          text: row.messageText,
          tool: ToolInvocation(
            name: row.toolName ?? '',
            args: _decodeObject(row.toolArgumentsJson) ?? const {},
          ),
          result: row.result ?? '',
          reasoning: row.reasoning,
          reasoningDetails: _decodeList(row.reasoningDetailsJson),
        );
      case _errorType:
        return ErrorMessage(
          id: row.messageId,
          text: row.messageText,
          error: row.error ?? row.messageText,
        );
      case _compactedType:
        return CompactedNoticeMessage(
          id: row.messageId,
          text: row.messageText,
          summary: row.result ?? '',
        );
      default:
        throw FormatException('Unknown message type "${row.messageType}".');
    }
  }

  String _messageTypeOf(Message message) => switch (message) {
    UserMessage() => _userType,
    AssistantMessage() => _assistantType,
    ToolMessage() => _toolType,
    ErrorMessage() => _errorType,
    CompactedNoticeMessage() => _compactedType,
  };

  static List<String> _decodeStringList(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } on FormatException {
      return const [];
    }
  }

  static Map<String, dynamic>? _decodeObject(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static List<Map<String, dynamic>> _decodeList(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded.whereType<Map<String, dynamic>>().toList();
    } on FormatException {
      return const [];
    }
  }
}

const _userType = 'user';
const _assistantType = 'assistant';
const _toolType = 'tool';
const _errorType = 'error';
const _compactedType = 'compacted';
