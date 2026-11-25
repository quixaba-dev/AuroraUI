# Aurora UI 2.0 — Environment Compatibility

Aurora isolates all environment-specific APIs inside the internal `Environment` and `Storage` adapters.

## Supported Environments

1. **Roblox Executors**:
   - Uses `gethui()` if available, falling back to `CoreGui`, then `PlayerGui`.
   - Uses `getgenv()` for singleton cleanup (`__AuroraUI`) if available, falling back to `_G`.
   - Uses `writefile`, `readfile`, `isfile`, `isfolder`, `makefolder`, `listfiles`, `delfile` when exposed.
   - Uses `setclipboard` / `toclipboard` for one-click JSON export when available.
2. **Official Roblox (Studio / Live Client)**:
   - Zero dependency on executor globals.
   - Mounts cleanly into `PlayerGui`.
   - Falls back to in-memory storage + `LocalPlayer` attributes when filesystem APIs are absent.
   - Exported JSON is placed directly in the Theme/Config `TextArea` for manual copy.
