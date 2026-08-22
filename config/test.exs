import Config

# The suite never talks to a real LLM: domain and engine tests go through the
# Mox mock of the AgenticStories.LLM behaviour, and the Claude driver's own
# tests route HTTP through Req.Test.
config :agentic_stories, AgenticStories.LLM, adapter: AgenticStories.LLM.Mock

config :agentic_stories, AgenticStories.LLM.Claude,
  api_key: "test-key",
  plug: {Req.Test, AgenticStories.LLM.Claude}

config :agentic_stories, AgenticStories.LLM.Grok,
  api_key: "test-key",
  plug: {Req.Test, AgenticStories.LLM.Grok}

config :agentic_stories, AgenticStories.LLM.OpenRouter,
  api_key: "test-key",
  plug: {Req.Test, AgenticStories.LLM.OpenRouter}

config :agentic_stories, AgenticStories.LLM.Venice,
  api_key: "test-key",
  plug: {Req.Test, AgenticStories.LLM.Venice}

# Avatars are off by default in tests; avatar-flow tests flip :enabled and
# expect on AgenticStories.Imagery.Mock themselves.
config :agentic_stories, AgenticStories.Imagery,
  adapter: AgenticStories.Imagery.Mock,
  enabled: false

config :agentic_stories, AgenticStories.Imagery.GrokImagine,
  api_key: "test-key",
  plug: {Req.Test, AgenticStories.Imagery.GrokImagine}

config :agentic_stories, AgenticStories.Imagery.Venice,
  api_key: "test-key",
  plug: {Req.Test, AgenticStories.Imagery.Venice}

# Character agents never auto-start in tests; engine tests start them
# explicitly and drive ticks by hand (the huge interval keeps scheduled ticks
# from ever firing on their own).
config :agentic_stories, AgenticStories.Engine,
  start_agents: false,
  tick_interval_ms: 60_000

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :agentic_stories, AgenticStories.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "agentic_stories_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :agentic_stories, AgenticStoriesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tU6P7V4wodxiMRfSbUDJ6TnmzgUk69ooUAKaLtREH/smpkbiu1AU6AqO5NU6LrL+",
  server: false

# In test we don't send emails
config :agentic_stories, AgenticStories.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
