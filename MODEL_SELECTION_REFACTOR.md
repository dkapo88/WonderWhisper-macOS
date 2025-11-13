# OpenRouter Model Selection Refactor

## Summary
Completely refactored the model selection system for OpenRouter to use a favorites-based approach with model browsing, searching, and discovery.

## Changes Made

### 1. New Data Models (`OpenRouterModel.swift`)
- **OpenRouterModel**: Full model data including name, description, pricing, and context length
- **FavoriteOpenRouterModel**: Simplified favorite tracking with id, name, and timestamp
- **OpenRouterModelsResponse**: API response wrapper

### 2. Updated API Client (`OpenRouterHTTPClient.swift`)
- Added `fetchModels()` method to retrieve full model information from OpenRouter API
- Returns structured data including:
  - Model ID and display name
  - Description
  - Pricing (prompt/completion costs)
  - Context length
  - Architecture details

### 3. Model Browser View (`OpenRouterModelBrowserView.swift`)
A new full-featured model browser with:
- **Search**: Real-time fuzzy search across model IDs, names, and descriptions
- **Sorting**: Sort by name, cost, or context length
- **Favorites**: Star/unstar models directly from the browser
- **Detailed Info**: View pricing, context length, and descriptions
- **Visual Feedback**: Clear indicators for favorited models

### 4. ViewModel Updates (`DictationViewModel.swift`)
Added favorites management methods:
- `addFavoriteOpenRouterModel(id:name:)` - Add model to favorites
- `removeFavoriteOpenRouterModel(id:)` - Remove from favorites
- `setActiveOpenRouterModel(id:)` - Set active model
- `favoriteOpenRouterModels` - Published array of favorites
- Persistent storage using UserDefaults with JSON encoding

### 5. Settings UI Refactor (`SimpleModeSettingsView.swift`)
**Removed:**
- Custom model ID text input field
- Manual "Add" button for models
- Simple list of custom models
- Dropdown picker for model selection
- Separate "Model management" section

**Added:**
- Combined "Language model" section with:
  - LLM post-processing toggle at the top
  - "Browse Models" button to open the model browser
  - Clickable list of favorited models
  - Click any model to set it as active (no separate button needed)
  - Delete button for each favorite
  - Visual indicator (green checkmark) showing active model
  - Green background highlight for active model
  - Helpful message when no favorites exist

## User Flow

1. **First Time Setup**:
   - User sees "No favorites yet" message in Language model section
   - Clicks "Browse Models" button
   - Searches/browses OpenRouter catalog (400+ models)
   - Stars models to add to favorites

2. **Selecting Active Model**:
   - View all favorites in Settings → Language model
   - See model ID and name for each favorite
   - **Click any favorite to set it as active** (instant switch)
   - Active model shows green checkmark and highlighted background
   - Remove unwanted favorites with trash icon

3. **Browsing Models**:
   - Search by name, ID, or description
   - Sort by name, cost, or context length
   - View pricing and context info for each model
   - Add/remove favorites with star button
   - See count of available models at top

## Benefits

- **No manual typing**: Users browse and select from verified OpenRouter models
- **Discovery**: Users can explore all 400+ available models with full metadata
- **Streamlined UX**: Click to activate, no separate dropdown or buttons
- **Clear visual feedback**: Green highlight and checkmark for active model
- **Accurate data**: Pricing and context length shown directly from API
- **Flexible**: Easy to add/remove favorites as needs change
- **Persistent**: Favorites saved across app restarts
- **Unified interface**: One section for all model management instead of two separate sections

## Technical Notes

- Favorites stored in UserDefaults as JSON under `simple.openrouter.favorites`
- Model browser fetches fresh data from OpenRouter API each time
- Fallback to default model if all favorites removed
- Auto-selects first favorite if active model is removed
- Case-insensitive model ID comparisons throughout
