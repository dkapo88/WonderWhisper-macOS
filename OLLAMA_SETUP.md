# Ollama Integration Guide

## Overview

WonderWhisper Mac now supports using local Ollama LLM models for post-transcription text processing. This allows you to use your locally-running Ollama models without any API keys or cloud dependencies.

## Prerequisites

1. **Ollama installed and running**: Make sure Ollama is installed on your Mac and running
2. **Models downloaded**: Download the Ollama models you want to use

## Quick Start

### 1. Verify Ollama is Running

Check that Ollama is running by opening Terminal and running:

```bash
ollama list
```

This should show you all the models you have downloaded. If Ollama isn't running, start it with:

```bash
ollama serve
```

### 2. Download a Model (if needed)

To download a model, use:

```bash
# Example: Download llama3.2
ollama pull llama3.2

# Other popular models:
ollama pull mistral
ollama pull phi3
ollama pull gemma2
```

### 3. Configure WonderWhisper

In the WonderWhisper settings:

1. Go to **Settings → Models**
2. Set **LLM Provider** to `Ollama (Local)`
3. Your locally installed models will automatically appear in the **LLM model** dropdown
4. Select your preferred model from the list
5. The endpoint is automatically configured to `http://localhost:11434/api/chat`

**Note**: The app automatically detects your installed Ollama models. If no models appear, click the **Refresh** button or ensure Ollama is running.

## Supported Features

✅ **Automatic model detection**: App automatically discovers your installed Ollama models
✅ **Streaming**: Real-time token-by-token responses for faster perceived performance
✅ **Non-streaming**: Full response at once
✅ **Image attachments**: Vision models (e.g., `llava`) can process screen captures
✅ **Context support**: All screen context, vocabulary, and clipboard features work
✅ **No API key required**: Ollama runs locally without authentication
✅ **No manual configuration**: Just select your model from the dropdown - no typing needed!

## Model Recommendations

### For Speed
- `llama3.2:1b` - Fastest, good for simple formatting
- `phi3:mini` - Fast and efficient

### For Quality
- `llama3.2` - Best balance of speed and quality
- `mistral` - Excellent instruction following
- `gemma2` - Great for creative tasks

### For Vision (Screen Context)
- `llava` - Image + text understanding
- `llava-phi3` - Faster vision model

## Advanced Configuration

### Custom Ollama Port

If you're running Ollama on a non-default port, you can modify the endpoint in the code:

Edit `AppConfig.swift` and change:
```swift
private static let ollamaBaseString = "http://localhost:YOUR_PORT/api"
```

### Temperature Control

The default temperature is set to 0.2 for consistent output. This is configured in `OllamaLLMProvider.swift`.

### Timeout Settings

The default timeout uses your configured transcription timeout setting (typically 60-120 seconds).

## Troubleshooting

### First dictation is slow or times out
**This is normal!** The first time you use a model:
- Ollama loads the model into memory (can take 30-60 seconds for large models)
- Subsequent requests are much faster (1-2 seconds)
- The app now uses a **3-minute timeout** for Ollama to handle this

**Tips:**
- Use smaller models like `llama3.2:1b` or `phi3:mini` for faster responses
- After first load, the model stays in memory and responds quickly
- If timing out frequently, your model may be too large for your system

### Ollama not responding
If you see connection errors:
1. Check if Ollama is running: `ollama list`
2. Start Ollama: `ollama serve`
3. Verify the model is installed: `ollama list`

### Model not appearing in UI
1. Make sure Ollama is running
2. Click the **Refresh** button in Settings → Models
3. Check that models are properly installed with `ollama list`

### Slow performance

**Solutions**:
1. Use a smaller model (e.g., `llama3.2:1b` instead of `llama3.2:70b`)
2. Enable streaming for faster perceived performance
3. Ensure you have enough RAM for the model

### Model keeps getting unloaded

By default, Ollama unloads models after 5 minutes of inactivity. To keep a model loaded:
```bash
# Set keep_alive to a longer duration
ollama run llama3.2 --keep-alive 1h
```

## Performance Tips

1. **Pre-load models**: Run `ollama run <model-name>` before using WonderWhisper to pre-load the model into memory
2. **Use streaming**: Enable streaming in settings for faster first-token time
3. **Monitor resources**: Use Activity Monitor to ensure you have enough RAM for your chosen model
4. **Model size matters**: Larger models (70B) require significantly more RAM and are slower than smaller models (7B, 3B, 1B)

## Technical Details

### Implementation

The Ollama integration consists of:
- `OllamaHTTPClient.swift` - HTTP client for Ollama API communication
- `OllamaLLMProvider.swift` - LLM provider implementation
- Configuration in `AppConfig.swift` and `DictationViewModel.swift`

### API Endpoint

Uses Ollama's `/api/chat` endpoint with OpenAI-compatible message format:
```
POST http://localhost:11434/api/chat
```

### Message Format

Follows the standard chat completion format:
```json
{
  "model": "llama3.2",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "temperature": 0.2,
  "stream": true
}
```

## Example Usage

1. Start dictation with your hotkey
2. Speak your text
3. Release the hotkey
4. Ollama processes the transcription using your configured model
5. The formatted text is inserted into your application

The entire process happens locally on your Mac - no data leaves your machine!
