# LineUpOS Translation System (Non-AI, Manual)
# ==============================================
# This is the OS-built translation mechanism, NOT AI-generated.
# Language packs are simple JSON maps that the UI reads at runtime.
# ==============================================

# Design Principles:
# 1. Pure structural lookup - no ML models
# 2. Language packs are simple JSON files
# 3. Added via /run/lineupos/locales/ directory
# 4. System locale configured in /etc/lineupos_locale.conf
# 5. UI components perform map lookups, not translation
# 6. Users can create custom language packs freely

# Language Pack Format (JSON):
# {
#   "ui": {
#     "welcome": "Welcome to LineUpOS",
#     "settings": "Settings",
#     "logout": "Log Out"
#   },
#   "ai": {
#     "memory": "AI Memory",
#     "runtime": "Runtime: %d MB",
#     "load": "Loading model..."
#   },
#   "system": {
#     "connected": "Connected",
#     "offline": "Offline",
#     "error": "Error"
#   }
# }

# How It Works at Runtime:
# -----------------------
# 1. At boot, Kernel reads /etc/lineupos_locale.conf
#    Example content: "locale": "en-US"
# 2. The C# Shell (powerup.js) loads the corresponding JSON from /run/lineupos/locales/{locale}.json
# 3. UI text elements perform: translations[key] || fallback[key] || key
# 4. If key not found, the key name itself is displayed (transparency)
# 5. No AI/ML involved - pure JavaScript object lookup

# Adding a New Language Pack:
# --------------------------
# 1. Create: /run/lineupos/locales/pt-BR.json
# 2. Configure: echo "locale: pt-BR" >> /etc/lineupos_locale.conf
# 3. Reboot or reload UI
# 4. UI automatically uses new translations
#
# Example pt-BR.json:
# {
#   "ui": {
#     "welcome": "Bem-vindo ao LineUpOS",
#     "loading": "Carregando...",
#     "error": "Ocorreu um erro"
#   },
#   "ai": {
#     "memory": "Memória AI",
#     "budget": "Orçamento: %d MB"
#   }
# }

# Supported Locales (built-in):
# - en-US (default, English)
# - pt-BR (Brazil Portuguese - user-added)
# - ja-JP (Japan - user-added)
# - de-DE (Germany - user-added)
# etc.

# Technical Constraints:
# ---------------------
# - No runtime AI/ML inference
# - No external API calls
# - No network required after locale load
# - Memory overhead: ~2KB per language pack
# - Load time: < 1ms on modern hardware
# - All text is transparently fallible (key displayed if missing)

# Integration with powerup.js:
# ---------------------------
# In the UI components, translation looks like:
# const t = (key, ...args) => {
#   const map = window.LineUpLocale || {};
#   const value = map[key] || key;
#   return args.length ? value.replace(/%s/g, args) : value;
# };
# 
# Usage in JSX/TSX:
# <div>{t('welcome')}</div>
# <div>{t('ai.budget', 732)}</div>

# This system ensures:
# ✅ Zero AI/ML usage at runtime
# ✅ Users control their language packs
# ✅ Zero cost for adding new languages
# ✅ Transparent - missing keys display the key name
# ✅ Performance: pure object lookup, no parsing