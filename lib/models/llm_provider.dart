import 'model_option.dart';

class LlmProvider {
  final String id;
  final String name;
  final String baseUrl;
  final String? apiKey;
  final bool isDefault;
  final bool isPreset;
  final List<String> customModels;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LlmProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey,
    this.isDefault = false,
    this.isPreset = false,
    this.customModels = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasKey => apiKey != null && apiKey!.trim().isNotEmpty;

  List<ModelOption> get defaultModels {
    for (final preset in ProviderPresetType.values) {
      if (preset.id == id) return preset.fallbackModels;
    }
    return ProviderPresetType.byok.fallbackModels;
  }

  String get defaultBaseUrl {
    for (final preset in ProviderPresetType.values) {
      if (preset.id == id) return preset.defaultBaseUrl;
    }
    return ProviderPresetType.byok.defaultBaseUrl;
  }

  LlmProvider copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
    bool? isDefault,
    bool? isPreset,
    List<String>? customModels,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return LlmProvider(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      isDefault: isDefault ?? this.isDefault,
      isPreset: isPreset ?? this.isPreset,
      customModels: customModels ?? this.customModels,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'isDefault': isDefault,
    'isPreset': isPreset,
    'customModels': customModels,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory LlmProvider.fromJson(Map<String, dynamic> json, {String? apiKey}) {
    return LlmProvider(
      id: json['id'] as String,
      name: json['name'] as String,
      baseUrl: json['baseUrl'] as String,
      apiKey: apiKey,
      isDefault: json['isDefault'] as bool? ?? false,
      isPreset: json['isPreset'] as bool? ?? false,
      customModels: (json['customModels'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// The 4 presets requested: OpenCode Zen, OpenRouter, Groq, and BYOK (Custom).
enum ProviderPresetType {
  openCodeZen,
  openRouter,
  groq,
  byok;

  String get id {
    switch (this) {
      case ProviderPresetType.openCodeZen:
        return 'opencode_zen';
      case ProviderPresetType.openRouter:
        return 'openrouter';
      case ProviderPresetType.groq:
        return 'groq';
      case ProviderPresetType.byok:
        return 'byok';
    }
  }

  String get displayName {
    switch (this) {
      case ProviderPresetType.openCodeZen:
        return 'OpenCode Zen';
      case ProviderPresetType.openRouter:
        return 'OpenRouter';
      case ProviderPresetType.groq:
        return 'Groq';
      case ProviderPresetType.byok:
        return 'BYOK (Custom)';
    }
  }

  String get defaultBaseUrl {
    switch (this) {
      case ProviderPresetType.openCodeZen:
        return 'https://opencode.ai/zen/v1';
      case ProviderPresetType.openRouter:
        return 'https://openrouter.ai/api/v1';
      case ProviderPresetType.groq:
        return 'https://api.groq.com/openai/v1';
      case ProviderPresetType.byok:
        return 'https://api.openai.com/v1';
    }
  }

  String get keyHint {
    switch (this) {
      case ProviderPresetType.openCodeZen:
        return 'Bearer token';
      case ProviderPresetType.openRouter:
        return 'sk-or-v1-…';
      case ProviderPresetType.groq:
        return 'gsk_…';
      case ProviderPresetType.byok:
        return 'API key or token';
    }
  }

  List<ModelOption> get fallbackModels {
    switch (this) {
      case ProviderPresetType.openCodeZen:
        return const [
          ModelOption(
            id: 'claude-3-5-sonnet',
            name: 'Claude 3.5 Sonnet',
            provider: 'OpenCode Zen',
            inputModalities: ['text', 'image'],
          ),
          ModelOption(
            id: 'gpt-4o',
            name: 'GPT-4o',
            provider: 'OpenCode Zen',
            inputModalities: ['text', 'image'],
          ),
          ModelOption(
            id: 'deepseek-chat',
            name: 'DeepSeek V3',
            provider: 'OpenCode Zen',
            inputModalities: ['text'],
          ),
        ];
      case ProviderPresetType.openRouter:
        return const [
          ModelOption(
            id: 'anthropic/claude-3.7-sonnet',
            name: 'Claude 3.7 Sonnet',
            provider: 'Anthropic',
            inputModalities: ['text', 'image'],
          ),
          ModelOption(
            id: 'openai/gpt-4o',
            name: 'GPT-4o',
            provider: 'OpenAI',
            inputModalities: ['text', 'image'],
          ),
          ModelOption(
            id: 'google/gemini-2.0-flash-001',
            name: 'Gemini 2.0 Flash',
            provider: 'Google',
            inputModalities: ['text', 'image', 'audio', 'video'],
          ),
          ModelOption(
            id: 'meta-llama/llama-3.3-70b-instruct',
            name: 'Llama 3.3 70B Instruct',
            provider: 'Meta',
            inputModalities: ['text'],
          ),
        ];
      case ProviderPresetType.groq:
        return const [
          ModelOption(
            id: 'llama-3.3-70b-versatile',
            name: 'Llama 3.3 70B Versatile',
            provider: 'Groq',
            inputModalities: ['text'],
          ),
          ModelOption(
            id: 'llama-3.1-8b-instant',
            name: 'Llama 3.1 8B Instant',
            provider: 'Groq',
            inputModalities: ['text'],
          ),
          ModelOption(
            id: 'mixtral-8x7b-32768',
            name: 'Mixtral 8x7B 32k',
            provider: 'Groq',
            inputModalities: ['text'],
          ),
        ];
      case ProviderPresetType.byok:
        return const [
          ModelOption(
            id: 'gpt-4o',
            name: 'GPT-4o',
            provider: 'OpenAI',
            inputModalities: ['text', 'image'],
          ),
          ModelOption(
            id: 'gpt-4o-mini',
            name: 'GPT-4o mini',
            provider: 'OpenAI',
            inputModalities: ['text', 'image'],
          ),
        ];
    }
  }

  LlmProvider createProvider({String? apiKey, bool isDefault = false}) {
    final now = DateTime.now();
    return LlmProvider(
      id: id,
      name: displayName,
      baseUrl: defaultBaseUrl,
      apiKey: apiKey,
      isDefault: isDefault,
      isPreset: true,
      createdAt: now,
      updatedAt: now,
    );
  }
}
