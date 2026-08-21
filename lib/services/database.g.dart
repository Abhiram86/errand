// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, ConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localSystemPromptMeta = const VerificationMeta(
    'localSystemPrompt',
  );
  @override
  late final GeneratedColumn<String> localSystemPrompt =
      GeneratedColumn<String>(
        'local_system_prompt',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _currentDirMeta = const VerificationMeta(
    'currentDir',
  );
  @override
  late final GeneratedColumn<String> currentDir = GeneratedColumn<String>(
    'current_dir',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _providerMeta = const VerificationMeta(
    'provider',
  );
  @override
  late final GeneratedColumn<String> provider = GeneratedColumn<String>(
    'provider',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isPinnedMeta = const VerificationMeta(
    'isPinned',
  );
  @override
  late final GeneratedColumn<bool> isPinned = GeneratedColumn<bool>(
    'is_pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    localSystemPrompt,
    title,
    currentDir,
    provider,
    model,
    isPinned,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('local_system_prompt')) {
      context.handle(
        _localSystemPromptMeta,
        localSystemPrompt.isAcceptableOrUnknown(
          data['local_system_prompt']!,
          _localSystemPromptMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('current_dir')) {
      context.handle(
        _currentDirMeta,
        currentDir.isAcceptableOrUnknown(data['current_dir']!, _currentDirMeta),
      );
    } else if (isInserting) {
      context.missing(_currentDirMeta);
    }
    if (data.containsKey('provider')) {
      context.handle(
        _providerMeta,
        provider.isAcceptableOrUnknown(data['provider']!, _providerMeta),
      );
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    }
    if (data.containsKey('is_pinned')) {
      context.handle(
        _isPinnedMeta,
        isPinned.isAcceptableOrUnknown(data['is_pinned']!, _isPinnedMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      localSystemPrompt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_system_prompt'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      currentDir: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}current_dir'],
      )!,
      provider: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}provider'],
      ),
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      ),
      isPinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_pinned'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class ConversationRow extends DataClass implements Insertable<ConversationRow> {
  final String id;
  final String? localSystemPrompt;
  final String title;
  final String currentDir;
  final String? provider;
  final String? model;
  final bool isPinned;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ConversationRow({
    required this.id,
    this.localSystemPrompt,
    required this.title,
    required this.currentDir,
    this.provider,
    this.model,
    required this.isPinned,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || localSystemPrompt != null) {
      map['local_system_prompt'] = Variable<String>(localSystemPrompt);
    }
    map['title'] = Variable<String>(title);
    map['current_dir'] = Variable<String>(currentDir);
    if (!nullToAbsent || provider != null) {
      map['provider'] = Variable<String>(provider);
    }
    if (!nullToAbsent || model != null) {
      map['model'] = Variable<String>(model);
    }
    map['is_pinned'] = Variable<bool>(isPinned);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      localSystemPrompt: localSystemPrompt == null && nullToAbsent
          ? const Value.absent()
          : Value(localSystemPrompt),
      title: Value(title),
      currentDir: Value(currentDir),
      provider: provider == null && nullToAbsent
          ? const Value.absent()
          : Value(provider),
      model: model == null && nullToAbsent
          ? const Value.absent()
          : Value(model),
      isPinned: Value(isPinned),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ConversationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationRow(
      id: serializer.fromJson<String>(json['id']),
      localSystemPrompt: serializer.fromJson<String?>(
        json['localSystemPrompt'],
      ),
      title: serializer.fromJson<String>(json['title']),
      currentDir: serializer.fromJson<String>(json['currentDir']),
      provider: serializer.fromJson<String?>(json['provider']),
      model: serializer.fromJson<String?>(json['model']),
      isPinned: serializer.fromJson<bool>(json['isPinned']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'localSystemPrompt': serializer.toJson<String?>(localSystemPrompt),
      'title': serializer.toJson<String>(title),
      'currentDir': serializer.toJson<String>(currentDir),
      'provider': serializer.toJson<String?>(provider),
      'model': serializer.toJson<String?>(model),
      'isPinned': serializer.toJson<bool>(isPinned),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ConversationRow copyWith({
    String? id,
    Value<String?> localSystemPrompt = const Value.absent(),
    String? title,
    String? currentDir,
    Value<String?> provider = const Value.absent(),
    Value<String?> model = const Value.absent(),
    bool? isPinned,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ConversationRow(
    id: id ?? this.id,
    localSystemPrompt: localSystemPrompt.present
        ? localSystemPrompt.value
        : this.localSystemPrompt,
    title: title ?? this.title,
    currentDir: currentDir ?? this.currentDir,
    provider: provider.present ? provider.value : this.provider,
    model: model.present ? model.value : this.model,
    isPinned: isPinned ?? this.isPinned,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ConversationRow copyWithCompanion(ConversationsCompanion data) {
    return ConversationRow(
      id: data.id.present ? data.id.value : this.id,
      localSystemPrompt: data.localSystemPrompt.present
          ? data.localSystemPrompt.value
          : this.localSystemPrompt,
      title: data.title.present ? data.title.value : this.title,
      currentDir: data.currentDir.present
          ? data.currentDir.value
          : this.currentDir,
      provider: data.provider.present ? data.provider.value : this.provider,
      model: data.model.present ? data.model.value : this.model,
      isPinned: data.isPinned.present ? data.isPinned.value : this.isPinned,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRow(')
          ..write('id: $id, ')
          ..write('localSystemPrompt: $localSystemPrompt, ')
          ..write('title: $title, ')
          ..write('currentDir: $currentDir, ')
          ..write('provider: $provider, ')
          ..write('model: $model, ')
          ..write('isPinned: $isPinned, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    localSystemPrompt,
    title,
    currentDir,
    provider,
    model,
    isPinned,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationRow &&
          other.id == this.id &&
          other.localSystemPrompt == this.localSystemPrompt &&
          other.title == this.title &&
          other.currentDir == this.currentDir &&
          other.provider == this.provider &&
          other.model == this.model &&
          other.isPinned == this.isPinned &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConversationsCompanion extends UpdateCompanion<ConversationRow> {
  final Value<String> id;
  final Value<String?> localSystemPrompt;
  final Value<String> title;
  final Value<String> currentDir;
  final Value<String?> provider;
  final Value<String?> model;
  final Value<bool> isPinned;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.localSystemPrompt = const Value.absent(),
    this.title = const Value.absent(),
    this.currentDir = const Value.absent(),
    this.provider = const Value.absent(),
    this.model = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    this.localSystemPrompt = const Value.absent(),
    this.title = const Value.absent(),
    required String currentDir,
    this.provider = const Value.absent(),
    this.model = const Value.absent(),
    this.isPinned = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       currentDir = Value(currentDir),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ConversationRow> custom({
    Expression<String>? id,
    Expression<String>? localSystemPrompt,
    Expression<String>? title,
    Expression<String>? currentDir,
    Expression<String>? provider,
    Expression<String>? model,
    Expression<bool>? isPinned,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (localSystemPrompt != null) 'local_system_prompt': localSystemPrompt,
      if (title != null) 'title': title,
      if (currentDir != null) 'current_dir': currentDir,
      if (provider != null) 'provider': provider,
      if (model != null) 'model': model,
      if (isPinned != null) 'is_pinned': isPinned,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String?>? localSystemPrompt,
    Value<String>? title,
    Value<String>? currentDir,
    Value<String?>? provider,
    Value<String?>? model,
    Value<bool>? isPinned,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      localSystemPrompt: localSystemPrompt ?? this.localSystemPrompt,
      title: title ?? this.title,
      currentDir: currentDir ?? this.currentDir,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      isPinned: isPinned ?? this.isPinned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (localSystemPrompt.present) {
      map['local_system_prompt'] = Variable<String>(localSystemPrompt.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (currentDir.present) {
      map['current_dir'] = Variable<String>(currentDir.value);
    }
    if (provider.present) {
      map['provider'] = Variable<String>(provider.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (isPinned.present) {
      map['is_pinned'] = Variable<bool>(isPinned.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('localSystemPrompt: $localSystemPrompt, ')
          ..write('title: $title, ')
          ..write('currentDir: $currentDir, ')
          ..write('provider: $provider, ')
          ..write('model: $model, ')
          ..write('isPinned: $isPinned, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationMessagesTable extends ConversationMessages
    with TableInfo<$ConversationMessagesTable, ConversationMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta = const VerificationMeta(
    'localId',
  );
  @override
  late final GeneratedColumn<int> localId = GeneratedColumn<int>(
    'local_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversations (id)',
    ),
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageTypeMeta = const VerificationMeta(
    'messageType',
  );
  @override
  late final GeneratedColumn<String> messageType = GeneratedColumn<String>(
    'message_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageTextMeta = const VerificationMeta(
    'messageText',
  );
  @override
  late final GeneratedColumn<String> messageText = GeneratedColumn<String>(
    'message_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toolNameMeta = const VerificationMeta(
    'toolName',
  );
  @override
  late final GeneratedColumn<String> toolName = GeneratedColumn<String>(
    'tool_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _toolArgumentsJsonMeta = const VerificationMeta(
    'toolArgumentsJson',
  );
  @override
  late final GeneratedColumn<String> toolArgumentsJson =
      GeneratedColumn<String>(
        'tool_arguments_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _resultMeta = const VerificationMeta('result');
  @override
  late final GeneratedColumn<String> result = GeneratedColumn<String>(
    'result',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasoningMeta = const VerificationMeta(
    'reasoning',
  );
  @override
  late final GeneratedColumn<String> reasoning = GeneratedColumn<String>(
    'reasoning',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reasoningDetailsJsonMeta =
      const VerificationMeta('reasoningDetailsJson');
  @override
  late final GeneratedColumn<String> reasoningDetailsJson =
      GeneratedColumn<String>(
        'reasoning_details_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    localId,
    conversationId,
    messageId,
    sortOrder,
    messageType,
    messageText,
    toolName,
    toolArgumentsJson,
    result,
    reasoning,
    reasoningDetailsJson,
    error,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationMessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    if (data.containsKey('message_type')) {
      context.handle(
        _messageTypeMeta,
        messageType.isAcceptableOrUnknown(
          data['message_type']!,
          _messageTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageTypeMeta);
    }
    if (data.containsKey('message_text')) {
      context.handle(
        _messageTextMeta,
        messageText.isAcceptableOrUnknown(
          data['message_text']!,
          _messageTextMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageTextMeta);
    }
    if (data.containsKey('tool_name')) {
      context.handle(
        _toolNameMeta,
        toolName.isAcceptableOrUnknown(data['tool_name']!, _toolNameMeta),
      );
    }
    if (data.containsKey('tool_arguments_json')) {
      context.handle(
        _toolArgumentsJsonMeta,
        toolArgumentsJson.isAcceptableOrUnknown(
          data['tool_arguments_json']!,
          _toolArgumentsJsonMeta,
        ),
      );
    }
    if (data.containsKey('result')) {
      context.handle(
        _resultMeta,
        result.isAcceptableOrUnknown(data['result']!, _resultMeta),
      );
    }
    if (data.containsKey('reasoning')) {
      context.handle(
        _reasoningMeta,
        reasoning.isAcceptableOrUnknown(data['reasoning']!, _reasoningMeta),
      );
    }
    if (data.containsKey('reasoning_details_json')) {
      context.handle(
        _reasoningDetailsJsonMeta,
        reasoningDetailsJson.isAcceptableOrUnknown(
          data['reasoning_details_json']!,
          _reasoningDetailsJsonMeta,
        ),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  ConversationMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationMessageRow(
      localId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      messageType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_type'],
      )!,
      messageText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_text'],
      )!,
      toolName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_name'],
      ),
      toolArgumentsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_arguments_json'],
      ),
      result: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result'],
      ),
      reasoning: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning'],
      ),
      reasoningDetailsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_details_json'],
      ),
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
    );
  }

  @override
  $ConversationMessagesTable createAlias(String alias) {
    return $ConversationMessagesTable(attachedDatabase, alias);
  }
}

class ConversationMessageRow extends DataClass
    implements Insertable<ConversationMessageRow> {
  final int localId;
  final String conversationId;
  final String messageId;
  final int sortOrder;
  final String messageType;
  final String messageText;
  final String? toolName;
  final String? toolArgumentsJson;
  final String? result;
  final String? reasoning;
  final String? reasoningDetailsJson;
  final String? error;
  const ConversationMessageRow({
    required this.localId,
    required this.conversationId,
    required this.messageId,
    required this.sortOrder,
    required this.messageType,
    required this.messageText,
    this.toolName,
    this.toolArgumentsJson,
    this.result,
    this.reasoning,
    this.reasoningDetailsJson,
    this.error,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_id'] = Variable<int>(localId);
    map['conversation_id'] = Variable<String>(conversationId);
    map['message_id'] = Variable<String>(messageId);
    map['sort_order'] = Variable<int>(sortOrder);
    map['message_type'] = Variable<String>(messageType);
    map['message_text'] = Variable<String>(messageText);
    if (!nullToAbsent || toolName != null) {
      map['tool_name'] = Variable<String>(toolName);
    }
    if (!nullToAbsent || toolArgumentsJson != null) {
      map['tool_arguments_json'] = Variable<String>(toolArgumentsJson);
    }
    if (!nullToAbsent || result != null) {
      map['result'] = Variable<String>(result);
    }
    if (!nullToAbsent || reasoning != null) {
      map['reasoning'] = Variable<String>(reasoning);
    }
    if (!nullToAbsent || reasoningDetailsJson != null) {
      map['reasoning_details_json'] = Variable<String>(reasoningDetailsJson);
    }
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    return map;
  }

  ConversationMessagesCompanion toCompanion(bool nullToAbsent) {
    return ConversationMessagesCompanion(
      localId: Value(localId),
      conversationId: Value(conversationId),
      messageId: Value(messageId),
      sortOrder: Value(sortOrder),
      messageType: Value(messageType),
      messageText: Value(messageText),
      toolName: toolName == null && nullToAbsent
          ? const Value.absent()
          : Value(toolName),
      toolArgumentsJson: toolArgumentsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(toolArgumentsJson),
      result: result == null && nullToAbsent
          ? const Value.absent()
          : Value(result),
      reasoning: reasoning == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoning),
      reasoningDetailsJson: reasoningDetailsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningDetailsJson),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
    );
  }

  factory ConversationMessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationMessageRow(
      localId: serializer.fromJson<int>(json['localId']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      messageType: serializer.fromJson<String>(json['messageType']),
      messageText: serializer.fromJson<String>(json['messageText']),
      toolName: serializer.fromJson<String?>(json['toolName']),
      toolArgumentsJson: serializer.fromJson<String?>(
        json['toolArgumentsJson'],
      ),
      result: serializer.fromJson<String?>(json['result']),
      reasoning: serializer.fromJson<String?>(json['reasoning']),
      reasoningDetailsJson: serializer.fromJson<String?>(
        json['reasoningDetailsJson'],
      ),
      error: serializer.fromJson<String?>(json['error']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localId': serializer.toJson<int>(localId),
      'conversationId': serializer.toJson<String>(conversationId),
      'messageId': serializer.toJson<String>(messageId),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'messageType': serializer.toJson<String>(messageType),
      'messageText': serializer.toJson<String>(messageText),
      'toolName': serializer.toJson<String?>(toolName),
      'toolArgumentsJson': serializer.toJson<String?>(toolArgumentsJson),
      'result': serializer.toJson<String?>(result),
      'reasoning': serializer.toJson<String?>(reasoning),
      'reasoningDetailsJson': serializer.toJson<String?>(reasoningDetailsJson),
      'error': serializer.toJson<String?>(error),
    };
  }

  ConversationMessageRow copyWith({
    int? localId,
    String? conversationId,
    String? messageId,
    int? sortOrder,
    String? messageType,
    String? messageText,
    Value<String?> toolName = const Value.absent(),
    Value<String?> toolArgumentsJson = const Value.absent(),
    Value<String?> result = const Value.absent(),
    Value<String?> reasoning = const Value.absent(),
    Value<String?> reasoningDetailsJson = const Value.absent(),
    Value<String?> error = const Value.absent(),
  }) => ConversationMessageRow(
    localId: localId ?? this.localId,
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    sortOrder: sortOrder ?? this.sortOrder,
    messageType: messageType ?? this.messageType,
    messageText: messageText ?? this.messageText,
    toolName: toolName.present ? toolName.value : this.toolName,
    toolArgumentsJson: toolArgumentsJson.present
        ? toolArgumentsJson.value
        : this.toolArgumentsJson,
    result: result.present ? result.value : this.result,
    reasoning: reasoning.present ? reasoning.value : this.reasoning,
    reasoningDetailsJson: reasoningDetailsJson.present
        ? reasoningDetailsJson.value
        : this.reasoningDetailsJson,
    error: error.present ? error.value : this.error,
  );
  ConversationMessageRow copyWithCompanion(ConversationMessagesCompanion data) {
    return ConversationMessageRow(
      localId: data.localId.present ? data.localId.value : this.localId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      messageType: data.messageType.present
          ? data.messageType.value
          : this.messageType,
      messageText: data.messageText.present
          ? data.messageText.value
          : this.messageText,
      toolName: data.toolName.present ? data.toolName.value : this.toolName,
      toolArgumentsJson: data.toolArgumentsJson.present
          ? data.toolArgumentsJson.value
          : this.toolArgumentsJson,
      result: data.result.present ? data.result.value : this.result,
      reasoning: data.reasoning.present ? data.reasoning.value : this.reasoning,
      reasoningDetailsJson: data.reasoningDetailsJson.present
          ? data.reasoningDetailsJson.value
          : this.reasoningDetailsJson,
      error: data.error.present ? data.error.value : this.error,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationMessageRow(')
          ..write('localId: $localId, ')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('messageType: $messageType, ')
          ..write('messageText: $messageText, ')
          ..write('toolName: $toolName, ')
          ..write('toolArgumentsJson: $toolArgumentsJson, ')
          ..write('result: $result, ')
          ..write('reasoning: $reasoning, ')
          ..write('reasoningDetailsJson: $reasoningDetailsJson, ')
          ..write('error: $error')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    localId,
    conversationId,
    messageId,
    sortOrder,
    messageType,
    messageText,
    toolName,
    toolArgumentsJson,
    result,
    reasoning,
    reasoningDetailsJson,
    error,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationMessageRow &&
          other.localId == this.localId &&
          other.conversationId == this.conversationId &&
          other.messageId == this.messageId &&
          other.sortOrder == this.sortOrder &&
          other.messageType == this.messageType &&
          other.messageText == this.messageText &&
          other.toolName == this.toolName &&
          other.toolArgumentsJson == this.toolArgumentsJson &&
          other.result == this.result &&
          other.reasoning == this.reasoning &&
          other.reasoningDetailsJson == this.reasoningDetailsJson &&
          other.error == this.error);
}

class ConversationMessagesCompanion
    extends UpdateCompanion<ConversationMessageRow> {
  final Value<int> localId;
  final Value<String> conversationId;
  final Value<String> messageId;
  final Value<int> sortOrder;
  final Value<String> messageType;
  final Value<String> messageText;
  final Value<String?> toolName;
  final Value<String?> toolArgumentsJson;
  final Value<String?> result;
  final Value<String?> reasoning;
  final Value<String?> reasoningDetailsJson;
  final Value<String?> error;
  const ConversationMessagesCompanion({
    this.localId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.messageType = const Value.absent(),
    this.messageText = const Value.absent(),
    this.toolName = const Value.absent(),
    this.toolArgumentsJson = const Value.absent(),
    this.result = const Value.absent(),
    this.reasoning = const Value.absent(),
    this.reasoningDetailsJson = const Value.absent(),
    this.error = const Value.absent(),
  });
  ConversationMessagesCompanion.insert({
    this.localId = const Value.absent(),
    required String conversationId,
    required String messageId,
    required int sortOrder,
    required String messageType,
    required String messageText,
    this.toolName = const Value.absent(),
    this.toolArgumentsJson = const Value.absent(),
    this.result = const Value.absent(),
    this.reasoning = const Value.absent(),
    this.reasoningDetailsJson = const Value.absent(),
    this.error = const Value.absent(),
  }) : conversationId = Value(conversationId),
       messageId = Value(messageId),
       sortOrder = Value(sortOrder),
       messageType = Value(messageType),
       messageText = Value(messageText);
  static Insertable<ConversationMessageRow> custom({
    Expression<int>? localId,
    Expression<String>? conversationId,
    Expression<String>? messageId,
    Expression<int>? sortOrder,
    Expression<String>? messageType,
    Expression<String>? messageText,
    Expression<String>? toolName,
    Expression<String>? toolArgumentsJson,
    Expression<String>? result,
    Expression<String>? reasoning,
    Expression<String>? reasoningDetailsJson,
    Expression<String>? error,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (messageId != null) 'message_id': messageId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (messageType != null) 'message_type': messageType,
      if (messageText != null) 'message_text': messageText,
      if (toolName != null) 'tool_name': toolName,
      if (toolArgumentsJson != null) 'tool_arguments_json': toolArgumentsJson,
      if (result != null) 'result': result,
      if (reasoning != null) 'reasoning': reasoning,
      if (reasoningDetailsJson != null)
        'reasoning_details_json': reasoningDetailsJson,
      if (error != null) 'error': error,
    });
  }

  ConversationMessagesCompanion copyWith({
    Value<int>? localId,
    Value<String>? conversationId,
    Value<String>? messageId,
    Value<int>? sortOrder,
    Value<String>? messageType,
    Value<String>? messageText,
    Value<String?>? toolName,
    Value<String?>? toolArgumentsJson,
    Value<String?>? result,
    Value<String?>? reasoning,
    Value<String?>? reasoningDetailsJson,
    Value<String?>? error,
  }) {
    return ConversationMessagesCompanion(
      localId: localId ?? this.localId,
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      sortOrder: sortOrder ?? this.sortOrder,
      messageType: messageType ?? this.messageType,
      messageText: messageText ?? this.messageText,
      toolName: toolName ?? this.toolName,
      toolArgumentsJson: toolArgumentsJson ?? this.toolArgumentsJson,
      result: result ?? this.result,
      reasoning: reasoning ?? this.reasoning,
      reasoningDetailsJson: reasoningDetailsJson ?? this.reasoningDetailsJson,
      error: error ?? this.error,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<int>(localId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (messageType.present) {
      map['message_type'] = Variable<String>(messageType.value);
    }
    if (messageText.present) {
      map['message_text'] = Variable<String>(messageText.value);
    }
    if (toolName.present) {
      map['tool_name'] = Variable<String>(toolName.value);
    }
    if (toolArgumentsJson.present) {
      map['tool_arguments_json'] = Variable<String>(toolArgumentsJson.value);
    }
    if (result.present) {
      map['result'] = Variable<String>(result.value);
    }
    if (reasoning.present) {
      map['reasoning'] = Variable<String>(reasoning.value);
    }
    if (reasoningDetailsJson.present) {
      map['reasoning_details_json'] = Variable<String>(
        reasoningDetailsJson.value,
      );
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationMessagesCompanion(')
          ..write('localId: $localId, ')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('messageType: $messageType, ')
          ..write('messageText: $messageText, ')
          ..write('toolName: $toolName, ')
          ..write('toolArgumentsJson: $toolArgumentsJson, ')
          ..write('result: $result, ')
          ..write('reasoning: $reasoning, ')
          ..write('reasoningDetailsJson: $reasoningDetailsJson, ')
          ..write('error: $error')
          ..write(')'))
        .toString();
  }
}

class $ConversationAttachmentsTable extends ConversationAttachments
    with TableInfo<$ConversationAttachmentsTable, ConversationAttachmentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationAttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversations (id)',
    ),
  );
  static const VerificationMeta _uriMeta = const VerificationMeta('uri');
  @override
  late final GeneratedColumn<String> uri = GeneratedColumn<String>(
    'uri',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [conversationId, uri];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation_attachments';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationAttachmentRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('uri')) {
      context.handle(
        _uriMeta,
        uri.isAcceptableOrUnknown(data['uri']!, _uriMeta),
      );
    } else if (isInserting) {
      context.missing(_uriMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, uri};
  @override
  ConversationAttachmentRow map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationAttachmentRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      uri: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uri'],
      )!,
    );
  }

  @override
  $ConversationAttachmentsTable createAlias(String alias) {
    return $ConversationAttachmentsTable(attachedDatabase, alias);
  }
}

class ConversationAttachmentRow extends DataClass
    implements Insertable<ConversationAttachmentRow> {
  final String conversationId;
  final String uri;
  const ConversationAttachmentRow({
    required this.conversationId,
    required this.uri,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['uri'] = Variable<String>(uri);
    return map;
  }

  ConversationAttachmentsCompanion toCompanion(bool nullToAbsent) {
    return ConversationAttachmentsCompanion(
      conversationId: Value(conversationId),
      uri: Value(uri),
    );
  }

  factory ConversationAttachmentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationAttachmentRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      uri: serializer.fromJson<String>(json['uri']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'uri': serializer.toJson<String>(uri),
    };
  }

  ConversationAttachmentRow copyWith({String? conversationId, String? uri}) =>
      ConversationAttachmentRow(
        conversationId: conversationId ?? this.conversationId,
        uri: uri ?? this.uri,
      );
  ConversationAttachmentRow copyWithCompanion(
    ConversationAttachmentsCompanion data,
  ) {
    return ConversationAttachmentRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      uri: data.uri.present ? data.uri.value : this.uri,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationAttachmentRow(')
          ..write('conversationId: $conversationId, ')
          ..write('uri: $uri')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, uri);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationAttachmentRow &&
          other.conversationId == this.conversationId &&
          other.uri == this.uri);
}

class ConversationAttachmentsCompanion
    extends UpdateCompanion<ConversationAttachmentRow> {
  final Value<String> conversationId;
  final Value<String> uri;
  final Value<int> rowid;
  const ConversationAttachmentsCompanion({
    this.conversationId = const Value.absent(),
    this.uri = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationAttachmentsCompanion.insert({
    required String conversationId,
    required String uri,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       uri = Value(uri);
  static Insertable<ConversationAttachmentRow> custom({
    Expression<String>? conversationId,
    Expression<String>? uri,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (uri != null) 'uri': uri,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationAttachmentsCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? uri,
    Value<int>? rowid,
  }) {
    return ConversationAttachmentsCompanion(
      conversationId: conversationId ?? this.conversationId,
      uri: uri ?? this.uri,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (uri.present) {
      map['uri'] = Variable<String>(uri.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationAttachmentsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('uri: $uri, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ErrandDatabase extends GeneratedDatabase {
  _$ErrandDatabase(QueryExecutor e) : super(e);
  $ErrandDatabaseManager get managers => $ErrandDatabaseManager(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $ConversationMessagesTable conversationMessages =
      $ConversationMessagesTable(this);
  late final $ConversationAttachmentsTable conversationAttachments =
      $ConversationAttachmentsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    conversations,
    conversationMessages,
    conversationAttachments,
  ];
}

typedef $$ConversationsTableCreateCompanionBuilder =
    ConversationsCompanion Function({
      required String id,
      Value<String?> localSystemPrompt,
      Value<String> title,
      required String currentDir,
      Value<String?> provider,
      Value<String?> model,
      Value<bool> isPinned,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$ConversationsTableUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> id,
      Value<String?> localSystemPrompt,
      Value<String> title,
      Value<String> currentDir,
      Value<String?> provider,
      Value<String?> model,
      Value<bool> isPinned,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

final class $$ConversationsTableReferences
    extends
        BaseReferences<_$ErrandDatabase, $ConversationsTable, ConversationRow> {
  $$ConversationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<
    $ConversationMessagesTable,
    List<ConversationMessageRow>
  >
  _conversationMessagesRefsTable(_$ErrandDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.conversationMessages,
        aliasName: 'conversations__id__conversation_messages__conversation_id',
      );

  $$ConversationMessagesTableProcessedTableManager
  get conversationMessagesRefs {
    final manager = $$ConversationMessagesTableTableManager(
      $_db,
      $_db.conversationMessages,
    ).filter((f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _conversationMessagesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $ConversationAttachmentsTable,
    List<ConversationAttachmentRow>
  >
  _conversationAttachmentsRefsTable(_$ErrandDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.conversationAttachments,
        aliasName:
            'conversations__id__conversation_attachments__conversation_id',
      );

  $$ConversationAttachmentsTableProcessedTableManager
  get conversationAttachmentsRefs {
    final manager = $$ConversationAttachmentsTableTableManager(
      $_db,
      $_db.conversationAttachments,
    ).filter((f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _conversationAttachmentsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ConversationsTableFilterComposer
    extends Composer<_$ErrandDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localSystemPrompt => $composableBuilder(
    column: $table.localSystemPrompt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get currentDir => $composableBuilder(
    column: $table.currentDir,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPinned => $composableBuilder(
    column: $table.isPinned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> conversationMessagesRefs(
    Expression<bool> Function($$ConversationMessagesTableFilterComposer f) f,
  ) {
    final $$ConversationMessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.conversationMessages,
      getReferencedColumn: (t) => t.conversationId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationMessagesTableFilterComposer(
            $db: $db,
            $table: $db.conversationMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> conversationAttachmentsRefs(
    Expression<bool> Function($$ConversationAttachmentsTableFilterComposer f) f,
  ) {
    final $$ConversationAttachmentsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.conversationAttachments,
          getReferencedColumn: (t) => t.conversationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ConversationAttachmentsTableFilterComposer(
                $db: $db,
                $table: $db.conversationAttachments,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$ErrandDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localSystemPrompt => $composableBuilder(
    column: $table.localSystemPrompt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get currentDir => $composableBuilder(
    column: $table.currentDir,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPinned => $composableBuilder(
    column: $table.isPinned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get localSystemPrompt => $composableBuilder(
    column: $table.localSystemPrompt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get currentDir => $composableBuilder(
    column: $table.currentDir,
    builder: (column) => column,
  );

  GeneratedColumn<String> get provider =>
      $composableBuilder(column: $table.provider, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<bool> get isPinned =>
      $composableBuilder(column: $table.isPinned, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> conversationMessagesRefs<T extends Object>(
    Expression<T> Function($$ConversationMessagesTableAnnotationComposer a) f,
  ) {
    final $$ConversationMessagesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.conversationMessages,
          getReferencedColumn: (t) => t.conversationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ConversationMessagesTableAnnotationComposer(
                $db: $db,
                $table: $db.conversationMessages,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> conversationAttachmentsRefs<T extends Object>(
    Expression<T> Function($$ConversationAttachmentsTableAnnotationComposer a)
    f,
  ) {
    final $$ConversationAttachmentsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.conversationAttachments,
          getReferencedColumn: (t) => t.conversationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ConversationAttachmentsTableAnnotationComposer(
                $db: $db,
                $table: $db.conversationAttachments,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ConversationsTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $ConversationsTable,
          ConversationRow,
          $$ConversationsTableFilterComposer,
          $$ConversationsTableOrderingComposer,
          $$ConversationsTableAnnotationComposer,
          $$ConversationsTableCreateCompanionBuilder,
          $$ConversationsTableUpdateCompanionBuilder,
          (ConversationRow, $$ConversationsTableReferences),
          ConversationRow,
          PrefetchHooks Function({
            bool conversationMessagesRefs,
            bool conversationAttachmentsRefs,
          })
        > {
  $$ConversationsTableTableManager(
    _$ErrandDatabase db,
    $ConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> localSystemPrompt = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> currentDir = const Value.absent(),
                Value<String?> provider = const Value.absent(),
                Value<String?> model = const Value.absent(),
                Value<bool> isPinned = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                id: id,
                localSystemPrompt: localSystemPrompt,
                title: title,
                currentDir: currentDir,
                provider: provider,
                model: model,
                isPinned: isPinned,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> localSystemPrompt = const Value.absent(),
                Value<String> title = const Value.absent(),
                required String currentDir,
                Value<String?> provider = const Value.absent(),
                Value<String?> model = const Value.absent(),
                Value<bool> isPinned = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                id: id,
                localSystemPrompt: localSystemPrompt,
                title: title,
                currentDir: currentDir,
                provider: provider,
                model: model,
                isPinned: isPinned,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ConversationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                conversationMessagesRefs = false,
                conversationAttachmentsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (conversationMessagesRefs) db.conversationMessages,
                    if (conversationAttachmentsRefs) db.conversationAttachments,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (conversationMessagesRefs)
                        await $_getPrefetchedData<
                          ConversationRow,
                          $ConversationsTable,
                          ConversationMessageRow
                        >(
                          currentTable: table,
                          referencedTable: $$ConversationsTableReferences
                              ._conversationMessagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ConversationsTableReferences(
                                db,
                                table,
                                p0,
                              ).conversationMessagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.conversationId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (conversationAttachmentsRefs)
                        await $_getPrefetchedData<
                          ConversationRow,
                          $ConversationsTable,
                          ConversationAttachmentRow
                        >(
                          currentTable: table,
                          referencedTable: $$ConversationsTableReferences
                              ._conversationAttachmentsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ConversationsTableReferences(
                                db,
                                table,
                                p0,
                              ).conversationAttachmentsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.conversationId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $ConversationsTable,
      ConversationRow,
      $$ConversationsTableFilterComposer,
      $$ConversationsTableOrderingComposer,
      $$ConversationsTableAnnotationComposer,
      $$ConversationsTableCreateCompanionBuilder,
      $$ConversationsTableUpdateCompanionBuilder,
      (ConversationRow, $$ConversationsTableReferences),
      ConversationRow,
      PrefetchHooks Function({
        bool conversationMessagesRefs,
        bool conversationAttachmentsRefs,
      })
    >;
typedef $$ConversationMessagesTableCreateCompanionBuilder =
    ConversationMessagesCompanion Function({
      Value<int> localId,
      required String conversationId,
      required String messageId,
      required int sortOrder,
      required String messageType,
      required String messageText,
      Value<String?> toolName,
      Value<String?> toolArgumentsJson,
      Value<String?> result,
      Value<String?> reasoning,
      Value<String?> reasoningDetailsJson,
      Value<String?> error,
    });
typedef $$ConversationMessagesTableUpdateCompanionBuilder =
    ConversationMessagesCompanion Function({
      Value<int> localId,
      Value<String> conversationId,
      Value<String> messageId,
      Value<int> sortOrder,
      Value<String> messageType,
      Value<String> messageText,
      Value<String?> toolName,
      Value<String?> toolArgumentsJson,
      Value<String?> result,
      Value<String?> reasoning,
      Value<String?> reasoningDetailsJson,
      Value<String?> error,
    });

final class $$ConversationMessagesTableReferences
    extends
        BaseReferences<
          _$ErrandDatabase,
          $ConversationMessagesTable,
          ConversationMessageRow
        > {
  $$ConversationMessagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ConversationsTable _conversationIdTable(_$ErrandDatabase db) => db
      .conversations
      .createAlias('conversation_messages__conversation_id__conversations__id');

  $$ConversationsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationsTableTableManager(
      $_db,
      $_db.conversations,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ConversationMessagesTableFilterComposer
    extends Composer<_$ErrandDatabase, $ConversationMessagesTable> {
  $$ConversationMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageType => $composableBuilder(
    column: $table.messageType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageText => $composableBuilder(
    column: $table.messageText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolArgumentsJson => $composableBuilder(
    column: $table.toolArgumentsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get result => $composableBuilder(
    column: $table.result,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoning => $composableBuilder(
    column: $table.reasoning,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningDetailsJson => $composableBuilder(
    column: $table.reasoningDetailsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableFilterComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationMessagesTableOrderingComposer
    extends Composer<_$ErrandDatabase, $ConversationMessagesTable> {
  $$ConversationMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageType => $composableBuilder(
    column: $table.messageType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageText => $composableBuilder(
    column: $table.messageText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolArgumentsJson => $composableBuilder(
    column: $table.toolArgumentsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get result => $composableBuilder(
    column: $table.result,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoning => $composableBuilder(
    column: $table.reasoning,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningDetailsJson => $composableBuilder(
    column: $table.reasoningDetailsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableOrderingComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationMessagesTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $ConversationMessagesTable> {
  $$ConversationMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get messageType => $composableBuilder(
    column: $table.messageType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageText => $composableBuilder(
    column: $table.messageText,
    builder: (column) => column,
  );

  GeneratedColumn<String> get toolName =>
      $composableBuilder(column: $table.toolName, builder: (column) => column);

  GeneratedColumn<String> get toolArgumentsJson => $composableBuilder(
    column: $table.toolArgumentsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get result =>
      $composableBuilder(column: $table.result, builder: (column) => column);

  GeneratedColumn<String> get reasoning =>
      $composableBuilder(column: $table.reasoning, builder: (column) => column);

  GeneratedColumn<String> get reasoningDetailsJson => $composableBuilder(
    column: $table.reasoningDetailsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get conversationId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableAnnotationComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationMessagesTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $ConversationMessagesTable,
          ConversationMessageRow,
          $$ConversationMessagesTableFilterComposer,
          $$ConversationMessagesTableOrderingComposer,
          $$ConversationMessagesTableAnnotationComposer,
          $$ConversationMessagesTableCreateCompanionBuilder,
          $$ConversationMessagesTableUpdateCompanionBuilder,
          (ConversationMessageRow, $$ConversationMessagesTableReferences),
          ConversationMessageRow,
          PrefetchHooks Function({bool conversationId})
        > {
  $$ConversationMessagesTableTableManager(
    _$ErrandDatabase db,
    $ConversationMessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationMessagesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ConversationMessagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> localId = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String> messageType = const Value.absent(),
                Value<String> messageText = const Value.absent(),
                Value<String?> toolName = const Value.absent(),
                Value<String?> toolArgumentsJson = const Value.absent(),
                Value<String?> result = const Value.absent(),
                Value<String?> reasoning = const Value.absent(),
                Value<String?> reasoningDetailsJson = const Value.absent(),
                Value<String?> error = const Value.absent(),
              }) => ConversationMessagesCompanion(
                localId: localId,
                conversationId: conversationId,
                messageId: messageId,
                sortOrder: sortOrder,
                messageType: messageType,
                messageText: messageText,
                toolName: toolName,
                toolArgumentsJson: toolArgumentsJson,
                result: result,
                reasoning: reasoning,
                reasoningDetailsJson: reasoningDetailsJson,
                error: error,
              ),
          createCompanionCallback:
              ({
                Value<int> localId = const Value.absent(),
                required String conversationId,
                required String messageId,
                required int sortOrder,
                required String messageType,
                required String messageText,
                Value<String?> toolName = const Value.absent(),
                Value<String?> toolArgumentsJson = const Value.absent(),
                Value<String?> result = const Value.absent(),
                Value<String?> reasoning = const Value.absent(),
                Value<String?> reasoningDetailsJson = const Value.absent(),
                Value<String?> error = const Value.absent(),
              }) => ConversationMessagesCompanion.insert(
                localId: localId,
                conversationId: conversationId,
                messageId: messageId,
                sortOrder: sortOrder,
                messageType: messageType,
                messageText: messageText,
                toolName: toolName,
                toolArgumentsJson: toolArgumentsJson,
                result: result,
                reasoning: reasoning,
                reasoningDetailsJson: reasoningDetailsJson,
                error: error,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ConversationMessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({conversationId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (conversationId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.conversationId,
                        referencedTable: $$ConversationMessagesTableReferences
                            ._conversationIdTable(db),
                        referencedColumn: $$ConversationMessagesTableReferences
                            ._conversationIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ConversationMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $ConversationMessagesTable,
      ConversationMessageRow,
      $$ConversationMessagesTableFilterComposer,
      $$ConversationMessagesTableOrderingComposer,
      $$ConversationMessagesTableAnnotationComposer,
      $$ConversationMessagesTableCreateCompanionBuilder,
      $$ConversationMessagesTableUpdateCompanionBuilder,
      (ConversationMessageRow, $$ConversationMessagesTableReferences),
      ConversationMessageRow,
      PrefetchHooks Function({bool conversationId})
    >;
typedef $$ConversationAttachmentsTableCreateCompanionBuilder =
    ConversationAttachmentsCompanion Function({
      required String conversationId,
      required String uri,
      Value<int> rowid,
    });
typedef $$ConversationAttachmentsTableUpdateCompanionBuilder =
    ConversationAttachmentsCompanion Function({
      Value<String> conversationId,
      Value<String> uri,
      Value<int> rowid,
    });

final class $$ConversationAttachmentsTableReferences
    extends
        BaseReferences<
          _$ErrandDatabase,
          $ConversationAttachmentsTable,
          ConversationAttachmentRow
        > {
  $$ConversationAttachmentsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ConversationsTable _conversationIdTable(_$ErrandDatabase db) =>
      db.conversations.createAlias(
        'conversation_attachments__conversation_id__conversations__id',
      );

  $$ConversationsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationsTableTableManager(
      $_db,
      $_db.conversations,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ConversationAttachmentsTableFilterComposer
    extends Composer<_$ErrandDatabase, $ConversationAttachmentsTable> {
  $$ConversationAttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uri => $composableBuilder(
    column: $table.uri,
    builder: (column) => ColumnFilters(column),
  );

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableFilterComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationAttachmentsTableOrderingComposer
    extends Composer<_$ErrandDatabase, $ConversationAttachmentsTable> {
  $$ConversationAttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uri => $composableBuilder(
    column: $table.uri,
    builder: (column) => ColumnOrderings(column),
  );

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableOrderingComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationAttachmentsTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $ConversationAttachmentsTable> {
  $$ConversationAttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uri =>
      $composableBuilder(column: $table.uri, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get conversationId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableAnnotationComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationAttachmentsTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $ConversationAttachmentsTable,
          ConversationAttachmentRow,
          $$ConversationAttachmentsTableFilterComposer,
          $$ConversationAttachmentsTableOrderingComposer,
          $$ConversationAttachmentsTableAnnotationComposer,
          $$ConversationAttachmentsTableCreateCompanionBuilder,
          $$ConversationAttachmentsTableUpdateCompanionBuilder,
          (ConversationAttachmentRow, $$ConversationAttachmentsTableReferences),
          ConversationAttachmentRow,
          PrefetchHooks Function({bool conversationId})
        > {
  $$ConversationAttachmentsTableTableManager(
    _$ErrandDatabase db,
    $ConversationAttachmentsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationAttachmentsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$ConversationAttachmentsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ConversationAttachmentsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> uri = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationAttachmentsCompanion(
                conversationId: conversationId,
                uri: uri,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String uri,
                Value<int> rowid = const Value.absent(),
              }) => ConversationAttachmentsCompanion.insert(
                conversationId: conversationId,
                uri: uri,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ConversationAttachmentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({conversationId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (conversationId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.conversationId,
                        referencedTable:
                            $$ConversationAttachmentsTableReferences
                                ._conversationIdTable(db),
                        referencedColumn:
                            $$ConversationAttachmentsTableReferences
                                ._conversationIdTable(db)
                                .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ConversationAttachmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $ConversationAttachmentsTable,
      ConversationAttachmentRow,
      $$ConversationAttachmentsTableFilterComposer,
      $$ConversationAttachmentsTableOrderingComposer,
      $$ConversationAttachmentsTableAnnotationComposer,
      $$ConversationAttachmentsTableCreateCompanionBuilder,
      $$ConversationAttachmentsTableUpdateCompanionBuilder,
      (ConversationAttachmentRow, $$ConversationAttachmentsTableReferences),
      ConversationAttachmentRow,
      PrefetchHooks Function({bool conversationId})
    >;

class $ErrandDatabaseManager {
  final _$ErrandDatabase _db;
  $ErrandDatabaseManager(this._db);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$ConversationMessagesTableTableManager get conversationMessages =>
      $$ConversationMessagesTableTableManager(_db, _db.conversationMessages);
  $$ConversationAttachmentsTableTableManager get conversationAttachments =>
      $$ConversationAttachmentsTableTableManager(
        _db,
        _db.conversationAttachments,
      );
}
