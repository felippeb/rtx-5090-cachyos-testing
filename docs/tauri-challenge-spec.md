Build a complete, production-ready Tauri v2 desktop application called "TicTac History". This is a local-first tic-tac-toe game with persistent win tracking.

## REQUIREMENTS

1. Frontend: React 18 + TypeScript + Vite + TailwindCSS + Lucide React icons
2. Backend: Rust using Tauri v2 API
3. Database: SQLite with `sqlx` (async) for persistent local storage
4. State Management: Zustand or React Context (keep it simple)
5. Styling: TailwindCSS with dark/light theme support and system preference detection

## CROSS-PLATFORM REQUIREMENTS

- Tauri v2 configuration for Windows, macOS, and Linux
- Platform-specific icons and assets (16x16, 32x32, 64x64, 128x128, 256x256 for Windows; .icns for macOS; .svg for Linux)
- Platform-specific window sizing and positioning defaults
- Cross-platform path handling for the SQLite database (use `dirs` crate for app data directory)
- Platform-specific build configuration in `tauri.conf.json`

## FEATURES

- Standard 3x3 tic-tac-toe board with customizable player names (default: 'Player 1' and 'Player 2')
- Name configuration: Input fields to set custom names for Player 1 and Player 2. If left empty, defaults apply.
- Name persistence: Player names are saved to the SQLite database and persist across app restarts.
- Dynamic tracking: All history, statistics, and game results reflect the configured player names.
- Turn-based gameplay with visual indicator of current player
- Win detection for rows, columns, and diagonals
- Draw detection when board is full with no winner
- Game history tracking: record every game result (Winner Name or Draw) with timestamp and final board state
- Win statistics dashboard showing: total games played, [Player 1 Name] wins, [Player 2 Name] wins, draws, win percentages
- History log showing last 20 games with timestamp and result
- Reset game board button to start a new game
- Reset statistics button to clear all history
- Export history to JSON file
- Import history from JSON file
- Theme configuration: Toggle between Dark, Light, and System Default. System Default automatically adapts to OS settings. Theme preference persists in local storage.
- Responsive layout that works well on 1366x768 and up

## INSTALLATION CONSTRAINTS

All dependencies MUST be installed in user-space only. Do NOT use:
- `sudo npm install -g`
- `cargo install --global`
- System package managers (apt, pacman, dnf)

Use:
- `npm install` (no --global) in the project directory
- `cargo build` / `cargo run` (no --global)
- Node.js native modules should install into `node_modules/` within the project
- Rust toolchain via rustup is assumed; do not suggest system-wide installs

## PROCEEDING INSTRUCTIONS

After generating all files, the user should:

1. Copy all generated files into a new directory (e.g., `mkdir tictac-history && cd tictac-history`)
2. Install frontend dependencies: `npm install`
3. Install Rust toolchain (if not already installed): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
4. Install Tauri CLI: `cargo install tauri-cli --version "^2"`
5. Install build dependencies (Linux): `sudo apt install libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev` (this is the only allowed system install — it's a Tauri build requirement, not a project dependency)
6. Build the desktop app: `cargo tauri dev` (development) or `cargo tauri build` (production)
7. The app will launch automatically in dev mode

## OUTPUT FORMAT (STRICT — DO NOT DEVIATE)

You MUST output every file using this EXACT separator format. No exceptions. No tree diagrams. No summaries. No placeholders.

For each file, output:

--- filename: RELATIVE/PATH/TO/FILE.ext ---
[COMPLETE FILE CONTENT HERE]

--- filename: NEXT/FILE.ext ---
[COMPLETE FILE CONTENT HERE]

CRITICAL RULES:
1. EVERY file must use the `--- filename: path ---` separator. Nothing else.
2. The separator line contains ONLY `--- filename: ` followed by the relative path and ` ---`.
3. File content goes between the separator lines.
4. Do NOT use markdown code blocks (```) around file content.
5. Do NOT use tree diagrams (├──, └──) or file listings.
6. Do NOT use placeholders like "[...]", "// rest of code", or similar.
7. Write COMPLETE, COMPILABLE code for every single file.

The separator `--- filename: path ---` is the ONLY way to delimit files. The extraction script will parse this exact pattern. If you don't use it, your output will not be processed.

## MCP / TOOL USE INSTRUCTIONS (for opencode, hermes, pi clients)

Before writing any code, use your available tools and MCP servers to:

1. **Research Tauri v2 best practices** — check the latest Tauri docs, migration guides from v1, and current recommended patterns for security, capabilities, and plugins. Use `tavily-mcp`, `jina-mcp-tools`, `firecrawl-mcp`, `linkup-search`, or `duckduckgo-search` to verify current information.
2. **Verify sqlx + SQLite patterns** — confirm the latest async SQLx usage patterns for Tauri backend, including connection pooling, error handling, and migrations.
3. **Check React 18 + Tauri integration** — verify the current recommended approach for Tauri v2 API calls from React, including `@tauri-apps/api` v2 usage, invoke patterns, and type safety.
4. **Verify TailwindCSS + Vite setup** — confirm the latest Tailwind v4 (or v3) configuration for Vite + Tauri, including dark mode setup and CSS variable theming.
5. **Check Lucide React API** — verify the current Lucide React API for icon imports and usage.

Available MCP servers: `tavily-mcp` (web search), `jina-mcp-tools` (web reader + search), `firecrawl-mcp` (web scraping/crawling), `linkup-search` (deep web research), `duckduckgo-search` (privacy-focused search), `context7` (library documentation). Use them to validate your approach before generating code.

If you cannot access MCP servers, use your best knowledge but note any areas where verification would have helped.

The goal is to produce a project that uses current, correct patterns — not outdated v1 patterns or deprecated APIs.