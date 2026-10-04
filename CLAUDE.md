# AcousticMaps

Eyes-free walking navigation. A thin iPhone app (Sophia) talks to a Python FastAPI server (Joy) in `server/`.
Plans and contracts are in `docs/`: start with `docs/server-build.md`, then `navigation.md` and `voice-streaming.md`.

## How to work with Joy

- Joy types the server code; Claude guides and reviews. Don't write server code files unless asked.
- Always put the full code for the current step in the current message. Never say "see above" or
  make Joy scroll up for code.
- Plain functions, small files, clear code. Say what each file does.
- Before each build step, first give a short summary: goal, what gets built, tools and dependencies,
  what it affects (new, changed and unchanged files; the contract; Sophia's work), and the
  checkpoint. Then give the full code.
- Stop at each checkpoint so Joy can test before moving on.
- Never rename contract fields (`/update`, `/listen`) without flagging it, since Sophia builds against them.

## Server

- Run from `server/`: `source .venv/bin/activate && uvicorn main:app --reload --host 0.0.0.0 --port 8000`
- Tunnel: `cloudflared tunnel --url http://localhost:8000`
- Keys go in `server/.env` (gitignored). Logging and recording switches are `LOG_LEVEL` and `RECORD_UPDATES`.
- Before a demo, fill the cache (OpenStreetMap paths, landmarks, Gemini wording) so trips don't depend on
  slow APIs: `ROUTING_MOCK=0 python routing.py --warm` (from PSB), or `--warm <lat>,<lng>` from the demo's
  start point. The cache lives in `server/cache/`.
