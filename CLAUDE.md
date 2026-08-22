# CLAUDE.md

Agentic Stories: interactive fiction where the player seeds a story, an LLM "Weaver" turns
the seed into a Story (arc, tone, style, cast, opening scene), and each Character runs as
its own process that ticks on its own schedule, spending energy to decide whether to speak,
act, or stay quiet. Player interaction grants energy; silence lets the world go dormant.

Follow `AGENTS.md` for Phoenix v1.8 / Elixir / LiveView / Tailwind style rules. This file
covers what is specific to this project.

## Commands

```bash
docker compose up -d      # Postgres 17 on localhost:5432 (postgres/postgres)
mix setup                 # deps + ecto.create + ecto.migrate + assets
mix phx.server            # run on localhost:4000 (needs ANTHROPIC_API_KEY exported)
mix test                  # full suite; needs Postgres running, never hits a real LLM
mix test path/to/test.exs:42
mix precommit             # ALWAYS run when a change is done: warnings-as-errors,
                          # unused deps check, format, tests
```

## Architecture

Three boundaries. Keep them clean:

- `AgenticStories.Stories` — the persistence context. Ecto schemas (`Story`, `Character`,
  `Message`), CRUD, queries, and PubSub broadcasts. Broadcasts go to `"stories"` (all
  story lifecycle events) and `"story:#{id}"` (that story's events) as
  `{:story_updated, story}` / `{:message_created, message}` / `{:character_updated, character}`.
  No LLM calls, no process orchestration here.
- `AgenticStories.Engine` — the runtime. `Engine.Weaver` (seed → story, runs in a
  supervised Task), `Engine.CharacterAgent` (one GenServer per character: energy, ticks,
  jitter, dormancy), `Engine.CharacterMind` (pure prompt building + decision parsing).
  Public API is `AgenticStories.Engine` (`seed_story/1`, `ensure_running/1`,
  `player_message/2`). Agents register in `AgenticStories.Engine.Registry` and run under
  `AgenticStories.Engine.CharacterSupervisor`.
- `AgenticStories.LLM` — the text provider port. A behaviour (`chat/1` taking
  `LLM.Request` → `LLM.Response`) plus drivers: `LLM.Venice` (Venice.ai, uncensored,
  OpenAI-compatible `POST /v1/chat/completions`, the default), `LLM.OpenRouter`
  (same wire format, OpenRouter model slugs), `LLM.Grok` (xAI direct), and
  `LLM.Claude` (Anthropic `POST /v1/messages`). Model names are config, not code.
  Message content is a string or a list of `%{text:, cache:}` blocks; the Venice,
  OpenRouter, and Anthropic drivers turn `cache: true` into a `cache_control`
  breakpoint, the Grok driver flattens blocks in order (xAI caching is
  automatic). The Venice driver always disables `include_venice_system_prompt`
  (Venice would inject its own persona otherwise) and strips thinking from
  responses. The facade is `LLM.chat/2` — always pass `story_id:` and `purpose:`
  so the call lands in the cost ledger (`LLM.Ledger`, `llm_calls` table,
  best-effort, plain integer story_id on purpose).
- `AgenticStories.Engine.DirectorAgent` / `DirectorMind` — one omniscient, slow agent
  per live story. Directions: narrate / nudge (private one-tick impulse via the
  `nudge` virtual field + energy) / reveal (new location mid-story) / illustrate
  (chapter plate on a `:illustration` message) / conclude (closing narration, story
  `:finished`, cast stopped). Same energy discipline, funded only by player activity.
- `AgenticStories.Engine.Narrator` — residue (arrival traces of missed beats, watermark
  advances via the residue beat itself) and "Previously…" recaps (ephemeral assign,
  never a message).
- `AgenticStories.Engine.Presence` — an ETS table of "the player is writing", per story.
  The composer stamps it on `phx-change` (throttled); `CharacterAgent` and
  `DirectorAgent` read it before they take a turn. Deliberately process-free: a tick
  must never block on a process that is itself blocked on an LLM call.
- `AgenticStories.Imagery` — the image provider port (same pattern). `Imagery.Venice`
  is the default driver: photorealistic, uncensored renders via Venice's
  `POST /v1/image/generate` (base64 JSON, `safe_mode` forced off) and
  reference-based compositions via `POST /v1/image/multi-edit` (raw image
  response, up to three inputs). `Imagery.GrokImagine` (xAI,
  `POST /v1/images/generations`) remains available. Paints character
  portraits after weaving, best-effort: failures log and leave the character on the
  initial-letter fallback. Gated by `Imagery.enabled?/0` (off in tests).

  Plates mark the story's turning points: the opening scene, a place's first arrival
  (one per location, ever — `Stories.plate_at?/2`), a Director `illustrate`, the ending,
  and `Engine.request_plate/1` — the player's own "Picture this" button, the only plate
  whose scene is not supplied by its caller: `Narrator.tableau/4` reads the record back
  for who is present, how they stand, and what they are wearing *by now* (the Director's
  cooldown does not apply — the player asked). The Director's prompt invites plates at real turns; the rate limit is
  code-side (`plate_cooldown_beats` vs `Stories.beats_since_plate/1`), because a model
  cannot count beats and asking it to only costs tokens.

  **Getting the cast INTO the plate is the whole point of `compose/2`.** Present
  characters' portraits ride along as reference images and the prompt names them in the
  order the images were sent (the edit endpoint treats image 1 as the base). Two things
  break this silently, so watch them: `safe_mode` defaults to *true* on Venice's
  multi-edit endpoint (the driver forces it off on both endpoints), and a wrong
  `:edit_model` id makes every composition 4xx. Falling back to a text-only render is
  deliberate, but it **logs why** — a silent fallback is how "the plates never have
  anyone in them" hides for weeks.

Rules that keep this honest:

- **Nothing outside a driver module makes HTTP calls to a provider.** New providers =
  new module implementing the port behaviour + config change.
- Domain/engine code calls `AgenticStories.LLM.chat/1` (the facade), never a driver
  directly. The facade dispatches to the configured adapter.
- Prompt building and response parsing are pure functions (`Engine.CharacterMind`,
  `Engine.Weaver` blueprint parsing, `LLM.JSON`) so they're testable without processes.
- **Characters write prose; everything else writes JSON.** A character's tick reply is
  their beat as the story would tell it — **third person, present tense, dialogue in
  quotation marks**. The player is the only "you"; a character never writes "I" outside
  quotes. `CharacterMind.parse_decision/2` reads the shape: `-> Place: text` is a move,
  `silence` (or an empty reply) is a wait, quoted speech anywhere in the prose makes it
  a `:say`, and prose with nothing spoken is an `:act`. It also strips the character's
  own `Name:` prefix (models copy the transcript format they were just reading) and the
  leading dash the reading pane used to draw. A reply that arrives as a decision object
  is still parsed as one, so a model reaching for JSON out of habit never spills braces
  into the story. Do NOT put characters back on JSON, and do NOT ask them for a line in
  their own voice: first person from every character at once stops reading like a story,
  and a small model writes worse prose filling a string field than telling a tale.
- The Weaver, the Director, and the Narrator's tableau DO use JSON — they are structural,
  not voiced. Those responses are parsed leniently via `AgenticStories.LLM.JSON` (strips
  code fences, extracts the outermost object). Treat parse failures as "the character
  stays quiet" / "weaving failed" — never crash the story over bad JSON.

## Witnessing (locations & per-character memory)

- Stories have `locations` (created by the Weaver from the seed). The player
  (`story.player_location_id`) and every character (`character.location_id`) are always
  at exactly one. A beat's presence is recorded **at write time**: witness rows in
  `message_witnesses` for characters, `witnessed_by_player` stamped on the message.
  Never compute witnessing retroactively from current positions.
- The reading pane is `Stories.player_messages/1`; a character's working memory is
  `Stories.character_memory/2` (witnessed beats only). A nil location (legacy or failed
  stories) means "witnessed by everyone" — keep that degradation path working.
- Moves (`Engine.character_move/4`, `Engine.player_move/2`) produce ONE beat with
  `witness_location_ids: [origin, destination]` so both rooms see it.
- Long-term memory is a **journal**: when a character's witnessed count crosses a
  chunk boundary, `Stories.fading_beats/2` hands the fading beats to
  `CharacterMind.consolidate/4`, which writes the NEXT entry (earlier entries are
  context, never restated) and `Stories.append_character_memory/3` freezes it as a
  new `CharacterMemory` block, advancing `memory_beats` in the same transaction.
  Nothing leaves the raw window until it lives in a block
  (`character_memory/2` trims to `min(chunk_drop, memory_beats)`), so a failed
  consolidation never punches a hole in what a character knows.

## The energy model (config: `:agentic_stories, AgenticStories.Engine`)

- `tick_interval_ms` base delay between one character's ticks (± jitter), `tick_cost`
  energy per tick, `player_energy` granted to co-located characters on a player message
  (`ambient_energy` trickles to everyone else), `chatter_energy` passed to **one** other
  co-located character when one speaks (the torch, next in cast order), `max_energy` cap,
  `initial_energy` funds exactly one reaction to the opening, `idle_timeout_ms` retires
  agents after player silence.
- **The floor belongs to the player while they type.** `typing_grace_ms` after the last
  keystroke, a tick that lands yields instead of speaking — costing no energy and no LLM
  call — and a line drafted before the player started typing is held by `verdict/3` as a
  collision. `Engine.player_message/2` drops the hold, so an answer is never delayed by
  the draft that provoked it. Emptying the composer drops it too; the grace window means
  an abandoned draft can never freeze a story.
- **Invariant: `chatter_energy < tick_cost`.** The player is the only net energy source;
  every tick strictly drains the cast, so scenes decay to silence at any cast size.
  Granting chatter to more listeners (or ≥ tick_cost) makes a perpetual-motion cast.
- **Responsiveness:** a `:player`-source energize reschedules the agent's pending tick to
  the wake delay (~2s) — without this, an addressed character with energy would sit on
  its 15–22s schedule. One pending tick at a time (`tick_timer` is cancelled on
  reschedule); don't add extra timers. `:ambient` wakes dormant agents only lazily.
- Energy is persisted on the character row so it survives restarts.
- An agent whose energy < tick cost stops rescheduling (dormant) until energized.
- Agents retire (`{:stop, :normal}`) `idle_timeout_ms` after the last *player* message —
  chatter does not extend the deadline. `Engine.ensure_running/1` (called on page mount
  and on every player message) revives them.
- There is deliberately **no global tick** — don't add one.

## Prompt caching (don't break it)

Character ticks are shaped for prompt caching on BOTH providers; the win is real only
while the prefix stays byte-stable across ticks:

- The tick prompt is an **append-only prefix**:
  `[static system] [memory block 1..N, frozen] [raw beats] [instruction]`.
  Static content (persona, agenda, rules, decision format) lives in the system
  prompt; long-term memory is a chain of immutable `CharacterMemory` blocks
  (append-only — NEVER rewrite one); the transcript is one block per beat.
  Breakpoints sit on the last memory block and the newest beat; xAI caches the
  identical byte prefix automatically. Consolidation appends block N+1 and trims the
  raw tail in the same moment, so everything through block N stays cached. Same
  invariant either way: **nothing volatile before the newest beat, and nothing
  behind the newest memory block ever changes.**
- Never add volatile content (timestamps, counters) before the breakpoint, and don't
  change beat rendering (`CharacterMind` line format) casually — both silently
  invalidate every cached prefix.
- `Stories.character_memory/2` trims the transcript in window-sized **chunks**, not one
  message at a time. A per-message sliding window changes the prefix every tick and
  defeats caching entirely — keep it chunked.
- Verification is built in: the ledger records cached tokens (Anthropic
  `cache_read_input_tokens`; the OpenAI-compatible drivers'
  `prompt_tokens_details.cached_tokens`) and the story sidebar shows them. If that
  number sits at zero in a long story, something above broke — unless the model is
  one of Venice's self-hosted uncensored ones, which don't cache at all (zero is
  expected there; the byte-stable prefix discipline still applies everywhere).

## Testing conventions (TDD)

Write the failing test first; tests describe behaviour, not implementation.

- `AgenticStories.LLM.Mock` (Mox, defined in `test/support/mocks.ex`) stands in for the
  LLM everywhere except the driver's own tests. Expectations resolve through `$callers`,
  so Tasks spawned by LiveViews inherit them.
- The Claude driver is tested with `Req.Test` (`plug: {Req.Test, AgenticStories.LLM.Claude}`
  in `config/test.exs`). Only driver tests stub HTTP.
- `config/test.exs` sets `start_agents: false`, so `Engine.ensure_running/1` is a no-op in
  tests; agent tests start `CharacterAgent` explicitly and use `Mox.allow/3` +
  `Ecto.Adapters.SQL.Sandbox.allow/3` for the agent pid.
- Fixtures live in `test/support/fixtures/stories_fixtures.ex`.

## Gotchas

- Provider keys are read in `config/runtime.exs` for all envs: `VENICE_API_KEY`
  (the default text + image adapters), plus `OPENROUTER_API_KEY`, `XAI_API_KEY`,
  and `ANTHROPIC_API_KEY` for the alternate drivers. Dev fails on first provider
  call (not at boot) if the configured adapter's key is unset. Weaving without a
  key frays the story with a clear reason; portraits/plates without one just log.
- **Agendas are secret.** `character.agenda` goes into CharacterMind/DirectorMind
  prompts and NOWHERE in the UI or reader page. Grep templates before shipping changes.
- Post-decision guards live in `CharacterAgent.verdict/3`: a collision (the player is
  typing, or **dialogue** — a player beat or another character's say — landed while
  thinking, via `Stories.witnessed_after/2`) holds the line and retries at the wake
  delay; repetition (`CharacterMind.repetitive?/3`, Jaro vs their own recent lines) and
  monologue (the newest beat they witnessed is their own say/act) drop it. Background
  acts/narration must NEVER cancel speech — that starves talkers in busy rooms (the
  Dez-and-Mara livelock). Keep guards code-side, not prompt-side.
- **One beat per character, per turn of the room.** A player message funds three ticks,
  so without the monologue guard a character says its piece three times running, which
  reads as one person talking to themselves. They may follow the player, another
  character, or the Director — never their own last word. Moves are exempt (they go
  through `move/4`, not `attempt/5`), so walking out on your own line still works.
- Agents trap exits so `terminate/2` always clears the thinking quill; the
  `{:EXIT, _, reason}` handle_info clause is what keeps `Process.exit(pid,
  :shutdown)` retirement working under trap_exit — don't remove either half.
- Player input starting with `*` becomes a `:act` beat with `character_id: nil` —
  rendering and transcripts must keep treating that as "You"/"The player".
- Finished stories: composer and moves are disabled at both the LiveView event level
  and the UI level; `ensure_running/1` ignores non-live stories; the DirectorAgent
  stops itself when its story is no longer live.
- The avatar binary never travels: `load_in_query: false` on the schema field,
  broadcasts strip it, and the UI fetches it over `/avatars/:id`. Load it only via
  `Stories.get_avatar/1`.
- The Anthropic request/response shapes live only in `LLM.Claude` — content is a list of
  blocks; join `"text"` blocks, check `stop_reason`.
- Character agents block on their own LLM call during a tick. That is intentional — it
  serializes one character's behaviour; never route another character's work through an
  existing agent process.
