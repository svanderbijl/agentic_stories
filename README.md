# Agentic Stories

Interactive fiction with a living cast. You seed a story with freeform text — a premise, a
vibe, a half-remembered dream — and the app weaves it into a Story with an arc, tone, and
style to match. Then you step inside: you talk to the world, and the world talks back.

The interesting part is the cast. Each story spawns Characters driven by a cheap, fast LLM.
Every character runs as its own process with its own memory (the story's message history seen
through their eyes). They decide for themselves whether to speak, act, or stay quiet — based
on who's present, what just happened, and whether they have anything worth saying.

## Witnessing: you only know what you saw

Every story has **locations**, inferred from the seed by the Weaver. The player and every
character are always at exactly one of them, and every beat records — permanently, at the
moment it happens — who was there:

- Your reading pane shows only beats you witnessed. Things happen elsewhere that you
  (and the characters with you) genuinely don't know about.
- Arriving somewhere things happened without you produces **residue**: one or two
  sentences of traces — churned sand, an overturned chair — never the events themselves.
- Images stay scarce so the prose stays primary: the opening scene and each **first
  arrival** at a place earn one establishing plate, and the Director may commission one
  for a truly striking moment. Present characters' portraits ride along as reference
  images (up to three), so the people in a plate are the people on the cast cards —
  their Weaver-written `appearance` backs both portraits and scenes so every image of a
  character agrees with the others.
- A character's memory is only what *they* witnessed. Walk away from a conversation and
  they can only tell others what they saw before you left.
- Every character carries a hidden **agenda** the Weaver gives them and the player is
  never shown; witnessing is what lets them act on it behind your back.
- Characters can **move** as a tick decision; the departure/arrival beat is seen at both
  ends. You move through the world panel — walking into a room wakes whoever is there.
  You can act as well as speak: `*I douse the lamp*` becomes a deed.
- When a character's working window fills up, the oldest beats are **consolidated**: the
  character rewrites them into long-term memory in first person, through their own lens —
  including where they stand with everyone they've dealt with. Two characters keep
  different memories of the same night.
- Return after hours away and the Narrator greets you with a "Previously…" recap of what
  *you* witnessed.

## The energy model

There is no global game tick. Each character runs on their **own tick**, and ticking costs
**energy** — and the player is the only net source of it:

- A tick costs energy. On a tick, the character reads what they've witnessed and decides:
  say something, do something, move somewhere, or wait.
- Interacting with the player **gives** energy. When you write, characters in the room
  get a full charge (about three beats each) — and their next tick is pulled forward, so
  the person you addressed answers in seconds, not at the next scheduled beat. Characters
  elsewhere get a small ambient trickle: off-screen life, at an unhurried pace.
- A speaking character passes a little energy to **one** other cast member in the same
  place (the torch), so exchanges happen — but the invariant `chatter_energy < tick_cost`
  means every tick strictly drains the cast, and scenes provably decay to silence at any
  cast size.
- A character out of energy goes dormant until something (always, eventually, you) wakes
  the scene up.
- As a backstop, an agent **retires** a few minutes after the last player message, energy
  or not; the next visit or message revives the cast.

The result: a world that feels alive while you're engaged and goes quiet when you leave,
without any scheduler trying to orchestrate the whole thing.

## Architecture at a glance

```
AgenticStoriesWeb          LiveViews (seed, scene), reader mode, plates & avatars
AgenticStories.Stories     Persistence context: stories, characters, locations,
                           messages, witnesses (+ PubSub)
AgenticStories.Engine      The runtime: Weaver (seed → story), one CharacterAgent per
                           character (energy + ticks), the DirectorAgent (plot
                           pressure + endings), and the Narrator (residue, recaps)
AgenticStories.LLM         Text provider port + cost ledger. `LLM.Grok` (xAI) is the
                           default driver; `LLM.Claude` (Anthropic) ships too — a
                           config change swaps providers.
AgenticStories.Imagery     Image provider port. `Imagery.GrokImagine` (xAI) paints
                           character portraits and chapter illustrations.
```

## The Director

Characters supply presence; the **Director** supplies plot. One per live story, on the
same energy/tick discipline (slower, omniscient, funded only by player activity), it can:

- **narrate** — weather turns, a knock, something found, at a chosen place;
- **nudge** — grant a character energy plus a private one-tick impulse ("tell them
  tonight"), invisible to the player;
- **reveal** — open a new location mid-story, once the story has knocked on its door;
- **illustrate** — commission a chapter plate of the current scene from Grok Imagine;
- **conclude** — write the closing narration and finish the story. Finished stories
  become books on the shelf, readable end-to-end in reader mode (`/stories/:id/read`,
  print-friendly).

- The **Weaver** uses a capable model (default `claude-opus-5`) to turn a seed into a
  title, premise, arc, tone, style, opening scene, and cast.
- **Character agents** use a cheap/fast model (default `claude-haiku-4-5`) for their ticks.
  Their requests are shaped for **prompt caching**: static persona and rules live in the
  system prompt and the growing transcript keeps a byte-stable prefix with a cache
  breakpoint on the newest beat, so each tick only pays for what's new.
- Everything reaches providers through behaviours — swapping or adding providers never
  touches domain code.

## Getting started

Prerequisites: Elixir ~> 1.17 / OTP 26+, Docker (for Postgres).

```bash
# 1. Start Postgres
docker compose up -d

# 2. Provide your xAI API key (text + images). To use Claude for text instead,
#    switch the adapter in config/config.exs and export ANTHROPIC_API_KEY.
export XAI_API_KEY="xai-..."

# 3. Install deps, create and migrate the database
mix setup

# 4. Run the app
mix phx.server
```

Then open [localhost:4000](http://localhost:4000) and seed a story.

## Configuration

LLM models and engine tuning live in `config/config.exs`:

```elixir
config :agentic_stories, AgenticStories.LLM,
  adapter: AgenticStories.LLM.Grok,               # or AgenticStories.LLM.Claude
  weaver_model: "grok-4.6",                       # quality matters, runs once
  character_model: "grok-4.20-0309-non-reasoning", # cheap, fast, no reasoning spend
  director_model: "grok-4.6"                      # taste matters, low frequency

config :agentic_stories, AgenticStories.Imagery,
  adapter: AgenticStories.Imagery.GrokImagine,
  enabled: true              # portraits/plates are best-effort; stories work without

config :agentic_stories, AgenticStories.Engine,
  tick_interval_ms: 15_000,  # base pause between a character's ticks (plus jitter)
  tick_cost: 2,              # energy spent per tick
  player_energy: 6,          # energy a player message grants characters in the room
  ambient_energy: 2,         # trickle for characters elsewhere (off-screen life)
  chatter_energy: 1,         # energy a speaking character passes to ONE other (< tick_cost!)
  max_energy: 12,
  initial_energy: 2,         # funds exactly one reaction to the opening scene
  idle_timeout_ms: 180_000,  # agents retire this long after the last player message
  memory_window: 40,         # witnessed beats kept verbatim before consolidation
  director_interval_ms: 90_000,
  director_energy: 4,        # the Director's opening balance
  director_grant: 4,         # energy a nudge hands its character
  recap_after_ms: 6 * 60 * 60 * 1000
```

API keys are read at runtime from `XAI_API_KEY` and `ANTHROPIC_API_KEY`
(see `config/runtime.exs`). Every LLM call lands in a per-story **cost ledger**
(tokens in/out and cache hits — the sidebar shows what a story has "thought").
Prompt caching works on both providers from the same design: Anthropic gets
explicit breakpoints, xAI's automatic prefix caching rides the byte-stable
transcript prefixes — and the ledger's cached-token column proves it.

## Development

```bash
mix test           # run the test suite (needs Postgres up)
mix precommit      # compile with warnings-as-errors, format, unused deps, tests
```

The project is built test-first:

- Contexts are covered with `DataCase` tests, LiveViews with `ConnCase` +
  `Phoenix.LiveViewTest`.
- Domain and engine tests never talk to a real LLM: they use a [Mox](https://hexdocs.pm/mox)
  mock of the `AgenticStories.LLM` behaviour.
- The Claude driver itself is tested against `Req.Test` stubs — no network in the suite.
- Character agents don't auto-start in tests (`config :agentic_stories,
  AgenticStories.Engine, start_agents: false`); engine tests start them explicitly.

See `CLAUDE.md` for the project map and conventions, and `AGENTS.md` for the
Phoenix/Elixir style guidelines the codebase follows.
