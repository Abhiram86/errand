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
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider,
    'inputModalities': inputModalities,
    'hasExplicitModalities': hasExplicitModalities,
    if (contextLength != null) 'contextLength': contextLength,
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
  );
}

const kDefaultModelId = 'anthropic/claude-3.7-sonnet';

// Used immediately on launch and whenever the model endpoint is unavailable.
// The live catalog normally replaces this list after startup.
const kFallbackModels = <ModelOption>[
  ModelOption(
    id: 'anthropic/claude-3.7-sonnet',
    name: 'Claude 3.7 Sonnet',
    provider: 'Anthropic',
    inputModalities: ['text', 'image'],
    hasExplicitModalities: true,
    contextLength: 200000,
  ),
  ModelOption(
    id: 'openai/gpt-4o',
    name: 'GPT-4o',
    provider: 'OpenAI',
    inputModalities: ['text', 'image'],
    hasExplicitModalities: true,
    contextLength: 128000,
  ),
  ModelOption(
    id: 'google/gemini-2.0-flash-001',
    name: 'Gemini 2.0 Flash',
    provider: 'Google',
    inputModalities: ['text', 'image', 'audio', 'video'],
    hasExplicitModalities: true,
    contextLength: 1048576,
  ),
  ModelOption(
    id: 'meta-llama/llama-3.3-70b-instruct',
    name: 'Llama 3.3 70B Instruct',
    provider: 'Meta',
    inputModalities: ['text'],
    hasExplicitModalities: true,
    contextLength: 128000,
  ),
];
