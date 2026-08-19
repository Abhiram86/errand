import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

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
}

class ConversationAttachments extends Table {
  TextColumn get conversationId => text().references(Conversations, #id)();

  TextColumn get uri => text()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, uri};
}

@DriftDatabase(
  tables: [Conversations, ConversationMessages, ConversationAttachments],
)
final class HandyDatabase extends _$HandyDatabase {
  HandyDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'handy'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
  );
}
