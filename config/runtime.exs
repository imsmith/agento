import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/agento start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :agento, AgentoWeb.Endpoint, server: true
end

# LLMAgent configuration — these flow through to LLMAgent
config :LLMAgent,
  model: System.get_env("LLMAGENT_MODEL", "llama3.2"),
  api_host: System.get_env("LLMAGENT_API_HOST", "http://localhost:11434/v1"),
  role: System.get_env("LLMAGENT_ROLE", "default")

# Start LLMAgent's mDNS discovery shim from within agento.
#
# A dependency's own config/runtime.exs is NOT evaluated when it runs as a
# library — only the top-level app's (agento's) config is. So agento must
# configure the adapter itself, and resolve the shim from LLMAgent's priv
# dir via app_dir/2 rather than File.cwd!() (which would point at agento's
# nonexistent priv/discovery path).
#
# Not in tests: the shim renews its ads for as long as it runs, so a test
# that empties the registry would see the real network's hosts reappear.
if tclsh = config_env() != :test && System.find_executable("tclsh") do
  config :LLMAgent, :discovery_adapters, [
    %{
      name: :avahi_llama,
      command: tclsh,
      args: [Application.app_dir(:LLMAgent, "priv/discovery/avahi-llama.tcl")],
      env: []
    }
  ]
end

# The listener binds every interface, over plain HTTP, unless AGENTO_BIND
# says otherwise: agento serves this network, not just this machine. Tests
# stay on loopback.
default_bind = if config_env() == :test, do: "127.0.0.1", else: "0.0.0.0"

bind =
  case System.get_env("AGENTO_BIND", default_bind) |> String.to_charlist() |> :inet.parse_address() do
    {:ok, ip} ->
      ip

    {:error, _} ->
      raise "AGENTO_BIND must be an IP address, got #{inspect(System.get_env("AGENTO_BIND"))}"
  end

# Port 0 unless PORT pins one: the OS picks a free port and busybody is told
# which. Clients find agento by name, not by a number someone has to remember.
config :agento, AgentoWeb.Endpoint,
  http: [ip: bind, port: String.to_integer(System.get_env("PORT", "0"))]

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :agento, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The bind address and port are set above, for every environment.
  config :agento, AgentoWeb.Endpoint,
    # Plain HTTP, reached by whatever name or address a client uses. The
    # LiveView socket accepts an origin that matches the host the request
    # itself was made to, rather than one fixed name. No port here: the real
    # one is whatever was bound, and busybody's client reads a port set here
    # in preference to it.
    url: [host: host, scheme: "http"],
    check_origin: :conn,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :agento, AgentoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :agento, AgentoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
