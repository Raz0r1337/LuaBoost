# ⚡ LuaBoost v1.2.0 (WotLK 3.3.5a)

**Lua runtime optimizer + SmartGC + SpeedyLoad for World of Warcraft 3.3.5a (build 12340)**
Author: **Suprematist**

LuaBoost improves addon performance by optimizing common Lua patterns, eliminating GC stutter with per-frame incremental garbage collection, and speeding up loading screens by suppressing noisy events.

Designed for **Warmane** and other 3.3.5a servers.

---

## ✅ Features

### Runtime Optimizations (automatic, always active)
- Faster `math.floor`, `math.ceil`, `math.abs` (pure Lua replacements, **auto-detected per CPU**)
- Faster `table.insert(t, v)` for append case
- `GetTimeCached()` — cached `GetTime()` value updated once per frame
- `LuaBoost_Throttle(id, interval)` — shared throttle helper for any addon
- Table pool: `LuaBoost_AcquireTable()` / `LuaBoost_ReleaseTable(t)` / `LuaBoost_GetPoolStats()`
- `GetDateCached(fmt)` — opt-in cached date helper (does **not** replace global `date()`)

### Math Auto-Detect (v1.2.0)
On first login, LuaBoost runs a quick micro-benchmark (200k iterations) to test whether its pure-Lua math replacements are actually faster than the original C implementations on **your specific CPU**.

- If a fast replacement is **slower** (beyond 5% tolerance) → **reverts to original** automatically
- Result is **saved** in `SavedVariables` — bench only runs once
- `/lb math` — check current status
- `/lb mathbench` — re-run detection manually
- Toggle in `ESC → Interface → AddOns → LuaBoost → Tools`

### Smart GC Manager (configurable)
- Stops Lua auto-GC and performs **incremental GC steps every frame**
- **4-tier stepping**: loading → combat → idle → normal
  - **Loading**: aggressive cleanup (no rendering happening anyway)
  - **Combat**: minimal GC to protect frametime
  - **Idle**: aggressive cleanup while AFK
  - **Normal**: balanced stepping
- Emergency full GC when Lua memory exceeds threshold (outside combat)
- GC burst on heavy events (boss kill, LFG popup, achievement, loot spam)
- **3 presets**: Weak / Mid / Strong — pick based on your addon load
- GUI: `ESC → Interface → AddOns → LuaBoost`

### SpeedyLoad — Fast Loading Screens
- Temporarily suppresses noisy events during loading screens
- Restores all events after loading completes (with event replay)
- **Two modes**:
  - **Safe** (11 events) — cosmetic events only, no risk
  - **Aggressive** (23 events) — includes actionbar/aura/inventory events, faster but slightly more aggressive
- Based on the approach from KPack/SpeedyLoad by Kader, with improvements:
  - Uses `GetFramesRegisteredForEvent()` for targeted suppression
  - Hooks `UnregisterEvent` to track removals during loading
  - Replays missed events after restore
  - Ensures LuaBoost's handler fires first via priority re-registration

### Protection Hooks (optional, OFF by default)
- **Intercept `collectgarbage()`** — blocks other addons from forcing full GC spikes
- **Block `UpdateAddOnMemoryUsage()`** — prevents CPU spikes from frequent memory scans

### DLL Integration (optional)
Works with **[wow_optimize.dll](https://github.com/suprepupre/wow-optimize)**:
- DLL does GC stepping from C (via Sleep hook) — zero Lua overhead
- DLL replaces Lua allocator with mimalloc — faster allocation, less fragmentation
- DLL reads `LUABOOST_ADDON_COMBAT`, `LUABOOST_ADDON_IDLE`, `LUABOOST_ADDON_LOADING` globals
- DLL adjusts step size based on 4-tier state
- LuaBoost remains the UI/logic/settings layer
- Stats available via `LuaBoostC_GetStats()`

---

## 🆕 What's New in v1.2.0

| Feature | Description |
|---------|-------------|
| **Math Auto-Detect** | Benchmarks math replacements on first login. Reverts to original if fast version is slower on your CPU. Cached in SavedVariables. |
| **Fixed Benchmark Output** | `/lb bench` now correctly shows "X% faster" (green) or "X% slower" (red) instead of always saying "faster" |
| **Expanded Slider Ranges** | All GC sliders support higher values for heavy addon setups |
| **Rebalanced Presets** | Weak/Mid/Strong presets fixed — old values were inverted and had too-low emergency thresholds |
| **New Commands** | `/lb math`, `/lb mathbench` |

---

## ⚙️ Settings Reference

Open settings: `ESC → Interface → AddOns → LuaBoost → GC Settings`

### Step Sizes — KB collected per frame

These control how much garbage the GC collects **every single frame**. Higher = more cleanup per frame (uses slightly more CPU) but keeps memory lower. Lower = less CPU but memory accumulates faster.

| Setting | What it does | Increase if... | Decrease if... |
|---------|-------------|----------------|----------------|
| **Normal Step** | GC work per frame during regular gameplay (walking around, questing, in town) | Memory climbs over time; you see gradual FPS degradation | You want minimal CPU overhead; you have very few addons |
| **Combat Step** | GC work per frame **during combat**. This is the most sensitive setting — too high hurts frametime, too low lets garbage pile up | You get a **big freeze after boss kills** — garbage accumulated during combat and triggers emergency GC | Combat FPS is unstable; you're CPU-limited and every microsecond matters |
| **Idle Step** | GC work per frame while AFK/idle (no input for N seconds) | Memory stays high even while AFK | Not important — idle mode uses zero rendering resources anyway |
| **Loading Step** | GC work per frame during loading screens (no rendering) | Loading screens feel slow | Not important — no rendering during loading |

#### How step size works
At 60 FPS with Normal Step = 50 KB:
- GC processes `50 KB × 60 = 3,000 KB/s ≈ 3 MB/s` of garbage per second
- Heavy addons (DBM + WA + Skada) generate roughly 1–2 MB/s of garbage
- So 50 KB/frame keeps up with most addon workloads

### Thresholds

| Setting | What it does | Increase if... | Decrease if... |
|---------|-------------|----------------|----------------|
| **Emergency Full GC (MB)** | When Lua memory exceeds this value (outside combat), LuaBoost forces a **full garbage collection**. This is a blocking operation — the game freezes until it's done. | **You get freezes after boss kills** or dungeon queue pops. Set to 500+ for heavy addon setups. | You want memory to stay low and don't mind occasional brief pauses (light addon setup) |
| **Idle Timeout (sec)** | Seconds without player activity before switching to idle GC mode (higher step size) | You want faster cleanup during brief AFK moments | You don't want aggressive GC to kick in while reading chat/AH |

### Why Emergency Full GC Causes Freezes

When Lua memory hits the emergency threshold, LuaBoost runs `collectgarbage("collect")` — a **full stop-the-world GC**. If there's 300 MB of garbage to clean, this can take **5-10 seconds**.

The solution is **not** to disable emergency GC, but to:
1. **Raise the threshold** so it doesn't trigger during normal spikes
2. **Raise combat step** so less garbage accumulates during boss fights
3. Let the per-frame incremental GC handle cleanup gradually

### Presets Comparison

| Setting | Weak | Mid | Strong |
|---------|------|-----|--------|
| Normal Step (KB/f) | 20 | 50 | 100 |
| Combat Step (KB/f) | 5 | 15 | 30 |
| Idle Step (KB/f) | 80 | 150 | 300 |
| Loading Step (KB/f) | 150 | 300 | 500 |
| Emergency GC (MB) | 150 | 300 | 500 |
| Idle Timeout (sec) | 15 | 15 | 20 |

| Preset | Best for | CPU cost | Memory | Freeze risk |
|--------|----------|----------|--------|-------------|
| **Weak** | Few addons, light UI, low-end CPU | Very low | Higher | Low (few addons = little garbage) |
| **Mid** | Most players, moderate addon setup | Low | Moderate | Low |
| **Strong** | DBM + WA + Skada + nameplates + everything | Moderate | Low | Very low |

**How to choose:**
- Start with **Mid** (default)
- If you get post-boss freezes → switch to **Strong**
- If you have very few addons and want minimal CPU overhead → try **Weak**
- If none of the presets fit → adjust individual sliders (preset changes to "Custom")

### Protection & Tools Settings

| Setting | What it does | When to enable |
|---------|-------------|----------------|
| **Debug mode** | Prints GC mode changes, SpeedyLoad events, emergency GC info to chat | When troubleshooting issues. Disable for normal play. |
| **Intercept collectgarbage()** | Blocks other addons from calling `collectgarbage("collect")` which would freeze the game | If you see sudden freezes caused by other addons forcing full GC. **WARNING:** causes taint with ElvUI/secure frames. |
| **Block UpdateAddOnMemoryUsage()** | Blocks CPU-heavy memory scanning calls | If you notice lag when opening addon memory panels. **WARNING:** causes taint. |
| **MemUsage Min Interval** | Minimum seconds between allowed `UpdateAddOnMemoryUsage()` calls | Only matters if Block MemUsage is OFF — throttles how often scans can run |
| **SpeedyLoad** | Suppresses noisy events during loading screens | If loading screens (dungeon teleports, zone changes) feel slow |
| **SpeedyLoad Mode** | Safe (11 events, cosmetic only) vs Aggressive (23 events, includes actionbar/inventory) | Use Safe first. Try Aggressive if you want faster loads and don't see issues. |
| **Math Auto-Detect** | Benchmarks pure-Lua math replacements vs originals on first login | Leave ON. Disable only if you want to force fast versions regardless of bench results. |

---

## 🔧 Fixing Freezes After Boss Kills / Dungeon Queue Pops

**Symptom:** A 5–10 second freeze right after killing a boss, leaving combat, or when a dungeon queue pops. The game becomes completely unresponsive.

**Cause:** When you fight a boss (especially in 25-man raids with addons like DBM, WeakAuras, Skada), Lua memory spikes rapidly — often from ~100 MB to 400+ MB. When combat ends, the Emergency Full GC triggers because memory exceeded the threshold, causing a **full garbage collection** that has to clean up 200–300 MB of garbage in one go. This is a single-threaded operation that blocks the entire game.

### Quick Fix

Switch to **Strong** preset:
```
/lb settings
```
Click the **Strong** button. Done.

### Manual Fix

1. Open `ESC → Interface → AddOns → LuaBoost → GC Settings`
2. Set **Emergency Full GC** to **500 MB** (or higher, up to 1000)
3. Set **Combat Step** to **30** KB/f (or higher, up to 50)

### Why this works

| Setting | What it does |
|---------|-------------|
| **Higher Emergency GC threshold** | Prevents the full GC from triggering right after combat when memory is high. Instead, the incremental per-frame GC gradually cleans up the memory over many frames — no freeze. |
| **Higher Combat Step** | Collects more garbage per frame *during* combat, so less garbage accumulates by the time the boss dies. Memory stays lower, so the post-combat spike is smaller. |

### Recommended values by addon load

| Addon Load | Emergency GC | Combat Step | Normal Step | Preset |
|------------|-------------|-------------|-------------|--------|
| Light (few addons) | 150 MB | 5 KB/f | 20 KB/f | Weak |
| Medium (DBM + meter) | 300 MB | 15 KB/f | 50 KB/f | Mid |
| Heavy (DBM + WA + Skada + nameplates) | 500 MB | 30 KB/f | 100 KB/f | Strong |
| Extreme (everything + ElvUI) | 600–1000 MB | 50–100 KB/f | 100–200 KB/f | Custom |

> **User feedback:** *"Setting Emergency GC to 500 and Combat Step to 30 — it seems to have stopped the big ass pause after boss kill."*

### How to verify it worked
1. Enable debug mode: `ESC → AddOns → LuaBoost → Tools → Debug mode`
2. Do a raid boss fight
3. After combat, check chat — you should see incremental GC messages instead of "Emergency GC: freed 300 MB in 8000 ms"
4. `/lb gc` to see current memory and step stats

---

## ⚠️ Conflicts

### SmartGC
**Do NOT use SmartGC together with LuaBoost.**
SmartGC has been integrated into LuaBoost. Using two GC managers simultaneously will conflict.

SmartGC repo: https://github.com/suprepupre/SmartGC

### KPack SpeedyLoad
**Disable KPack's SpeedyLoad module if you enable LuaBoost's SpeedyLoad.**
Both addons suppress the same events during loading screens. Running both will cause double-suppression and events may not restore correctly.

To disable in KPack: find SpeedyLoad in KPack's module settings or addons folder and disable/remove it.

If you keep LuaBoost SpeedyLoad **disabled** (default), KPack SpeedyLoad can remain active — they won't conflict.

---

## 📦 Installation

### Recommended (early load order)
LuaBoost must be loaded first, so the `!` prefix is used:

Copy the addon folder:
```
Interface/AddOns/!LuaBoost/
├── !LuaBoost.toc
└── LuaBoost.lua
```

If you downloaded from GitHub, make sure the extracted folder is named `!LuaBoost`.

Restart WoW or `/reload`.

### Recommended combo

| Layer | Tool | What It Does |
|-------|------|--------------|
| **C / Engine** | [wow_optimize.dll](https://github.com/suprepupre/wow-optimize) | Faster memory, I/O, network, timers, Lua allocator + GC from C |
| **Lua / Addons** | !LuaBoost addon | Faster math/table, incremental GC, SpeedyLoad, table pool, throttle API |

---

## 🧰 Commands

| Command | Description |
|---------|-------------|
| `/lb` or `/luaboost` | Status overview |
| `/lb bench` | Run performance benchmark |
| `/lb gc` | GC stats + DLL stats (if present) |
| `/lb pool` | Table pool stats |
| `/lb toggle` | Enable/disable GC manager |
| `/lb force` | Force full GC now |
| `/lb sl` | Toggle SpeedyLoad on/off |
| `/lb sl safe` | Enable SpeedyLoad in safe mode (11 events) |
| `/lb sl agg` | Enable SpeedyLoad in aggressive mode (23 events) |
| `/lb math` | Math optimization status |
| `/lb mathbench` | Re-run math auto-detect benchmark |
| `/lb settings` | Open GC settings panel |
| `/lb help` | Show all commands |

---

## 📊 SpeedyLoad Event Lists

### Safe Mode (11 events)
```
SPELLS_CHANGED, SPELL_UPDATE_USABLE, ACTIONBAR_SLOT_CHANGED,
USE_GLYPH, PLAYER_TALENT_UPDATE, PET_TALENT_UPDATE,
WORLD_MAP_UPDATE, UPDATE_WORLD_STATES, UPDATE_FACTION,
CRITERIA_UPDATE, RECEIVED_ACHIEVEMENT_LIST
```

### Aggressive Mode (23 events)
All safe events plus:
```
ACTIONBAR_UPDATE_STATE, ACTIONBAR_UPDATE_USABLE,
ACTIONBAR_UPDATE_COOLDOWN, SPELL_UPDATE_COOLDOWN,
UNIT_AURA, UNIT_INVENTORY_CHANGED, BAG_UPDATE,
QUEST_LOG_UPDATE, COMPANION_UPDATE, PET_BAR_UPDATE,
TRADE_SKILL_UPDATE, MERCHANT_UPDATE
```

---

## 📁 Project Structure

```
!LuaBoost/
├── !LuaBoost.toc    # Addon metadata (Interface 30300)
└── LuaBoost.lua     # All addon code (single file)
```

---

## ✅ Compatibility

- **WoW**: 3.3.5a (Interface 30300)
- **Tested**: Warmane (Lordaeron / Icecrown)
- **Lua**: 5.1 (embedded in WoW client)
- **Works with**: DXVK, LAA patch, wow_optimize.dll
- **Conflicts with**: SmartGC addon, KPack SpeedyLoad module (if both SpeedyLoad features are enabled)

---

## 🐛 Troubleshooting

| Problem | Solution |
|---------|----------|
| **Big freeze after boss kill (5–10 sec)** | Switch to **Strong** preset, or increase Emergency Full GC to 500+ MB and Combat Step to 30+ KB/f. See [Fixing Freezes](#-fixing-freezes-after-boss-kills--dungeon-queue-pops). |
| **Gradual FPS drop over long sessions** | Increase Normal Step to 80–100+ KB/f. Memory is accumulating faster than GC can clean. |
| **Micro-stutters every few seconds** | Emergency GC threshold is too low — raise it. Or enable **Strong** preset. |
| **Freeze when opening mailbox/AH** | Normal — these generate burst garbage. LuaBoost already handles GC bursts on these events. If severe, increase Normal Step. |
| **"A macro script has been blocked"** | Disable protection hooks in Tools panel (Intercept collectgarbage, Block UpdateAddOnMemoryUsage) |
| **Math bench says "slower"** | Normal — your CPU's C math is faster. LuaBoost auto-reverts to original. No action needed. |
| **SpeedyLoad not working** | Check that `GetFramesRegisteredForEvent` is available (shown in main panel). Some heavily modified clients may not have it. |
| **Conflict with SmartGC** | Disable/remove SmartGC. It's been merged into LuaBoost. |
| **Settings not saving** | Make sure `SavedVariables` folder exists and WoW can write to it. Check that you exit WoW properly (not via Task Manager). |
| **DLL not detected** | Install [wow_optimize.dll](https://github.com/suprepupre/wow-optimize). LuaBoost works fine without it — DLL is optional. |
| **Old preset values after update** | Your saved settings are preserved. Click a preset button (Weak/Mid/Strong) to apply new values, or Reset to Defaults in Tools. |

---

## 📜 License

MIT License — do whatever you want with it.