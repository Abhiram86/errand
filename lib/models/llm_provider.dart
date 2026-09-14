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
    return const [];
  }

  String get defaultBaseUrl {
    for (final preset in ProviderPresetType.values) {
      if (preset.id == id) return preset.defaultBaseUrl;
    }
    return '';
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

/// The default presets: OpenRouter, NVIDIA, and Groq.
enum ProviderPresetType {
  openRouter,
  nvidia,
  groq;

  String get id {
    switch (this) {
      case ProviderPresetType.openRouter:
        return 'openrouter';
      case ProviderPresetType.nvidia:
        return 'nvidia';
      case ProviderPresetType.groq:
        return 'groq';
    }
  }

  String get displayName {
    switch (this) {
      case ProviderPresetType.openRouter:
        return 'OpenRouter';
      case ProviderPresetType.nvidia:
        return 'NVIDIA';
      case ProviderPresetType.groq:
        return 'Groq';
    }
  }

  String get defaultBaseUrl {
    switch (this) {
      case ProviderPresetType.openRouter:
        return 'https://openrouter.ai/api/v1';
      case ProviderPresetType.nvidia:
        return 'https://integrate.api.nvidia.com/v1';
      case ProviderPresetType.groq:
        return 'https://api.groq.com/openai/v1';
    }
  }

  String get keyHint {
    switch (this) {
      case ProviderPresetType.openRouter:
        return 'sk-or-v1-…';
      case ProviderPresetType.nvidia:
        return 'nvapi-…';
      case ProviderPresetType.groq:
        return 'gsk_…';
    }
  }

  List<ModelOption> get fallbackModels {
    switch (this) {
      case ProviderPresetType.openRouter:
        return kFallbackModels;
      case ProviderPresetType.nvidia:
        return const [
          ModelOption(
            id: 'meta/llama-3.3-70b-instruct',
            name: 'Llama 3.3 70B Instruct',
            provider: 'NVIDIA',
            inputModalities: ['text'],
            contextLength: 131072,
          ),
          ModelOption(
            id: 'nvidia/llama-3.1-nemotron-70b-instruct',
            name: 'Nemotron 70B Instruct',
            provider: 'NVIDIA',
            inputModalities: ['text'],
            contextLength: 131072,
          ),
          ModelOption(
            id: 'deepseek-ai/deepseek-r1',
            name: 'DeepSeek R1',
            provider: 'NVIDIA',
            inputModalities: ['text'],
            contextLength: 131072,
          ),
        ];
      case ProviderPresetType.groq:
        return const [
          ModelOption(
            id: 'llama-3.3-70b-versatile',
            name: 'Llama 3.3 70B Versatile',
            provider: 'Groq',
            inputModalities: ['text'],
            contextLength: 128000,
          ),
          ModelOption(
            id: 'llama-3.1-8b-instant',
            name: 'Llama 3.1 8B Instant',
            provider: 'Groq',
            inputModalities: ['text'],
            contextLength: 128000,
          ),
          ModelOption(
            id: 'mixtral-8x7b-32768',
            name: 'Mixtral 8x7B 32k',
            provider: 'Groq',
            inputModalities: ['text'],
            contextLength: 32768,
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
