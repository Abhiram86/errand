class ModelOption {
  final String id;
  final String name;
  final String provider;

  /// Input modalities the model accepts, from OpenRouter's
  /// `architecture.input_modalities`: e.g. ["text", "image", "audio", "video",
  /// "file"]. May be absent for non-OpenRouter endpoints — treat unknown as
  /// "not claimed" rather than "unsupported".
  final List<String> inputModalities;

  bool supportsInput(String modality) => inputModalities.contains(modality);

  const ModelOption({
    required this.id,
    required this.name,
    required this.provider,
    this.inputModalities = const ['text'],
  });
}

const kDefaultModelId = 'nvidia/nemotron-3-ultra-550b-a55b:free';
// Used immediately on launch and whenever the model endpoint is unavailable.
// The live catalog normally replaces this list after startup.
const kFallbackModels = <ModelOption>[
  ModelOption(id: kDefaultModelId, name: 'Nemotron Ultra', provider: 'NVIDIA'),
  ModelOption(
    id: 'openai/gpt-4o-mini',
    name: 'GPT-4o mini',
    provider: 'OpenAI',
  ),
  ModelOption(
    id: 'anthropic/claude-3.5-sonnet',
    name: 'Claude 3.5 Sonnet',
    provider: 'Anthropic',
  ),
  ModelOption(
    id: 'google/gemini-2.0-flash-001',
    name: 'Gemini 2.0 Flash',
    provider: 'Google',
  ),
];

