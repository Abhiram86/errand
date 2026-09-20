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
  static const VerificationMeta _attachedUrisJsonMeta = const VerificationMeta(
    'attachedUrisJson',
  );
  @override
  late final GeneratedColumn<String> attachedUrisJson = GeneratedColumn<String>(
    'attached_uris_json',
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
    attachedUrisJson,
    model,
    provider,
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
    if (data.containsKey('attached_uris_json')) {
      context.handle(
        _attachedUrisJsonMeta,
        attachedUrisJson.isAcceptableOrUnknown(
          data['attached_uris_json']!,
          _attachedUrisJsonMeta,
        ),
      );
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    }
    if (data.containsKey('provider')) {
      context.handle(
        _providerMeta,
        provider.isAcceptableOrUnknown(data['provider']!, _providerMeta),
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
      attachedUrisJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attached_uris_json'],
      ),
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      ),
      provider: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}provider'],
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
  final String? attachedUrisJson;
  final String? model;
  final String? provider;
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
    this.attachedUrisJson,
    this.model,
    this.provider,
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
    if (!nullToAbsent || attachedUrisJson != null) {
      map['attached_uris_json'] = Variable<String>(attachedUrisJson);
    }
    if (!nullToAbsent || model != null) {
      map['model'] = Variable<String>(model);
    }
    if (!nullToAbsent || provider != null) {
      map['provider'] = Variable<String>(provider);
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
      attachedUrisJson: attachedUrisJson == null && nullToAbsent
          ? const Value.absent()
          : Value(attachedUrisJson),
      model: model == null && nullToAbsent
          ? const Value.absent()
          : Value(model),
      provider: provider == null && nullToAbsent
          ? const Value.absent()
          : Value(provider),
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
      attachedUrisJson: serializer.fromJson<String?>(json['attachedUrisJson']),
      model: serializer.fromJson<String?>(json['model']),
      provider: serializer.fromJson<String?>(json['provider']),
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
      'attachedUrisJson': serializer.toJson<String?>(attachedUrisJson),
      'model': serializer.toJson<String?>(model),
      'provider': serializer.toJson<String?>(provider),
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
    Value<String?> attachedUrisJson = const Value.absent(),
    Value<String?> model = const Value.absent(),
    Value<String?> provider = const Value.absent(),
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
    attachedUrisJson: attachedUrisJson.present
        ? attachedUrisJson.value
        : this.attachedUrisJson,
    model: model.present ? model.value : this.model,
    provider: provider.present ? provider.value : this.provider,
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
      attachedUrisJson: data.attachedUrisJson.present
          ? data.attachedUrisJson.value
          : this.attachedUrisJson,
      model: data.model.present ? data.model.value : this.model,
      provider: data.provider.present ? data.provider.value : this.provider,
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
          ..write('error: $error, ')
          ..write('attachedUrisJson: $attachedUrisJson, ')
          ..write('model: $model, ')
          ..write('provider: $provider')
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
    attachedUrisJson,
    model,
    provider,
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
          other.error == this.error &&
          other.attachedUrisJson == this.attachedUrisJson &&
          other.model == this.model &&
          other.provider == this.provider);
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
  final Value<String?> attachedUrisJson;
  final Value<String?> model;
  final Value<String?> provider;
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
    this.attachedUrisJson = const Value.absent(),
    this.model = const Value.absent(),
    this.provider = const Value.absent(),
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
    this.attachedUrisJson = const Value.absent(),
    this.model = const Value.absent(),
    this.provider = const Value.absent(),
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
    Expression<String>? attachedUrisJson,
    Expression<String>? model,
    Expression<String>? provider,
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
      if (attachedUrisJson != null) 'attached_uris_json': attachedUrisJson,
      if (model != null) 'model': model,
      if (provider != null) 'provider': provider,
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
    Value<String?>? attachedUrisJson,
    Value<String?>? model,
    Value<String?>? provider,
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
      attachedUrisJson: attachedUrisJson ?? this.attachedUrisJson,
      model: model ?? this.model,
      provider: provider ?? this.provider,
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
    if (attachedUrisJson.present) {
      map['attached_uris_json'] = Variable<String>(attachedUrisJson.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (provider.present) {
      map['provider'] = Variable<String>(provider.value);
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
          ..write('error: $error, ')
          ..write('attachedUrisJson: $attachedUrisJson, ')
          ..write('model: $model, ')
          ..write('provider: $provider')
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

class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSettingRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }
}

class AppSettingRow extends DataClass implements Insertable<AppSettingRow> {
  final String key;
  final String value;
  const AppSettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory AppSettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppSettingRow copyWith({String? key, String? value}) =>
      AppSettingRow(key: key ?? this.key, value: value ?? this.value);
  AppSettingRow copyWithCompanion(AppSettingsCompanion data) {
    return AppSettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class AppSettingsCompanion extends UpdateCompanion<AppSettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppSettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MemoriesTable extends Memories
    with TableInfo<$MemoriesTable, MemoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MemoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _aboutMeta = const VerificationMeta('about');
  @override
  late final GeneratedColumn<String> about = GeneratedColumn<String>(
    'about',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keywordsMeta = const VerificationMeta(
    'keywords',
  );
  @override
  late final GeneratedColumn<String> keywords = GeneratedColumn<String>(
    'keywords',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  static const VerificationMeta _sourceConversationIdMeta =
      const VerificationMeta('sourceConversationId');
  @override
  late final GeneratedColumn<String> sourceConversationId =
      GeneratedColumn<String>(
        'source_conversation_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    about,
    description,
    keywords,
    createdAt,
    updatedAt,
    sourceConversationId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'memories';
  @override
  VerificationContext validateIntegrity(
    Insertable<MemoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('about')) {
      context.handle(
        _aboutMeta,
        about.isAcceptableOrUnknown(data['about']!, _aboutMeta),
      );
    } else if (isInserting) {
      context.missing(_aboutMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_descriptionMeta);
    }
    if (data.containsKey('keywords')) {
      context.handle(
        _keywordsMeta,
        keywords.isAcceptableOrUnknown(data['keywords']!, _keywordsMeta),
      );
    } else if (isInserting) {
      context.missing(_keywordsMeta);
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
    if (data.containsKey('source_conversation_id')) {
      context.handle(
        _sourceConversationIdMeta,
        sourceConversationId.isAcceptableOrUnknown(
          data['source_conversation_id']!,
          _sourceConversationIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MemoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MemoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      about: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}about'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      keywords: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}keywords'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      sourceConversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_conversation_id'],
      ),
    );
  }

  @override
  $MemoriesTable createAlias(String alias) {
    return $MemoriesTable(attachedDatabase, alias);
  }
}

class MemoryRow extends DataClass implements Insertable<MemoryRow> {
  final String id;

  /// Short semantic identifier (NOT a generic title).
  final String about;

  /// Small but information-rich description giving context to understand/steer user intent.
  final String description;

  /// JSON array of short generic keywords, max 10.
  final String keywords;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Optional internal traceability field.
  final String? sourceConversationId;
  const MemoryRow({
    required this.id,
    required this.about,
    required this.description,
    required this.keywords,
    required this.createdAt,
    required this.updatedAt,
    this.sourceConversationId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['about'] = Variable<String>(about);
    map['description'] = Variable<String>(description);
    map['keywords'] = Variable<String>(keywords);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || sourceConversationId != null) {
      map['source_conversation_id'] = Variable<String>(sourceConversationId);
    }
    return map;
  }

  MemoriesCompanion toCompanion(bool nullToAbsent) {
    return MemoriesCompanion(
      id: Value(id),
      about: Value(about),
      description: Value(description),
      keywords: Value(keywords),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      sourceConversationId: sourceConversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceConversationId),
    );
  }

  factory MemoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MemoryRow(
      id: serializer.fromJson<String>(json['id']),
      about: serializer.fromJson<String>(json['about']),
      description: serializer.fromJson<String>(json['description']),
      keywords: serializer.fromJson<String>(json['keywords']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      sourceConversationId: serializer.fromJson<String?>(
        json['sourceConversationId'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'about': serializer.toJson<String>(about),
      'description': serializer.toJson<String>(description),
      'keywords': serializer.toJson<String>(keywords),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'sourceConversationId': serializer.toJson<String?>(sourceConversationId),
    };
  }

  MemoryRow copyWith({
    String? id,
    String? about,
    String? description,
    String? keywords,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<String?> sourceConversationId = const Value.absent(),
  }) => MemoryRow(
    id: id ?? this.id,
    about: about ?? this.about,
    description: description ?? this.description,
    keywords: keywords ?? this.keywords,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sourceConversationId: sourceConversationId.present
        ? sourceConversationId.value
        : this.sourceConversationId,
  );
  MemoryRow copyWithCompanion(MemoriesCompanion data) {
    return MemoryRow(
      id: data.id.present ? data.id.value : this.id,
      about: data.about.present ? data.about.value : this.about,
      description: data.description.present
          ? data.description.value
          : this.description,
      keywords: data.keywords.present ? data.keywords.value : this.keywords,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      sourceConversationId: data.sourceConversationId.present
          ? data.sourceConversationId.value
          : this.sourceConversationId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MemoryRow(')
          ..write('id: $id, ')
          ..write('about: $about, ')
          ..write('description: $description, ')
          ..write('keywords: $keywords, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sourceConversationId: $sourceConversationId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    about,
    description,
    keywords,
    createdAt,
    updatedAt,
    sourceConversationId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MemoryRow &&
          other.id == this.id &&
          other.about == this.about &&
          other.description == this.description &&
          other.keywords == this.keywords &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.sourceConversationId == this.sourceConversationId);
}

class MemoriesCompanion extends UpdateCompanion<MemoryRow> {
  final Value<String> id;
  final Value<String> about;
  final Value<String> description;
  final Value<String> keywords;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<String?> sourceConversationId;
  final Value<int> rowid;
  const MemoriesCompanion({
    this.id = const Value.absent(),
    this.about = const Value.absent(),
    this.description = const Value.absent(),
    this.keywords = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sourceConversationId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MemoriesCompanion.insert({
    required String id,
    required String about,
    required String description,
    required String keywords,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.sourceConversationId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       about = Value(about),
       description = Value(description),
       keywords = Value(keywords),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<MemoryRow> custom({
    Expression<String>? id,
    Expression<String>? about,
    Expression<String>? description,
    Expression<String>? keywords,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? sourceConversationId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (about != null) 'about': about,
      if (description != null) 'description': description,
      if (keywords != null) 'keywords': keywords,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (sourceConversationId != null)
        'source_conversation_id': sourceConversationId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MemoriesCompanion copyWith({
    Value<String>? id,
    Value<String>? about,
    Value<String>? description,
    Value<String>? keywords,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<String?>? sourceConversationId,
    Value<int>? rowid,
  }) {
    return MemoriesCompanion(
      id: id ?? this.id,
      about: about ?? this.about,
      description: description ?? this.description,
      keywords: keywords ?? this.keywords,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceConversationId: sourceConversationId ?? this.sourceConversationId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (about.present) {
      map['about'] = Variable<String>(about.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (keywords.present) {
      map['keywords'] = Variable<String>(keywords.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (sourceConversationId.present) {
      map['source_conversation_id'] = Variable<String>(
        sourceConversationId.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MemoriesCompanion(')
          ..write('id: $id, ')
          ..write('about: $about, ')
          ..write('description: $description, ')
          ..write('keywords: $keywords, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sourceConversationId: $sourceConversationId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SchedulerTasksTable extends SchedulerTasks
    with TableInfo<$SchedulerTasksTable, SchedulerTaskRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SchedulerTasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startsAtMeta = const VerificationMeta(
    'startsAt',
  );
  @override
  late final GeneratedColumn<int> startsAt = GeneratedColumn<int>(
    'starts_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextRunAtMeta = const VerificationMeta(
    'nextRunAt',
  );
  @override
  late final GeneratedColumn<int> nextRunAt = GeneratedColumn<int>(
    'next_run_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _repeatAfterMeta = const VerificationMeta(
    'repeatAfter',
  );
  @override
  late final GeneratedColumn<int> repeatAfter = GeneratedColumn<int>(
    'repeat_after',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _timezoneMeta = const VerificationMeta(
    'timezone',
  );
  @override
  late final GeneratedColumn<String> timezone = GeneratedColumn<String>(
    'timezone',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notifyMeta = const VerificationMeta('notify');
  @override
  late final GeneratedColumn<bool> notify = GeneratedColumn<bool>(
    'notify',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("notify" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _lastRunAtMeta = const VerificationMeta(
    'lastRunAt',
  );
  @override
  late final GeneratedColumn<int> lastRunAt = GeneratedColumn<int>(
    'last_run_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _totalRunsMeta = const VerificationMeta(
    'totalRuns',
  );
  @override
  late final GeneratedColumn<int> totalRuns = GeneratedColumn<int>(
    'total_runs',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _failuresMeta = const VerificationMeta(
    'failures',
  );
  @override
  late final GeneratedColumn<int> failures = GeneratedColumn<int>(
    'failures',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _retriesPerTurnMeta = const VerificationMeta(
    'retriesPerTurn',
  );
  @override
  late final GeneratedColumn<int> retriesPerTurn = GeneratedColumn<int>(
    'retries_per_turn',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(3),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    type,
    status,
    payloadJson,
    startsAt,
    nextRunAt,
    repeatAfter,
    timezone,
    notify,
    lastRunAt,
    totalRuns,
    failures,
    retriesPerTurn,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scheduler_task';
  @override
  VerificationContext validateIntegrity(
    Insertable<SchedulerTaskRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('starts_at')) {
      context.handle(
        _startsAtMeta,
        startsAt.isAcceptableOrUnknown(data['starts_at']!, _startsAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startsAtMeta);
    }
    if (data.containsKey('next_run_at')) {
      context.handle(
        _nextRunAtMeta,
        nextRunAt.isAcceptableOrUnknown(data['next_run_at']!, _nextRunAtMeta),
      );
    }
    if (data.containsKey('repeat_after')) {
      context.handle(
        _repeatAfterMeta,
        repeatAfter.isAcceptableOrUnknown(
          data['repeat_after']!,
          _repeatAfterMeta,
        ),
      );
    }
    if (data.containsKey('timezone')) {
      context.handle(
        _timezoneMeta,
        timezone.isAcceptableOrUnknown(data['timezone']!, _timezoneMeta),
      );
    } else if (isInserting) {
      context.missing(_timezoneMeta);
    }
    if (data.containsKey('notify')) {
      context.handle(
        _notifyMeta,
        notify.isAcceptableOrUnknown(data['notify']!, _notifyMeta),
      );
    }
    if (data.containsKey('last_run_at')) {
      context.handle(
        _lastRunAtMeta,
        lastRunAt.isAcceptableOrUnknown(data['last_run_at']!, _lastRunAtMeta),
      );
    }
    if (data.containsKey('total_runs')) {
      context.handle(
        _totalRunsMeta,
        totalRuns.isAcceptableOrUnknown(data['total_runs']!, _totalRunsMeta),
      );
    }
    if (data.containsKey('failures')) {
      context.handle(
        _failuresMeta,
        failures.isAcceptableOrUnknown(data['failures']!, _failuresMeta),
      );
    }
    if (data.containsKey('retries_per_turn')) {
      context.handle(
        _retriesPerTurnMeta,
        retriesPerTurn.isAcceptableOrUnknown(
          data['retries_per_turn']!,
          _retriesPerTurnMeta,
        ),
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
  SchedulerTaskRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SchedulerTaskRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      startsAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}starts_at'],
      )!,
      nextRunAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_run_at'],
      ),
      repeatAfter: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}repeat_after'],
      ),
      timezone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}timezone'],
      )!,
      notify: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}notify'],
      )!,
      lastRunAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_run_at'],
      ),
      totalRuns: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_runs'],
      )!,
      failures: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}failures'],
      )!,
      retriesPerTurn: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retries_per_turn'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SchedulerTasksTable createAlias(String alias) {
    return $SchedulerTasksTable(attachedDatabase, alias);
  }
}

class SchedulerTaskRow extends DataClass
    implements Insertable<SchedulerTaskRow> {
  final int id;
  final String title;
  final String type;
  final String status;
  final String payloadJson;
  final int startsAt;
  final int? nextRunAt;
  final int? repeatAfter;
  final String timezone;
  final bool notify;
  final int? lastRunAt;
  final int totalRuns;
  final int failures;
  final int retriesPerTurn;
  final int createdAt;
  final int updatedAt;
  const SchedulerTaskRow({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    required this.payloadJson,
    required this.startsAt,
    this.nextRunAt,
    this.repeatAfter,
    required this.timezone,
    required this.notify,
    this.lastRunAt,
    required this.totalRuns,
    required this.failures,
    required this.retriesPerTurn,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['title'] = Variable<String>(title);
    map['type'] = Variable<String>(type);
    map['status'] = Variable<String>(status);
    map['payload_json'] = Variable<String>(payloadJson);
    map['starts_at'] = Variable<int>(startsAt);
    if (!nullToAbsent || nextRunAt != null) {
      map['next_run_at'] = Variable<int>(nextRunAt);
    }
    if (!nullToAbsent || repeatAfter != null) {
      map['repeat_after'] = Variable<int>(repeatAfter);
    }
    map['timezone'] = Variable<String>(timezone);
    map['notify'] = Variable<bool>(notify);
    if (!nullToAbsent || lastRunAt != null) {
      map['last_run_at'] = Variable<int>(lastRunAt);
    }
    map['total_runs'] = Variable<int>(totalRuns);
    map['failures'] = Variable<int>(failures);
    map['retries_per_turn'] = Variable<int>(retriesPerTurn);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SchedulerTasksCompanion toCompanion(bool nullToAbsent) {
    return SchedulerTasksCompanion(
      id: Value(id),
      title: Value(title),
      type: Value(type),
      status: Value(status),
      payloadJson: Value(payloadJson),
      startsAt: Value(startsAt),
      nextRunAt: nextRunAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextRunAt),
      repeatAfter: repeatAfter == null && nullToAbsent
          ? const Value.absent()
          : Value(repeatAfter),
      timezone: Value(timezone),
      notify: Value(notify),
      lastRunAt: lastRunAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastRunAt),
      totalRuns: Value(totalRuns),
      failures: Value(failures),
      retriesPerTurn: Value(retriesPerTurn),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory SchedulerTaskRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SchedulerTaskRow(
      id: serializer.fromJson<int>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      type: serializer.fromJson<String>(json['type']),
      status: serializer.fromJson<String>(json['status']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      startsAt: serializer.fromJson<int>(json['startsAt']),
      nextRunAt: serializer.fromJson<int?>(json['nextRunAt']),
      repeatAfter: serializer.fromJson<int?>(json['repeatAfter']),
      timezone: serializer.fromJson<String>(json['timezone']),
      notify: serializer.fromJson<bool>(json['notify']),
      lastRunAt: serializer.fromJson<int?>(json['lastRunAt']),
      totalRuns: serializer.fromJson<int>(json['totalRuns']),
      failures: serializer.fromJson<int>(json['failures']),
      retriesPerTurn: serializer.fromJson<int>(json['retriesPerTurn']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'title': serializer.toJson<String>(title),
      'type': serializer.toJson<String>(type),
      'status': serializer.toJson<String>(status),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'startsAt': serializer.toJson<int>(startsAt),
      'nextRunAt': serializer.toJson<int?>(nextRunAt),
      'repeatAfter': serializer.toJson<int?>(repeatAfter),
      'timezone': serializer.toJson<String>(timezone),
      'notify': serializer.toJson<bool>(notify),
      'lastRunAt': serializer.toJson<int?>(lastRunAt),
      'totalRuns': serializer.toJson<int>(totalRuns),
      'failures': serializer.toJson<int>(failures),
      'retriesPerTurn': serializer.toJson<int>(retriesPerTurn),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SchedulerTaskRow copyWith({
    int? id,
    String? title,
    String? type,
    String? status,
    String? payloadJson,
    int? startsAt,
    Value<int?> nextRunAt = const Value.absent(),
    Value<int?> repeatAfter = const Value.absent(),
    String? timezone,
    bool? notify,
    Value<int?> lastRunAt = const Value.absent(),
    int? totalRuns,
    int? failures,
    int? retriesPerTurn,
    int? createdAt,
    int? updatedAt,
  }) => SchedulerTaskRow(
    id: id ?? this.id,
    title: title ?? this.title,
    type: type ?? this.type,
    status: status ?? this.status,
    payloadJson: payloadJson ?? this.payloadJson,
    startsAt: startsAt ?? this.startsAt,
    nextRunAt: nextRunAt.present ? nextRunAt.value : this.nextRunAt,
    repeatAfter: repeatAfter.present ? repeatAfter.value : this.repeatAfter,
    timezone: timezone ?? this.timezone,
    notify: notify ?? this.notify,
    lastRunAt: lastRunAt.present ? lastRunAt.value : this.lastRunAt,
    totalRuns: totalRuns ?? this.totalRuns,
    failures: failures ?? this.failures,
    retriesPerTurn: retriesPerTurn ?? this.retriesPerTurn,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SchedulerTaskRow copyWithCompanion(SchedulerTasksCompanion data) {
    return SchedulerTaskRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      type: data.type.present ? data.type.value : this.type,
      status: data.status.present ? data.status.value : this.status,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      startsAt: data.startsAt.present ? data.startsAt.value : this.startsAt,
      nextRunAt: data.nextRunAt.present ? data.nextRunAt.value : this.nextRunAt,
      repeatAfter: data.repeatAfter.present
          ? data.repeatAfter.value
          : this.repeatAfter,
      timezone: data.timezone.present ? data.timezone.value : this.timezone,
      notify: data.notify.present ? data.notify.value : this.notify,
      lastRunAt: data.lastRunAt.present ? data.lastRunAt.value : this.lastRunAt,
      totalRuns: data.totalRuns.present ? data.totalRuns.value : this.totalRuns,
      failures: data.failures.present ? data.failures.value : this.failures,
      retriesPerTurn: data.retriesPerTurn.present
          ? data.retriesPerTurn.value
          : this.retriesPerTurn,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SchedulerTaskRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('startsAt: $startsAt, ')
          ..write('nextRunAt: $nextRunAt, ')
          ..write('repeatAfter: $repeatAfter, ')
          ..write('timezone: $timezone, ')
          ..write('notify: $notify, ')
          ..write('lastRunAt: $lastRunAt, ')
          ..write('totalRuns: $totalRuns, ')
          ..write('failures: $failures, ')
          ..write('retriesPerTurn: $retriesPerTurn, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    type,
    status,
    payloadJson,
    startsAt,
    nextRunAt,
    repeatAfter,
    timezone,
    notify,
    lastRunAt,
    totalRuns,
    failures,
    retriesPerTurn,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SchedulerTaskRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.type == this.type &&
          other.status == this.status &&
          other.payloadJson == this.payloadJson &&
          other.startsAt == this.startsAt &&
          other.nextRunAt == this.nextRunAt &&
          other.repeatAfter == this.repeatAfter &&
          other.timezone == this.timezone &&
          other.notify == this.notify &&
          other.lastRunAt == this.lastRunAt &&
          other.totalRuns == this.totalRuns &&
          other.failures == this.failures &&
          other.retriesPerTurn == this.retriesPerTurn &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class SchedulerTasksCompanion extends UpdateCompanion<SchedulerTaskRow> {
  final Value<int> id;
  final Value<String> title;
  final Value<String> type;
  final Value<String> status;
  final Value<String> payloadJson;
  final Value<int> startsAt;
  final Value<int?> nextRunAt;
  final Value<int?> repeatAfter;
  final Value<String> timezone;
  final Value<bool> notify;
  final Value<int?> lastRunAt;
  final Value<int> totalRuns;
  final Value<int> failures;
  final Value<int> retriesPerTurn;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  const SchedulerTasksCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.startsAt = const Value.absent(),
    this.nextRunAt = const Value.absent(),
    this.repeatAfter = const Value.absent(),
    this.timezone = const Value.absent(),
    this.notify = const Value.absent(),
    this.lastRunAt = const Value.absent(),
    this.totalRuns = const Value.absent(),
    this.failures = const Value.absent(),
    this.retriesPerTurn = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SchedulerTasksCompanion.insert({
    this.id = const Value.absent(),
    required String title,
    required String type,
    required String status,
    required String payloadJson,
    required int startsAt,
    this.nextRunAt = const Value.absent(),
    this.repeatAfter = const Value.absent(),
    required String timezone,
    this.notify = const Value.absent(),
    this.lastRunAt = const Value.absent(),
    this.totalRuns = const Value.absent(),
    this.failures = const Value.absent(),
    this.retriesPerTurn = const Value.absent(),
    required int createdAt,
    required int updatedAt,
  }) : title = Value(title),
       type = Value(type),
       status = Value(status),
       payloadJson = Value(payloadJson),
       startsAt = Value(startsAt),
       timezone = Value(timezone),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<SchedulerTaskRow> custom({
    Expression<int>? id,
    Expression<String>? title,
    Expression<String>? type,
    Expression<String>? status,
    Expression<String>? payloadJson,
    Expression<int>? startsAt,
    Expression<int>? nextRunAt,
    Expression<int>? repeatAfter,
    Expression<String>? timezone,
    Expression<bool>? notify,
    Expression<int>? lastRunAt,
    Expression<int>? totalRuns,
    Expression<int>? failures,
    Expression<int>? retriesPerTurn,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (type != null) 'type': type,
      if (status != null) 'status': status,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (startsAt != null) 'starts_at': startsAt,
      if (nextRunAt != null) 'next_run_at': nextRunAt,
      if (repeatAfter != null) 'repeat_after': repeatAfter,
      if (timezone != null) 'timezone': timezone,
      if (notify != null) 'notify': notify,
      if (lastRunAt != null) 'last_run_at': lastRunAt,
      if (totalRuns != null) 'total_runs': totalRuns,
      if (failures != null) 'failures': failures,
      if (retriesPerTurn != null) 'retries_per_turn': retriesPerTurn,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SchedulerTasksCompanion copyWith({
    Value<int>? id,
    Value<String>? title,
    Value<String>? type,
    Value<String>? status,
    Value<String>? payloadJson,
    Value<int>? startsAt,
    Value<int?>? nextRunAt,
    Value<int?>? repeatAfter,
    Value<String>? timezone,
    Value<bool>? notify,
    Value<int?>? lastRunAt,
    Value<int>? totalRuns,
    Value<int>? failures,
    Value<int>? retriesPerTurn,
    Value<int>? createdAt,
    Value<int>? updatedAt,
  }) {
    return SchedulerTasksCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      status: status ?? this.status,
      payloadJson: payloadJson ?? this.payloadJson,
      startsAt: startsAt ?? this.startsAt,
      nextRunAt: nextRunAt ?? this.nextRunAt,
      repeatAfter: repeatAfter ?? this.repeatAfter,
      timezone: timezone ?? this.timezone,
      notify: notify ?? this.notify,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      totalRuns: totalRuns ?? this.totalRuns,
      failures: failures ?? this.failures,
      retriesPerTurn: retriesPerTurn ?? this.retriesPerTurn,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (startsAt.present) {
      map['starts_at'] = Variable<int>(startsAt.value);
    }
    if (nextRunAt.present) {
      map['next_run_at'] = Variable<int>(nextRunAt.value);
    }
    if (repeatAfter.present) {
      map['repeat_after'] = Variable<int>(repeatAfter.value);
    }
    if (timezone.present) {
      map['timezone'] = Variable<String>(timezone.value);
    }
    if (notify.present) {
      map['notify'] = Variable<bool>(notify.value);
    }
    if (lastRunAt.present) {
      map['last_run_at'] = Variable<int>(lastRunAt.value);
    }
    if (totalRuns.present) {
      map['total_runs'] = Variable<int>(totalRuns.value);
    }
    if (failures.present) {
      map['failures'] = Variable<int>(failures.value);
    }
    if (retriesPerTurn.present) {
      map['retries_per_turn'] = Variable<int>(retriesPerTurn.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SchedulerTasksCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('startsAt: $startsAt, ')
          ..write('nextRunAt: $nextRunAt, ')
          ..write('repeatAfter: $repeatAfter, ')
          ..write('timezone: $timezone, ')
          ..write('notify: $notify, ')
          ..write('lastRunAt: $lastRunAt, ')
          ..write('totalRuns: $totalRuns, ')
          ..write('failures: $failures, ')
          ..write('retriesPerTurn: $retriesPerTurn, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $SchedulerTaskLogsTable extends SchedulerTaskLogs
    with TableInfo<$SchedulerTaskLogsTable, SchedulerTaskLogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SchedulerTaskLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _schedulerTaskIdMeta = const VerificationMeta(
    'schedulerTaskId',
  );
  @override
  late final GeneratedColumn<int> schedulerTaskId = GeneratedColumn<int>(
    'scheduler_task_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES scheduler_task (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _scheduledForMeta = const VerificationMeta(
    'scheduledFor',
  );
  @override
  late final GeneratedColumn<int> scheduledFor = GeneratedColumn<int>(
    'scheduled_for',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
    'finished_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noAttemptsMeta = const VerificationMeta(
    'noAttempts',
  );
  @override
  late final GeneratedColumn<int> noAttempts = GeneratedColumn<int>(
    'no_attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _errorMessageMeta = const VerificationMeta(
    'errorMessage',
  );
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
    'error_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _outputFilePathMeta = const VerificationMeta(
    'outputFilePath',
  );
  @override
  late final GeneratedColumn<String> outputFilePath = GeneratedColumn<String>(
    'output_file_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notificationSentMeta = const VerificationMeta(
    'notificationSent',
  );
  @override
  late final GeneratedColumn<int> notificationSent = GeneratedColumn<int>(
    'notification_sent',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _notificationSeenMeta = const VerificationMeta(
    'notificationSeen',
  );
  @override
  late final GeneratedColumn<int> notificationSeen = GeneratedColumn<int>(
    'notification_seen',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    schedulerTaskId,
    scheduledFor,
    startedAt,
    finishedAt,
    status,
    noAttempts,
    errorMessage,
    outputFilePath,
    summary,
    notificationSent,
    notificationSeen,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scheduler_task_log';
  @override
  VerificationContext validateIntegrity(
    Insertable<SchedulerTaskLogRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('scheduler_task_id')) {
      context.handle(
        _schedulerTaskIdMeta,
        schedulerTaskId.isAcceptableOrUnknown(
          data['scheduler_task_id']!,
          _schedulerTaskIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_schedulerTaskIdMeta);
    }
    if (data.containsKey('scheduled_for')) {
      context.handle(
        _scheduledForMeta,
        scheduledFor.isAcceptableOrUnknown(
          data['scheduled_for']!,
          _scheduledForMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_scheduledForMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('no_attempts')) {
      context.handle(
        _noAttemptsMeta,
        noAttempts.isAcceptableOrUnknown(data['no_attempts']!, _noAttemptsMeta),
      );
    }
    if (data.containsKey('error_message')) {
      context.handle(
        _errorMessageMeta,
        errorMessage.isAcceptableOrUnknown(
          data['error_message']!,
          _errorMessageMeta,
        ),
      );
    }
    if (data.containsKey('output_file_path')) {
      context.handle(
        _outputFilePathMeta,
        outputFilePath.isAcceptableOrUnknown(
          data['output_file_path']!,
          _outputFilePathMeta,
        ),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('notification_sent')) {
      context.handle(
        _notificationSentMeta,
        notificationSent.isAcceptableOrUnknown(
          data['notification_sent']!,
          _notificationSentMeta,
        ),
      );
    }
    if (data.containsKey('notification_seen')) {
      context.handle(
        _notificationSeenMeta,
        notificationSeen.isAcceptableOrUnknown(
          data['notification_seen']!,
          _notificationSeenMeta,
        ),
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
  SchedulerTaskLogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SchedulerTaskLogRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      schedulerTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scheduler_task_id'],
      )!,
      scheduledFor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scheduled_for'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      ),
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}finished_at'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      noAttempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}no_attempts'],
      )!,
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
      outputFilePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}output_file_path'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      notificationSent: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}notification_sent'],
      )!,
      notificationSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}notification_seen'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SchedulerTaskLogsTable createAlias(String alias) {
    return $SchedulerTaskLogsTable(attachedDatabase, alias);
  }
}

class SchedulerTaskLogRow extends DataClass
    implements Insertable<SchedulerTaskLogRow> {
  final int id;
  final int schedulerTaskId;
  final int scheduledFor;
  final int? startedAt;
  final int? finishedAt;
  final String status;
  final int noAttempts;
  final String? errorMessage;
  final String? outputFilePath;
  final String? summary;
  final int notificationSent;
  final int notificationSeen;
  final int createdAt;
  final int updatedAt;
  const SchedulerTaskLogRow({
    required this.id,
    required this.schedulerTaskId,
    required this.scheduledFor,
    this.startedAt,
    this.finishedAt,
    required this.status,
    required this.noAttempts,
    this.errorMessage,
    this.outputFilePath,
    this.summary,
    required this.notificationSent,
    required this.notificationSeen,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['scheduler_task_id'] = Variable<int>(schedulerTaskId);
    map['scheduled_for'] = Variable<int>(scheduledFor);
    if (!nullToAbsent || startedAt != null) {
      map['started_at'] = Variable<int>(startedAt);
    }
    if (!nullToAbsent || finishedAt != null) {
      map['finished_at'] = Variable<int>(finishedAt);
    }
    map['status'] = Variable<String>(status);
    map['no_attempts'] = Variable<int>(noAttempts);
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    if (!nullToAbsent || outputFilePath != null) {
      map['output_file_path'] = Variable<String>(outputFilePath);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    map['notification_sent'] = Variable<int>(notificationSent);
    map['notification_seen'] = Variable<int>(notificationSeen);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SchedulerTaskLogsCompanion toCompanion(bool nullToAbsent) {
    return SchedulerTaskLogsCompanion(
      id: Value(id),
      schedulerTaskId: Value(schedulerTaskId),
      scheduledFor: Value(scheduledFor),
      startedAt: startedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(startedAt),
      finishedAt: finishedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(finishedAt),
      status: Value(status),
      noAttempts: Value(noAttempts),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      outputFilePath: outputFilePath == null && nullToAbsent
          ? const Value.absent()
          : Value(outputFilePath),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      notificationSent: Value(notificationSent),
      notificationSeen: Value(notificationSeen),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory SchedulerTaskLogRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SchedulerTaskLogRow(
      id: serializer.fromJson<int>(json['id']),
      schedulerTaskId: serializer.fromJson<int>(json['schedulerTaskId']),
      scheduledFor: serializer.fromJson<int>(json['scheduledFor']),
      startedAt: serializer.fromJson<int?>(json['startedAt']),
      finishedAt: serializer.fromJson<int?>(json['finishedAt']),
      status: serializer.fromJson<String>(json['status']),
      noAttempts: serializer.fromJson<int>(json['noAttempts']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      outputFilePath: serializer.fromJson<String?>(json['outputFilePath']),
      summary: serializer.fromJson<String?>(json['summary']),
      notificationSent: serializer.fromJson<int>(json['notificationSent']),
      notificationSeen: serializer.fromJson<int>(json['notificationSeen']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'schedulerTaskId': serializer.toJson<int>(schedulerTaskId),
      'scheduledFor': serializer.toJson<int>(scheduledFor),
      'startedAt': serializer.toJson<int?>(startedAt),
      'finishedAt': serializer.toJson<int?>(finishedAt),
      'status': serializer.toJson<String>(status),
      'noAttempts': serializer.toJson<int>(noAttempts),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'outputFilePath': serializer.toJson<String?>(outputFilePath),
      'summary': serializer.toJson<String?>(summary),
      'notificationSent': serializer.toJson<int>(notificationSent),
      'notificationSeen': serializer.toJson<int>(notificationSeen),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SchedulerTaskLogRow copyWith({
    int? id,
    int? schedulerTaskId,
    int? scheduledFor,
    Value<int?> startedAt = const Value.absent(),
    Value<int?> finishedAt = const Value.absent(),
    String? status,
    int? noAttempts,
    Value<String?> errorMessage = const Value.absent(),
    Value<String?> outputFilePath = const Value.absent(),
    Value<String?> summary = const Value.absent(),
    int? notificationSent,
    int? notificationSeen,
    int? createdAt,
    int? updatedAt,
  }) => SchedulerTaskLogRow(
    id: id ?? this.id,
    schedulerTaskId: schedulerTaskId ?? this.schedulerTaskId,
    scheduledFor: scheduledFor ?? this.scheduledFor,
    startedAt: startedAt.present ? startedAt.value : this.startedAt,
    finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
    status: status ?? this.status,
    noAttempts: noAttempts ?? this.noAttempts,
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
    outputFilePath: outputFilePath.present
        ? outputFilePath.value
        : this.outputFilePath,
    summary: summary.present ? summary.value : this.summary,
    notificationSent: notificationSent ?? this.notificationSent,
    notificationSeen: notificationSeen ?? this.notificationSeen,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SchedulerTaskLogRow copyWithCompanion(SchedulerTaskLogsCompanion data) {
    return SchedulerTaskLogRow(
      id: data.id.present ? data.id.value : this.id,
      schedulerTaskId: data.schedulerTaskId.present
          ? data.schedulerTaskId.value
          : this.schedulerTaskId,
      scheduledFor: data.scheduledFor.present
          ? data.scheduledFor.value
          : this.scheduledFor,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      status: data.status.present ? data.status.value : this.status,
      noAttempts: data.noAttempts.present
          ? data.noAttempts.value
          : this.noAttempts,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      outputFilePath: data.outputFilePath.present
          ? data.outputFilePath.value
          : this.outputFilePath,
      summary: data.summary.present ? data.summary.value : this.summary,
      notificationSent: data.notificationSent.present
          ? data.notificationSent.value
          : this.notificationSent,
      notificationSeen: data.notificationSeen.present
          ? data.notificationSeen.value
          : this.notificationSeen,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SchedulerTaskLogRow(')
          ..write('id: $id, ')
          ..write('schedulerTaskId: $schedulerTaskId, ')
          ..write('scheduledFor: $scheduledFor, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('status: $status, ')
          ..write('noAttempts: $noAttempts, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('outputFilePath: $outputFilePath, ')
          ..write('summary: $summary, ')
          ..write('notificationSent: $notificationSent, ')
          ..write('notificationSeen: $notificationSeen, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    schedulerTaskId,
    scheduledFor,
    startedAt,
    finishedAt,
    status,
    noAttempts,
    errorMessage,
    outputFilePath,
    summary,
    notificationSent,
    notificationSeen,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SchedulerTaskLogRow &&
          other.id == this.id &&
          other.schedulerTaskId == this.schedulerTaskId &&
          other.scheduledFor == this.scheduledFor &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.status == this.status &&
          other.noAttempts == this.noAttempts &&
          other.errorMessage == this.errorMessage &&
          other.outputFilePath == this.outputFilePath &&
          other.summary == this.summary &&
          other.notificationSent == this.notificationSent &&
          other.notificationSeen == this.notificationSeen &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class SchedulerTaskLogsCompanion extends UpdateCompanion<SchedulerTaskLogRow> {
  final Value<int> id;
  final Value<int> schedulerTaskId;
  final Value<int> scheduledFor;
  final Value<int?> startedAt;
  final Value<int?> finishedAt;
  final Value<String> status;
  final Value<int> noAttempts;
  final Value<String?> errorMessage;
  final Value<String?> outputFilePath;
  final Value<String?> summary;
  final Value<int> notificationSent;
  final Value<int> notificationSeen;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  const SchedulerTaskLogsCompanion({
    this.id = const Value.absent(),
    this.schedulerTaskId = const Value.absent(),
    this.scheduledFor = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.status = const Value.absent(),
    this.noAttempts = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.outputFilePath = const Value.absent(),
    this.summary = const Value.absent(),
    this.notificationSent = const Value.absent(),
    this.notificationSeen = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SchedulerTaskLogsCompanion.insert({
    this.id = const Value.absent(),
    required int schedulerTaskId,
    required int scheduledFor,
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    required String status,
    this.noAttempts = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.outputFilePath = const Value.absent(),
    this.summary = const Value.absent(),
    this.notificationSent = const Value.absent(),
    this.notificationSeen = const Value.absent(),
    required int createdAt,
    required int updatedAt,
  }) : schedulerTaskId = Value(schedulerTaskId),
       scheduledFor = Value(scheduledFor),
       status = Value(status),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<SchedulerTaskLogRow> custom({
    Expression<int>? id,
    Expression<int>? schedulerTaskId,
    Expression<int>? scheduledFor,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<String>? status,
    Expression<int>? noAttempts,
    Expression<String>? errorMessage,
    Expression<String>? outputFilePath,
    Expression<String>? summary,
    Expression<int>? notificationSent,
    Expression<int>? notificationSeen,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (schedulerTaskId != null) 'scheduler_task_id': schedulerTaskId,
      if (scheduledFor != null) 'scheduled_for': scheduledFor,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (status != null) 'status': status,
      if (noAttempts != null) 'no_attempts': noAttempts,
      if (errorMessage != null) 'error_message': errorMessage,
      if (outputFilePath != null) 'output_file_path': outputFilePath,
      if (summary != null) 'summary': summary,
      if (notificationSent != null) 'notification_sent': notificationSent,
      if (notificationSeen != null) 'notification_seen': notificationSeen,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SchedulerTaskLogsCompanion copyWith({
    Value<int>? id,
    Value<int>? schedulerTaskId,
    Value<int>? scheduledFor,
    Value<int?>? startedAt,
    Value<int?>? finishedAt,
    Value<String>? status,
    Value<int>? noAttempts,
    Value<String?>? errorMessage,
    Value<String?>? outputFilePath,
    Value<String?>? summary,
    Value<int>? notificationSent,
    Value<int>? notificationSeen,
    Value<int>? createdAt,
    Value<int>? updatedAt,
  }) {
    return SchedulerTaskLogsCompanion(
      id: id ?? this.id,
      schedulerTaskId: schedulerTaskId ?? this.schedulerTaskId,
      scheduledFor: scheduledFor ?? this.scheduledFor,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      status: status ?? this.status,
      noAttempts: noAttempts ?? this.noAttempts,
      errorMessage: errorMessage ?? this.errorMessage,
      outputFilePath: outputFilePath ?? this.outputFilePath,
      summary: summary ?? this.summary,
      notificationSent: notificationSent ?? this.notificationSent,
      notificationSeen: notificationSeen ?? this.notificationSeen,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (schedulerTaskId.present) {
      map['scheduler_task_id'] = Variable<int>(schedulerTaskId.value);
    }
    if (scheduledFor.present) {
      map['scheduled_for'] = Variable<int>(scheduledFor.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(finishedAt.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (noAttempts.present) {
      map['no_attempts'] = Variable<int>(noAttempts.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (outputFilePath.present) {
      map['output_file_path'] = Variable<String>(outputFilePath.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (notificationSent.present) {
      map['notification_sent'] = Variable<int>(notificationSent.value);
    }
    if (notificationSeen.present) {
      map['notification_seen'] = Variable<int>(notificationSeen.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SchedulerTaskLogsCompanion(')
          ..write('id: $id, ')
          ..write('schedulerTaskId: $schedulerTaskId, ')
          ..write('scheduledFor: $scheduledFor, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('status: $status, ')
          ..write('noAttempts: $noAttempts, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('outputFilePath: $outputFilePath, ')
          ..write('summary: $summary, ')
          ..write('notificationSent: $notificationSent, ')
          ..write('notificationSeen: $notificationSeen, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
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
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  late final $MemoriesTable memories = $MemoriesTable(this);
  late final $SchedulerTasksTable schedulerTasks = $SchedulerTasksTable(this);
  late final $SchedulerTaskLogsTable schedulerTaskLogs =
      $SchedulerTaskLogsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    conversations,
    conversationMessages,
    conversationAttachments,
    appSettings,
    memories,
    schedulerTasks,
    schedulerTaskLogs,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'scheduler_task',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('scheduler_task_log', kind: UpdateKind.delete)],
    ),
  ]);
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
      Value<String?> attachedUrisJson,
      Value<String?> model,
      Value<String?> provider,
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
      Value<String?> attachedUrisJson,
      Value<String?> model,
      Value<String?> provider,
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

  ColumnFilters<String> get attachedUrisJson => $composableBuilder(
    column: $table.attachedUrisJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get provider => $composableBuilder(
    column: $table.provider,
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

  ColumnOrderings<String> get attachedUrisJson => $composableBuilder(
    column: $table.attachedUrisJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get provider => $composableBuilder(
    column: $table.provider,
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

  GeneratedColumn<String> get attachedUrisJson => $composableBuilder(
    column: $table.attachedUrisJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<String> get provider =>
      $composableBuilder(column: $table.provider, builder: (column) => column);

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
                Value<String?> attachedUrisJson = const Value.absent(),
                Value<String?> model = const Value.absent(),
                Value<String?> provider = const Value.absent(),
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
                attachedUrisJson: attachedUrisJson,
                model: model,
                provider: provider,
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
                Value<String?> attachedUrisJson = const Value.absent(),
                Value<String?> model = const Value.absent(),
                Value<String?> provider = const Value.absent(),
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
                attachedUrisJson: attachedUrisJson,
                model: model,
                provider: provider,
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
typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$ErrandDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingsTableOrderingComposer
    extends Composer<_$ErrandDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $AppSettingsTable,
          AppSettingRow,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSettingRow,
            BaseReferences<_$ErrandDatabase, $AppSettingsTable, AppSettingRow>,
          ),
          AppSettingRow,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(_$ErrandDatabase db, $AppSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => AppSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $AppSettingsTable,
      AppSettingRow,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSettingRow,
        BaseReferences<_$ErrandDatabase, $AppSettingsTable, AppSettingRow>,
      ),
      AppSettingRow,
      PrefetchHooks Function()
    >;
typedef $$MemoriesTableCreateCompanionBuilder = MemoriesCompanion Function({
  required String id,
  required String about,
  required String description,
  required String keywords,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<String?> sourceConversationId,
  Value<int> rowid,
});
typedef $$MemoriesTableUpdateCompanionBuilder = MemoriesCompanion Function({
  Value<String> id,
  Value<String> about,
  Value<String> description,
  Value<String> keywords,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<String?> sourceConversationId,
  Value<int> rowid,
});

class $$MemoriesTableFilterComposer
    extends Composer<_$ErrandDatabase, $MemoriesTable> {
  $$MemoriesTableFilterComposer({
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

  ColumnFilters<String> get about => $composableBuilder(
    column: $table.about,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keywords => $composableBuilder(
    column: $table.keywords,
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

  ColumnFilters<String> get sourceConversationId => $composableBuilder(
    column: $table.sourceConversationId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MemoriesTableOrderingComposer
    extends Composer<_$ErrandDatabase, $MemoriesTable> {
  $$MemoriesTableOrderingComposer({
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

  ColumnOrderings<String> get about => $composableBuilder(
    column: $table.about,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keywords => $composableBuilder(
    column: $table.keywords,
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

  ColumnOrderings<String> get sourceConversationId => $composableBuilder(
    column: $table.sourceConversationId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MemoriesTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $MemoriesTable> {
  $$MemoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get about =>
      $composableBuilder(column: $table.about, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get keywords =>
      $composableBuilder(column: $table.keywords, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get sourceConversationId => $composableBuilder(
    column: $table.sourceConversationId,
    builder: (column) => column,
  );
}

class $$MemoriesTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $MemoriesTable,
          MemoryRow,
          $$MemoriesTableFilterComposer,
          $$MemoriesTableOrderingComposer,
          $$MemoriesTableAnnotationComposer,
          $$MemoriesTableCreateCompanionBuilder,
          $$MemoriesTableUpdateCompanionBuilder,
          (
            MemoryRow,
            BaseReferences<_$ErrandDatabase, $MemoriesTable, MemoryRow>,
          ),
          MemoryRow,
          PrefetchHooks Function()
        > {
  $$MemoriesTableTableManager(_$ErrandDatabase db, $MemoriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MemoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MemoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MemoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> about = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<String> keywords = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String?> sourceConversationId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MemoriesCompanion(
                id: id,
                about: about,
                description: description,
                keywords: keywords,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sourceConversationId: sourceConversationId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String about,
                required String description,
                required String keywords,
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<String?> sourceConversationId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MemoriesCompanion.insert(
                id: id,
                about: about,
                description: description,
                keywords: keywords,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sourceConversationId: sourceConversationId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MemoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $MemoriesTable,
      MemoryRow,
      $$MemoriesTableFilterComposer,
      $$MemoriesTableOrderingComposer,
      $$MemoriesTableAnnotationComposer,
      $$MemoriesTableCreateCompanionBuilder,
      $$MemoriesTableUpdateCompanionBuilder,
      (MemoryRow, BaseReferences<_$ErrandDatabase, $MemoriesTable, MemoryRow>),
      MemoryRow,
      PrefetchHooks Function()
    >;
typedef $$SchedulerTasksTableCreateCompanionBuilder =
    SchedulerTasksCompanion Function({
      Value<int> id,
      required String title,
      required String type,
      required String status,
      required String payloadJson,
      required int startsAt,
      Value<int?> nextRunAt,
      Value<int?> repeatAfter,
      required String timezone,
      Value<bool> notify,
      Value<int?> lastRunAt,
      Value<int> totalRuns,
      Value<int> failures,
      Value<int> retriesPerTurn,
      required int createdAt,
      required int updatedAt,
    });
typedef $$SchedulerTasksTableUpdateCompanionBuilder =
    SchedulerTasksCompanion Function({
      Value<int> id,
      Value<String> title,
      Value<String> type,
      Value<String> status,
      Value<String> payloadJson,
      Value<int> startsAt,
      Value<int?> nextRunAt,
      Value<int?> repeatAfter,
      Value<String> timezone,
      Value<bool> notify,
      Value<int?> lastRunAt,
      Value<int> totalRuns,
      Value<int> failures,
      Value<int> retriesPerTurn,
      Value<int> createdAt,
      Value<int> updatedAt,
    });

final class $$SchedulerTasksTableReferences
    extends
        BaseReferences<
          _$ErrandDatabase,
          $SchedulerTasksTable,
          SchedulerTaskRow
        > {
  $$SchedulerTasksTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$SchedulerTaskLogsTable, List<SchedulerTaskLogRow>>
  _schedulerTaskLogsRefsTable(_$ErrandDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.schedulerTaskLogs,
        aliasName: 'scheduler_task__id__scheduler_task_log__scheduler_task_id',
      );

  $$SchedulerTaskLogsTableProcessedTableManager get schedulerTaskLogsRefs {
    final manager = $$SchedulerTaskLogsTableTableManager(
      $_db,
      $_db.schedulerTaskLogs,
    ).filter((f) => f.schedulerTaskId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _schedulerTaskLogsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SchedulerTasksTableFilterComposer
    extends Composer<_$ErrandDatabase, $SchedulerTasksTable> {
  $$SchedulerTasksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startsAt => $composableBuilder(
    column: $table.startsAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextRunAt => $composableBuilder(
    column: $table.nextRunAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get repeatAfter => $composableBuilder(
    column: $table.repeatAfter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get timezone => $composableBuilder(
    column: $table.timezone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get notify => $composableBuilder(
    column: $table.notify,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastRunAt => $composableBuilder(
    column: $table.lastRunAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalRuns => $composableBuilder(
    column: $table.totalRuns,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get failures => $composableBuilder(
    column: $table.failures,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retriesPerTurn => $composableBuilder(
    column: $table.retriesPerTurn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> schedulerTaskLogsRefs(
    Expression<bool> Function($$SchedulerTaskLogsTableFilterComposer f) f,
  ) {
    final $$SchedulerTaskLogsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.schedulerTaskLogs,
      getReferencedColumn: (t) => t.schedulerTaskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SchedulerTaskLogsTableFilterComposer(
            $db: $db,
            $table: $db.schedulerTaskLogs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SchedulerTasksTableOrderingComposer
    extends Composer<_$ErrandDatabase, $SchedulerTasksTable> {
  $$SchedulerTasksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startsAt => $composableBuilder(
    column: $table.startsAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextRunAt => $composableBuilder(
    column: $table.nextRunAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get repeatAfter => $composableBuilder(
    column: $table.repeatAfter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get timezone => $composableBuilder(
    column: $table.timezone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get notify => $composableBuilder(
    column: $table.notify,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastRunAt => $composableBuilder(
    column: $table.lastRunAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalRuns => $composableBuilder(
    column: $table.totalRuns,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get failures => $composableBuilder(
    column: $table.failures,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retriesPerTurn => $composableBuilder(
    column: $table.retriesPerTurn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SchedulerTasksTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $SchedulerTasksTable> {
  $$SchedulerTasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get startsAt =>
      $composableBuilder(column: $table.startsAt, builder: (column) => column);

  GeneratedColumn<int> get nextRunAt =>
      $composableBuilder(column: $table.nextRunAt, builder: (column) => column);

  GeneratedColumn<int> get repeatAfter => $composableBuilder(
    column: $table.repeatAfter,
    builder: (column) => column,
  );

  GeneratedColumn<String> get timezone =>
      $composableBuilder(column: $table.timezone, builder: (column) => column);

  GeneratedColumn<bool> get notify =>
      $composableBuilder(column: $table.notify, builder: (column) => column);

  GeneratedColumn<int> get lastRunAt =>
      $composableBuilder(column: $table.lastRunAt, builder: (column) => column);

  GeneratedColumn<int> get totalRuns =>
      $composableBuilder(column: $table.totalRuns, builder: (column) => column);

  GeneratedColumn<int> get failures =>
      $composableBuilder(column: $table.failures, builder: (column) => column);

  GeneratedColumn<int> get retriesPerTurn => $composableBuilder(
    column: $table.retriesPerTurn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> schedulerTaskLogsRefs<T extends Object>(
    Expression<T> Function($$SchedulerTaskLogsTableAnnotationComposer a) f,
  ) {
    final $$SchedulerTaskLogsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.schedulerTaskLogs,
          getReferencedColumn: (t) => t.schedulerTaskId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$SchedulerTaskLogsTableAnnotationComposer(
                $db: $db,
                $table: $db.schedulerTaskLogs,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$SchedulerTasksTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $SchedulerTasksTable,
          SchedulerTaskRow,
          $$SchedulerTasksTableFilterComposer,
          $$SchedulerTasksTableOrderingComposer,
          $$SchedulerTasksTableAnnotationComposer,
          $$SchedulerTasksTableCreateCompanionBuilder,
          $$SchedulerTasksTableUpdateCompanionBuilder,
          (SchedulerTaskRow, $$SchedulerTasksTableReferences),
          SchedulerTaskRow,
          PrefetchHooks Function({bool schedulerTaskLogsRefs})
        > {
  $$SchedulerTasksTableTableManager(
    _$ErrandDatabase db,
    $SchedulerTasksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SchedulerTasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SchedulerTasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SchedulerTasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<int> startsAt = const Value.absent(),
                Value<int?> nextRunAt = const Value.absent(),
                Value<int?> repeatAfter = const Value.absent(),
                Value<String> timezone = const Value.absent(),
                Value<bool> notify = const Value.absent(),
                Value<int?> lastRunAt = const Value.absent(),
                Value<int> totalRuns = const Value.absent(),
                Value<int> failures = const Value.absent(),
                Value<int> retriesPerTurn = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
              }) => SchedulerTasksCompanion(
                id: id,
                title: title,
                type: type,
                status: status,
                payloadJson: payloadJson,
                startsAt: startsAt,
                nextRunAt: nextRunAt,
                repeatAfter: repeatAfter,
                timezone: timezone,
                notify: notify,
                lastRunAt: lastRunAt,
                totalRuns: totalRuns,
                failures: failures,
                retriesPerTurn: retriesPerTurn,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String title,
                required String type,
                required String status,
                required String payloadJson,
                required int startsAt,
                Value<int?> nextRunAt = const Value.absent(),
                Value<int?> repeatAfter = const Value.absent(),
                required String timezone,
                Value<bool> notify = const Value.absent(),
                Value<int?> lastRunAt = const Value.absent(),
                Value<int> totalRuns = const Value.absent(),
                Value<int> failures = const Value.absent(),
                Value<int> retriesPerTurn = const Value.absent(),
                required int createdAt,
                required int updatedAt,
              }) => SchedulerTasksCompanion.insert(
                id: id,
                title: title,
                type: type,
                status: status,
                payloadJson: payloadJson,
                startsAt: startsAt,
                nextRunAt: nextRunAt,
                repeatAfter: repeatAfter,
                timezone: timezone,
                notify: notify,
                lastRunAt: lastRunAt,
                totalRuns: totalRuns,
                failures: failures,
                retriesPerTurn: retriesPerTurn,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SchedulerTasksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({schedulerTaskLogsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (schedulerTaskLogsRefs) db.schedulerTaskLogs,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (schedulerTaskLogsRefs)
                    await $_getPrefetchedData<
                      SchedulerTaskRow,
                      $SchedulerTasksTable,
                      SchedulerTaskLogRow
                    >(
                      currentTable: table,
                      referencedTable: $$SchedulerTasksTableReferences
                          ._schedulerTaskLogsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$SchedulerTasksTableReferences(
                            db,
                            table,
                            p0,
                          ).schedulerTaskLogsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.schedulerTaskId == item.id,
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

typedef $$SchedulerTasksTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $SchedulerTasksTable,
      SchedulerTaskRow,
      $$SchedulerTasksTableFilterComposer,
      $$SchedulerTasksTableOrderingComposer,
      $$SchedulerTasksTableAnnotationComposer,
      $$SchedulerTasksTableCreateCompanionBuilder,
      $$SchedulerTasksTableUpdateCompanionBuilder,
      (SchedulerTaskRow, $$SchedulerTasksTableReferences),
      SchedulerTaskRow,
      PrefetchHooks Function({bool schedulerTaskLogsRefs})
    >;
typedef $$SchedulerTaskLogsTableCreateCompanionBuilder =
    SchedulerTaskLogsCompanion Function({
      Value<int> id,
      required int schedulerTaskId,
      required int scheduledFor,
      Value<int?> startedAt,
      Value<int?> finishedAt,
      required String status,
      Value<int> noAttempts,
      Value<String?> errorMessage,
      Value<String?> outputFilePath,
      Value<String?> summary,
      Value<int> notificationSent,
      Value<int> notificationSeen,
      required int createdAt,
      required int updatedAt,
    });
typedef $$SchedulerTaskLogsTableUpdateCompanionBuilder =
    SchedulerTaskLogsCompanion Function({
      Value<int> id,
      Value<int> schedulerTaskId,
      Value<int> scheduledFor,
      Value<int?> startedAt,
      Value<int?> finishedAt,
      Value<String> status,
      Value<int> noAttempts,
      Value<String?> errorMessage,
      Value<String?> outputFilePath,
      Value<String?> summary,
      Value<int> notificationSent,
      Value<int> notificationSeen,
      Value<int> createdAt,
      Value<int> updatedAt,
    });

final class $$SchedulerTaskLogsTableReferences
    extends
        BaseReferences<
          _$ErrandDatabase,
          $SchedulerTaskLogsTable,
          SchedulerTaskLogRow
        > {
  $$SchedulerTaskLogsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SchedulerTasksTable _schedulerTaskIdTable(_$ErrandDatabase db) => db
      .schedulerTasks
      .createAlias('scheduler_task_log__scheduler_task_id__scheduler_task__id');

  $$SchedulerTasksTableProcessedTableManager get schedulerTaskId {
    final $_column = $_itemColumn<int>('scheduler_task_id')!;

    final manager = $$SchedulerTasksTableTableManager(
      $_db,
      $_db.schedulerTasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_schedulerTaskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SchedulerTaskLogsTableFilterComposer
    extends Composer<_$ErrandDatabase, $SchedulerTaskLogsTable> {
  $$SchedulerTaskLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scheduledFor => $composableBuilder(
    column: $table.scheduledFor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get noAttempts => $composableBuilder(
    column: $table.noAttempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outputFilePath => $composableBuilder(
    column: $table.outputFilePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get notificationSent => $composableBuilder(
    column: $table.notificationSent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get notificationSeen => $composableBuilder(
    column: $table.notificationSeen,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$SchedulerTasksTableFilterComposer get schedulerTaskId {
    final $$SchedulerTasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.schedulerTaskId,
      referencedTable: $db.schedulerTasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SchedulerTasksTableFilterComposer(
            $db: $db,
            $table: $db.schedulerTasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SchedulerTaskLogsTableOrderingComposer
    extends Composer<_$ErrandDatabase, $SchedulerTaskLogsTable> {
  $$SchedulerTaskLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scheduledFor => $composableBuilder(
    column: $table.scheduledFor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get noAttempts => $composableBuilder(
    column: $table.noAttempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outputFilePath => $composableBuilder(
    column: $table.outputFilePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get notificationSent => $composableBuilder(
    column: $table.notificationSent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get notificationSeen => $composableBuilder(
    column: $table.notificationSeen,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$SchedulerTasksTableOrderingComposer get schedulerTaskId {
    final $$SchedulerTasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.schedulerTaskId,
      referencedTable: $db.schedulerTasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SchedulerTasksTableOrderingComposer(
            $db: $db,
            $table: $db.schedulerTasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SchedulerTaskLogsTableAnnotationComposer
    extends Composer<_$ErrandDatabase, $SchedulerTaskLogsTable> {
  $$SchedulerTaskLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get scheduledFor => $composableBuilder(
    column: $table.scheduledFor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get noAttempts => $composableBuilder(
    column: $table.noAttempts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  GeneratedColumn<String> get outputFilePath => $composableBuilder(
    column: $table.outputFilePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<int> get notificationSent => $composableBuilder(
    column: $table.notificationSent,
    builder: (column) => column,
  );

  GeneratedColumn<int> get notificationSeen => $composableBuilder(
    column: $table.notificationSeen,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$SchedulerTasksTableAnnotationComposer get schedulerTaskId {
    final $$SchedulerTasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.schedulerTaskId,
      referencedTable: $db.schedulerTasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SchedulerTasksTableAnnotationComposer(
            $db: $db,
            $table: $db.schedulerTasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SchedulerTaskLogsTableTableManager
    extends
        RootTableManager<
          _$ErrandDatabase,
          $SchedulerTaskLogsTable,
          SchedulerTaskLogRow,
          $$SchedulerTaskLogsTableFilterComposer,
          $$SchedulerTaskLogsTableOrderingComposer,
          $$SchedulerTaskLogsTableAnnotationComposer,
          $$SchedulerTaskLogsTableCreateCompanionBuilder,
          $$SchedulerTaskLogsTableUpdateCompanionBuilder,
          (SchedulerTaskLogRow, $$SchedulerTaskLogsTableReferences),
          SchedulerTaskLogRow,
          PrefetchHooks Function({bool schedulerTaskId})
        > {
  $$SchedulerTaskLogsTableTableManager(
    _$ErrandDatabase db,
    $SchedulerTaskLogsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SchedulerTaskLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SchedulerTaskLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SchedulerTaskLogsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> schedulerTaskId = const Value.absent(),
                Value<int> scheduledFor = const Value.absent(),
                Value<int?> startedAt = const Value.absent(),
                Value<int?> finishedAt = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> noAttempts = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<String?> outputFilePath = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int> notificationSent = const Value.absent(),
                Value<int> notificationSeen = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
              }) => SchedulerTaskLogsCompanion(
                id: id,
                schedulerTaskId: schedulerTaskId,
                scheduledFor: scheduledFor,
                startedAt: startedAt,
                finishedAt: finishedAt,
                status: status,
                noAttempts: noAttempts,
                errorMessage: errorMessage,
                outputFilePath: outputFilePath,
                summary: summary,
                notificationSent: notificationSent,
                notificationSeen: notificationSeen,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int schedulerTaskId,
                required int scheduledFor,
                Value<int?> startedAt = const Value.absent(),
                Value<int?> finishedAt = const Value.absent(),
                required String status,
                Value<int> noAttempts = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<String?> outputFilePath = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int> notificationSent = const Value.absent(),
                Value<int> notificationSeen = const Value.absent(),
                required int createdAt,
                required int updatedAt,
              }) => SchedulerTaskLogsCompanion.insert(
                id: id,
                schedulerTaskId: schedulerTaskId,
                scheduledFor: scheduledFor,
                startedAt: startedAt,
                finishedAt: finishedAt,
                status: status,
                noAttempts: noAttempts,
                errorMessage: errorMessage,
                outputFilePath: outputFilePath,
                summary: summary,
                notificationSent: notificationSent,
                notificationSeen: notificationSeen,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SchedulerTaskLogsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({schedulerTaskId = false}) {
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
                    if (schedulerTaskId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.schedulerTaskId,
                        referencedTable: $$SchedulerTaskLogsTableReferences
                            ._schedulerTaskIdTable(db),
                        referencedColumn: $$SchedulerTaskLogsTableReferences
                            ._schedulerTaskIdTable(db)
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

typedef $$SchedulerTaskLogsTableProcessedTableManager =
    ProcessedTableManager<
      _$ErrandDatabase,
      $SchedulerTaskLogsTable,
      SchedulerTaskLogRow,
      $$SchedulerTaskLogsTableFilterComposer,
      $$SchedulerTaskLogsTableOrderingComposer,
      $$SchedulerTaskLogsTableAnnotationComposer,
      $$SchedulerTaskLogsTableCreateCompanionBuilder,
      $$SchedulerTaskLogsTableUpdateCompanionBuilder,
      (SchedulerTaskLogRow, $$SchedulerTaskLogsTableReferences),
      SchedulerTaskLogRow,
      PrefetchHooks Function({bool schedulerTaskId})
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
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
  $$MemoriesTableTableManager get memories =>
      $$MemoriesTableTableManager(_db, _db.memories);
  $$SchedulerTasksTableTableManager get schedulerTasks =>
      $$SchedulerTasksTableTableManager(_db, _db.schedulerTasks);
  $$SchedulerTaskLogsTableTableManager get schedulerTaskLogs =>
      $$SchedulerTaskLogsTableTableManager(_db, _db.schedulerTaskLogs);
}
