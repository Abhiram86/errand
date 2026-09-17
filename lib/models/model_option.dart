import '../services/models_dev_service.dart';

class ModelOption {
  final String id;
  final String name;
  final String provider;

  /// Input modalities the model accepts, from OpenRouter's
  /// `architecture.input_modalities`: e.g. ["text", "image", "audio", "video",
  /// "file"]. May be absent for non-OpenRouter endpoints — treat unknown as
  /// "not claimed" rather than "unsupported".
  final List<String> inputModalities;

  /// Whether the catalog response had an explicit architecture modalities list.
  final bool hasExplicitModalities;

  /// Native context window limit in tokens (e.g. 128000, 200000, 1048576).
  final int? contextLength;

  /// Release or last-updated date of the model.
  final DateTime? releaseDate;

  /// Effective release date, falling back to dynamic lookup via [ModelsDevService].
  DateTime? get effectiveReleaseDate =>
      releaseDate ?? ModelsDevService.lookupReleaseDate(id);

  bool? checkModality(String modality) {
    if (inputModalities.contains(modality)) return true;
    if (hasExplicitModalities) return false;
    return null; // Unknown / unverified
  }

  bool supportsInput(String modality) => inputModalities.contains(modality);

  const ModelOption({
    required this.id,
    required this.name,
    required this.provider,
    this.inputModalities = const ['text'],
    this.hasExplicitModalities = false,
    this.contextLength,
    this.releaseDate,
  });

  ModelOption copyWith({
    String? id,
    String? name,
    String? provider,
    List<String>? inputModalities,
    bool? hasExplicitModalities,
    int? contextLength,
    DateTime? releaseDate,
  }) {
    return ModelOption(
      id: id ?? this.id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      inputModalities: inputModalities ?? this.inputModalities,
      hasExplicitModalities: hasExplicitModalities ?? this.hasExplicitModalities,
      contextLength: contextLength ?? this.contextLength,
      releaseDate: releaseDate ?? this.releaseDate,
    );
  }

  /// Compares two [ModelOption]s by release date (newest first).
  ///
  /// If release dates are equal or both missing, falls back to alphabetical name order.
  static int compareByReleaseDate(ModelOption a, ModelOption b) {
    final dateA = a.effectiveReleaseDate;
    final dateB = b.effectiveReleaseDate;
    if (dateA != null && dateB != null) {
      final cmp = dateB.compareTo(dateA); // Descending (newest first)
      if (cmp != 0) return cmp;
    } else if (dateA != null) {
      return -1;
    } else if (dateB != null) {
      return 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider,
    'inputModalities': inputModalities,
    'hasExplicitModalities': hasExplicitModalities,
    if (contextLength != null) 'contextLength': contextLength,
    if (releaseDate != null) 'releaseDate': releaseDate!.toIso8601String(),
  };

  factory ModelOption.fromJson(Map<String, dynamic> json) => ModelOption(
    id: json['id'] as String,
    name: json['name'] as String,
    provider: json['provider'] as String? ?? '',
    inputModalities: (json['inputModalities'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['text'],
    hasExplicitModalities: json['hasExplicitModalities'] as bool? ?? false,
    contextLength: (json['contextLength'] as num?)?.toInt(),
    releaseDate: json['releaseDate'] != null
        ? DateTime.tryParse(json['releaseDate'] as String)
        : null,
  );
}

const kDefaultModelId = 'openrouter/free';

// Used immediately on launch and whenever the model endpoint is unavailable.
// The live catalog normally replaces this list after startup.
const kFallbackModels = <ModelOption>[
  ModelOption(
    id: 'openrouter/free',
    name: 'Free Models',
    provider: 'OpenRouter',
    inputModalities: ['text', 'image'],
    hasExplicitModalities: true,
    contextLength: 200000,
  ),
  ModelOption(
    id: 'openai/gpt-5.6-luna',
    name: 'GPT-5.6 Luna',
    provider: 'OpenAI',
    inputModalities: ['text', 'image'],
    hasExplicitModalities: true,
    contextLength: 1050000,
  ),
  ModelOption(
    id: 'deepseek/deepseek-v4-flash-0731',
    name: 'DeepSeek V4 Flash',
    provider: 'DeepSeek',
    inputModalities: ['text'],
    hasExplicitModalities: true,
    contextLength: 1310720,
  ),
  ModelOption(
    id: 'z-ai/glm-5.3-flash',
    name: 'GLM 5.3 Flash',
    provider: 'Z.ai',
    inputModalities: ['text', 'image', 'video'],
    hasExplicitModalities: true,
    contextLength: 1048576,
  ),
];
