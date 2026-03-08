# ⚡️ LuaBoost v1.3.0 (WotLK 3.3.5a)

**Lua runtime optimizer + SmartGC + SpeedyLoad + UI Thrashing Protection for World of Warcraft 3.3.5a (build 12340)**  
Author: **Suprematist**

LuaBoost improves addon performance by eliminating GC stutter with per-frame incremental garbage collection, speeding up loading screens by suppressing noisy events, and preventing redundant UI widget updates across all addons. 

Designed for **Warmane** and other 3.3.5a servers.

---

## 🆕 What's New in v1.3.0

| Feature | Description |
|---------|-------------|
| **UI Thrashing Protection** | Automatically caches widget values and skips redundant engine calls. Speeds up all addons that update UI every frame. Zero configuration needed. |
| **Safe StatusBar Hooks** | Hooks `SetValue`, `SetMinMaxValues`, and `SetStatusBarColor`. 100% safe from Blizzard Dropdown Menu taint. FontString hooks were removed to prevent interaction issues with secure frames. |
| **Runtime Toggle** | Use `/lb tg toggle` to enable/disable at runtime without reloading the UI. Check live stats via `/lb tg`. |

*(For older changes like Taint-Free optimizations and SpeedyLoad, see previous releases).*

---

## 🌍 Localization / Credits

- **English (`enUS`)**: Default
- **Korean (`koKR`)**: Translated and optimized by [**nadugi**](https://github.com/nadugi)

*If you want to translate LuaBoost to your language, feel free to submit a Pull Request! Just copy `enUS.lua`, rename it to your locale (e.g., `ruRU.lua`), translate the strings, and add it to `!LuaBoost.toc`.*

---

## ✅ Features

### 🛡️ UI Thrashing Protection (NEW in v1.3.0)
Poorly written addons call UI methods every single frame even when the value hasn't changed (e.g., `HealthBar:SetValue(45000)` 60 times a second). 

LuaBoost hooks widget metatable methods globally and caches the last value. If the new value is identical, the engine call is **completely skipped** — saving bar fill recomputation and CPU cycles.

**Hooked methods (100% Taint-Free):**
- `StatusBar:SetValue`
- `StatusBar:SetMinMaxValues`
- `StatusBar:SetStatusBarColor`

*Note: FontString and Texture methods are intentionally NOT hooked because modifying them causes "Action Blocked" taint errors with Blizzard's secure dropdown menus, or desyncs C++ engine animations.*

### Safe Runtime Optimizations (automatic, always active)
- `GetTimeCached()` — cached `GetTime()` value updated once per frame
- `LuaBoost_Throttle(id, interval)` — shared throttle helper for any addon
- Table pool: `LuaBoost_AcquireTable()` / `LuaBoost_ReleaseTable(t)` / `LuaBoost_GetPoolStats()`
- `GetDateCached(fmt)` — opt-in cached date helper (does **not** replace global `date()`)

### Smart GC Manager (configurable)
- Stops Lua auto-GC and performs **incremental GC steps every frame**
- **4-tier stepping**: loading → combat → idle → normal
  - **Loading**: aggressive cleanup (no rendering happening anyway)
  - **Combat**: minimal GC to protect frametime
  - **Idle**: aggressive cleanup while AFK
  - **Normal**: balanced stepping
- Emergency full GC when Lua memory exceeds threshold (outside combat)
- GC burst on heavy events (boss kill, LFG popup, achievement, loot spam)
- **3 presets**: Light / Standard / Heavy — pick based on your addon load
- GUI: `ESC → Interface → AddOns → LuaBoost`

### SpeedyLoad — Fast Loading Screens
- Temporarily suppresses noisy events during loading screens
- Restores all events after loading completes (with event replay)
- **Two modes**:
  - **Safe** (11 events) — cosmetic events only, no risk
  - **Aggressive** (23 events) — includes actionbar/aura/inventory events, faster but slightly more aggressive

### Protection Hooks (optional, OFF by default)
- **Intercept `collectgarbage()`** — blocks other addons from forcing full GC spikes
- **Block `UpdateAddOnMemoryUsage()`** — prevents CPU spikes from frequent memory scans

---

## 🔧 Recommended Optimization Ecosystem

For maximum client performance, use all three of my optimization projects together:

| Layer | Tool | What It Does |
|-------|------|--------------|
| **C / Engine** | [wow_optimize.dll](https://github.com/suprepupre/wow-optimize) | Faster memory allocator (mimalloc), network optimization (TCP_NODELAY), precision timers, Lua GC from C, combat log pool fix. |
| **Lua / Runtime** | **!LuaBoost** | Smart GC, SpeedyLoad, UI Thrashing Protection, table pool, throttle API. |
| **Lua / Source** | [LuaBoost Localizer](https://github.com/suprepupre/luaboost-localizer) | Automatic global-to-local (`local GetTime = GetTime`) optimizer utility for all your downloaded addons. Run it once in your AddOns folder. |

When the DLL and !LuaBoost addon are both installed, they communicate automatically. The DLL handles GC stepping from C (zero Lua overhead), and the addon handles combat awareness and GUI.

---

## ⚙️ Settings Reference

Open settings: `ESC → Interface → AddOns → LuaBoost → GC Settings`

### Step Sizes — KB collected per frame

| Setting | What it does | Increase if... | Decrease if... |
|---------|-------------|----------------|----------------|
| **Normal Step** | GC work per frame during regular gameplay | Memory climbs over time; you see gradual FPS degradation | You want minimal CPU overhead; you have very few addons |
| **Combat Step** | GC work per frame **during combat**. | You get a **big freeze after boss kills** (garbage accumulated during combat) | Combat FPS is unstable; you're CPU-limited |
| **Idle Step** | GC work per frame while AFK/idle | Memory stays high even while AFK | Not important — idle mode uses zero rendering resources |
| **Loading Step** | GC work per frame during loading screens | Loading screens feel slow | Not important — no rendering during loading |

### Presets Comparison

| Setting | Light (<150MB) | Standard (150-300MB) | Heavy (>300MB) |
|---------|------|-----|--------|
| Normal Step (KB/f) | 20 | 50 | 100 |
| Combat Step (KB/f) | 5 | 15 | 30 |
| Idle Step (KB/f) | 80 | 150 | 300 |
| Loading Step (KB/f) | 150 | 300 | 500 |
| Emergency GC (MB) | 150 | 300 | 500 |
| Idle Timeout (sec) | 15 | 15 | 20 |

---

## 🔧 Fixing Freezes After Boss Kills / Dungeon Queue Pops

**Symptom:** A 5–10 second freeze right after killing a boss, leaving combat, or when a dungeon queue pops.

**Cause:** When you fight a boss, Lua memory spikes rapidly. When combat ends, the Emergency Full GC triggers because memory exceeded the threshold, causing a **full garbage collection** that blocks the entire game.

### Quick Fix
Open settings (`/lb settings`) and click the **Heavy (> 300MB)** preset.

### Manual Fix
1. Set **Emergency Full GC** to **500 MB** (or higher, up to 1000). This prevents the full GC from triggering right after combat.
2. Set **Combat Step** to **30** KB/f (or higher, up to 50). This collects more garbage *during* combat so less accumulates.

---

## ⚠️ Conflicts

### SmartGC
**Do NOT use SmartGC together with LuaBoost.**
SmartGC has been integrated into LuaBoost. Using two GC managers simultaneously will conflict.

### KPack SpeedyLoad
**Disable KPack's SpeedyLoad module if you enable LuaBoost's SpeedyLoad.**
Both addons suppress the same events during loading screens. Running both will cause double-suppression.

---

## 📦 Installation

Copy the addon folder into your WoW directory:

```text
Interface/AddOns/!LuaBoost/
├── !LuaBoost.toc
├── LuaBoost.lua
├── enUS.lua
└── koKR.lua
```

*(Make sure the folder is named `!LuaBoost` so it loads early).*

---

## 🧰 Commands

| Command | Description |
|---------|-------------|
| `/lb` or `/luaboost` | Status overview |
| `/lb gc` | GC stats + DLL stats (if present) |
| `/lb pool` | Table pool stats |
| `/lb toggle` | Enable/disable GC manager |
| `/lb force` | Force full GC now |
| `/lb sl` | Toggle SpeedyLoad on/off |
| `/lb sl safe` | Enable SpeedyLoad in safe mode (11 events) |
| `/lb sl agg` | Enable SpeedyLoad in aggressive mode (23 events) |
| `/lb tg` | UI Thrashing Protection stats |
| `/lb tg toggle` | Enable/disable ThrashGuard at runtime |
| `/lb tg reset` | Reset ThrashGuard counters |
| `/lb settings` | Open GC settings panel |
| `/lb help` | Show all commands |

---

## 📜 License

MIT License — do whatever you want with it.