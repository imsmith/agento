import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :agento, AgentoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kJSgFAAkn3aLw4T7YmeaB1mPBobAz53+hSRZnCFkg6nMpZCK6XlqJgpiMwqf/92n",
  server: false

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

# LLMAgent test config — use TestLLMClient, point at no real LLM
config :LLMAgent,
  model: "test-model",
  api_host: "http://localhost:11434/v1",
  role: "sysadmin",
  llm_client: AgentoWeb.TestLLMClient

# LLMAgent.init reads :llm_client from start opts, not app config, so
# AgentoWeb.Harness.Session.open/1 threads this through explicitly.
config :agento, harness_llm_client: AgentoWeb.TestLLMClient
