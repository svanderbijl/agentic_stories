# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# LLM provider port: which driver to use and which models each part of the
# engine talks to. The Weaver gets a capable model; character ticks run on a
# cheap/fast one.
# Text provider: Venice.ai (uncensored). The Weaver and Director get Venice's
# smart uncensored reasoning model; characters run on the cheap non-reasoning
# uncensored tier — no hidden reasoning tokens, the cost lever that matters
# at tick frequency ("venice-uncensored-role-play" is the pricier
# roleplay-tuned alternative). The other drivers remain available:
#   AgenticStories.LLM.Grok — xAI direct, e.g. weaver_model: "grok-4.6",
#     character_model: "grok-4.20-0309-non-reasoning"
#   AgenticStories.LLM.Claude — Anthropic direct, e.g. "claude-opus-5" /
#     "claude-haiku-4-5"
#   AgenticStories.LLM.OpenRouter — one key, any model via OpenRouter slugs,
#     e.g. "x-ai/grok-4.6" or the Venice-hosted
#     "cognitivecomputations/dolphin-mistral-24b-venice-edition"
config :agentic_stories, AgenticStories.LLM,
  adapter: AgenticStories.LLM.Venice,
  weaver_model: "qwen-3-6-plus",
  character_model: "venice-uncensored-1-2",
  director_model: "qwen-3-6-plus"

# Image provider port: paints character avatars after a story is woven.
# Venice.ai renders photorealistic, uncensored portraits and plates
# (AgenticStories.Imagery.GrokImagine remains available for xAI).
# Runs only when enabled AND the driver has its key (VENICE_API_KEY at
# runtime); stories work fine without it — the UI falls back to
# initial-letter marks.
config :agentic_stories, AgenticStories.Imagery,
  adapter: AgenticStories.Imagery.Venice,
  enabled: true

# The energy model. Ticks cost energy; the player is the only net source of
# it. A speaking character passes chatter_energy to ONE other cast member (the
# torch). Invariant: chatter_energy < tick_cost, so every tick strictly drains
# the cast and scenes provably decay to silence at any cast size. A player
# message funds ~three beats per character (player_energy / tick_cost);
# initial_energy funds exactly one reaction to the opening scene. Agents
# retire idle_timeout_ms after the last player message, energy or not.
config :agentic_stories, AgenticStories.Engine,
  start_agents: true,
  tick_interval_ms: 15_000,
  tick_cost: 2,
  player_energy: 6,
  ambient_energy: 2,
  chatter_energy: 1,
  max_energy: 12,
  initial_energy: 2,
  idle_timeout_ms: 180_000,
  # Verbatim witnessed beats per character: up to 2x this before a chunk is
  # consolidated into long-term memory. Generous on purpose — the byte-stable
  # transcript prefix is served from provider prompt caches at a fraction of
  # the input rate, so a big window is cheap and context is what makes a story.
  memory_window: 150,
  # The Director: a slow, omniscient agent that supplies plot pressure —
  # narration, nudges, new places, and (eventually) the ending. The grant is
  # what a nudge hands its character: enough for three beats of the impulse.
  director_interval_ms: 60_000,
  director_energy: 4,
  director_grant: 6,
  # A "Previously…" recap greets a player returning after this long.
  recap_after_ms: 6 * 60 * 60 * 1000

config :agentic_stories,
  ecto_repos: [AgenticStories.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :agentic_stories, AgenticStoriesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AgenticStoriesWeb.ErrorHTML, json: AgenticStoriesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AgenticStories.PubSub,
  live_view: [signing_salt: "nd8fzW7/"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :agentic_stories, AgenticStories.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  agentic_stories: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  agentic_stories: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
