# Handy Flutter

Handy is a Flutter chat client with a small on-device agent loop. The current
runtime supports two file tools: `list` and bounded `read` for text, PDF, DOCX,
XLSX, and PPTX files.

## Run with local environment

Flutter does not load `.env` files automatically. Start the app with:

```bash
flutter run --dart-define-from-file=.env
```

The local `.env` file should define:

```text
OPENROUTER_API_KEY=...
HANDY_BASE_URL=https://openrouter.ai/api/v1
HANDY_MODEL=openai/gpt-4o-mini
```

`HANDY_BASE_URL` and `HANDY_MODEL` are optional. The app defaults to OpenRouter
and `openai/gpt-4o-mini`.

On Android, the app currently requests all-files access and reads paths under
`/storage/emulated/0`. The agent refuses absolute paths outside its injected
workspace.

Run the test suite with:

```bash
flutter test
```
