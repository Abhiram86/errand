import 'dart:convert';

/// A structured user memory stored persistently across conversations.
class UserMemory {
  final String id;
  final String about;
  final String description;
  final List<String> keywords;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? sourceConversationId;

  const UserMemory({
    required this.id,
    required this.about,
    required this.description,
    required this.keywords,
    required this.createdAt,
    required this.updatedAt,
    this.sourceConversationId,
  });

  /// Model-facing full representation for `memory.read`.
  Map<String, dynamic> toModelJson() => {
    'id': id,
    'about': about,
    'description': description,
    'keywords': keywords,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  /// Serializes to JSON including internal fields.
  Map<String, dynamic> toJson() => {
    'id': id,
    'about': about,
    'description': description,
    'keywords': keywords,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    if (sourceConversationId != null)
      'source_conversation_id': sourceConversationId,
  };

  factory UserMemory.fromJson(Map<String, dynamic> json) {
    List<String> parseKeywords(dynamic raw) {
      if (raw is List) {
        return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      } else if (raw is String) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            return decoded.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
          }
        } catch (_) {}
      }
      return const [];
    }

    return UserMemory(
      id: json['id'] as String,
      about: json['about'] as String,
      description: json['description'] as String,
      keywords: parseKeywords(json['keywords']),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      sourceConversationId: json['source_conversation_id'] as String?,
    );
  }

  UserMemory copyWith({
    String? id,
    String? about,
    String? description,
    List<String>? keywords,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? sourceConversationId,
  }) {
    return UserMemory(
      id: id ?? this.id,
      about: about ?? this.about,
      description: description ?? this.description,
      keywords: keywords ?? this.keywords,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceConversationId:
          sourceConversationId ?? this.sourceConversationId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserMemory &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          about == other.about &&
          description == other.description &&
          _listEquals(keywords, other.keywords) &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          sourceConversationId == other.sourceConversationId;

  @override
  int get hashCode =>
      id.hashCode ^
      about.hashCode ^
      description.hashCode ^
      Object.hashAll(keywords) ^
      createdAt.hashCode ^
      updatedAt.hashCode ^
      sourceConversationId.hashCode;

  @override
  String toString() =>
      'UserMemory(id: $id, about: $about, keywords: $keywords, updated: $updatedAt)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Lightweight candidate result returned by `memory.find`.
class MemoryFindResult {
  final String id;
  final String about;

  const MemoryFindResult({
    required this.id,
    required this.about,
  });

  Map<String, String> toJson() => {
    'id': id,
    'about': about,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryFindResult &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          about == other.about;

  @override
  int get hashCode => id.hashCode ^ about.hashCode;

  @override
  String toString() => 'MemoryFindResult(id: $id, about: $about)';
}
