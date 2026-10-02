defmodule Agento.Hub.Config do
  @moduledoc """
  The hub's operator configuration: which clients may connect, and how turns
  are routed and kept.

  Read once at boot from an edn file — `AGENTO_HUB_CONFIG`, else
  `~/.config/agento/hub.edn` — and held for the life of the node:

      {:clients [{:name "claude-code" :token "…"}]
       :default-host "skynet001.local"
       :retention-days 30
       :performer-timeout-seconds 900
       :data-dir "~/.local/share/agento"}

  The file holds bearer tokens, so one that anyone but its owner can read is
  refused. A missing file is not an error: the hub then has no clients and
  refuses every request.

  ## Every client is local-only

  Each client gets a `%LLMAgent.Tool.Policy{}` that admits only
  `compute.llm.chat` ads whose provenance is the mDNS shim. The provenance
  constraint is never left `nil`, which would mean "no filtering". This build
  has no cloud forwarding, so a client record carrying `:cloud true` is
  refused rather than ignored: a setting that asks for paid forwarding must
  never be silently accepted.

  The listener's address and port are not here. Phoenix needs them before
  this file can be read; they come from `AGENTO_BIND` and `PORT`.

  `EDN.decode/1` creates atoms for keywords it has not seen, which is why it
  is used on this file and never on anything a client sends.
  """

  import Bitwise

  alias LLMAgent.Tool.Policy

  @local_sources ["mdns/_llama._tcp"]
  @min_token_bytes 16
  @known_keys [
    :clients,
    :"default-host",
    :"retention-days",
    :"performer-timeout-seconds",
    :"data-dir"
  ]
  @client_keys [:name, :token, :cloud]

  @enforce_keys [:clients, :default_host, :retention_days, :performer_timeout_ms, :data_dir]
  defstruct [:clients, :default_host, :retention_days, :performer_timeout_ms, :data_dir]

  @type client :: %{name: String.t(), token: String.t(), policy: Policy.t()}

  @type t :: %__MODULE__{
          clients: [client()],
          default_host: String.t() | nil,
          retention_days: pos_integer(),
          performer_timeout_ms: pos_integer(),
          data_dir: String.t()
        }

  @doc "Where the configuration is read from."
  @spec path() :: String.t()
  def path do
    Application.get_env(:agento, :hub_config_path) ||
      System.get_env("AGENTO_HUB_CONFIG") ||
      Path.expand("~/.config/agento/hub.edn")
  end

  @doc "The configuration loaded at boot."
  @spec get() :: t()
  def get, do: :persistent_term.get(__MODULE__)

  @doc "Install a configuration. Called once at boot, and by tests."
  @spec put(t()) :: :ok
  def put(%__MODULE__{} = config), do: :persistent_term.put(__MODULE__, config)

  @doc """
  Load and validate the file at `path`. Every failure is `{:error, message}`
  with a message an operator can act on; no message contains a token.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    case File.stat(path) do
      {:error, :enoent} -> build(%{})
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
      {:ok, %File.Stat{mode: mode}} -> load_file(path, mode)
    end
  end

  defp load_file(path, mode) when (mode &&& 0o077) != 0 do
    {:error,
     "#{path} has mode #{Integer.to_string(mode &&& 0o777, 8)}; it holds tokens and must be readable " <>
       "by its owner only (chmod 600)"}
  end

  defp load_file(path, _mode) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = edn} when not is_struct(edn) <- EDN.decode(text) do
      build(edn)
    else
      {:ok, _not_a_map} ->
        {:error, "#{path}: the top level must be an edn map"}

      {:error, %{__exception__: true} = error} ->
        {:error, "#{path}: malformed edn: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp build(edn) do
    with :ok <- known_keys(edn, @known_keys, "top-level key"),
         {:ok, clients} <- clients(Map.get(edn, :clients, [])),
         {:ok, default_host} <- optional_string(edn, :"default-host"),
         {:ok, retention} <- positive_integer(edn, :"retention-days", 30),
         {:ok, timeout} <- positive_integer(edn, :"performer-timeout-seconds", 900),
         {:ok, data_dir} <- optional_string(edn, :"data-dir") do
      {:ok,
       %__MODULE__{
         clients: clients,
         default_host: default_host,
         retention_days: retention,
         performer_timeout_ms: timeout * 1_000,
         data_dir: Path.expand(data_dir || "~/.local/share/agento")
       }}
    end
  end

  defp known_keys(map, known, what) do
    case Map.keys(map) -- known do
      [] -> :ok
      [key | _] -> {:error, "unknown #{what} #{inspect(key)}"}
    end
  end

  defp optional_string(edn, key) do
    case Map.get(edn, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp positive_integer(edn, key, default) do
    case Map.get(edn, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp clients(%EDN.Vector{} = vector), do: clients(Enum.to_list(vector))

  defp clients(list) when is_list(list) do
    with {:ok, clients} <- each_client(list, []),
         :ok <- unique(clients, :name, fn name -> "two clients are named #{inspect(name)}" end),
         :ok <-
           unique(clients, :token, fn _token ->
             "two clients share a token; each client needs its own"
           end) do
      {:ok, clients}
    end
  end

  defp clients(_other), do: {:error, "clients must be a vector of client maps"}

  defp each_client([], acc), do: {:ok, Enum.reverse(acc)}

  defp each_client([record | rest], acc) do
    case client(record) do
      {:ok, client} -> each_client(rest, [client | acc])
      {:error, _} = error -> error
    end
  end

  defp client(%{name: name} = record) when is_binary(name) and name != "" do
    token = Map.get(record, :token)

    cond do
      Map.keys(record) -- @client_keys != [] ->
        {:error,
         "client #{inspect(name)}: unknown key #{inspect(hd(Map.keys(record) -- @client_keys))}"}

      Map.get(record, :cloud, false) != false ->
        {:error,
         "client #{inspect(name)}: cloud forwarding is not available in this build; remove :cloud or set it to false"}

      not is_binary(token) or byte_size(token) < @min_token_bytes ->
        {:error,
         "client #{inspect(name)}: token must be a string of at least #{@min_token_bytes} characters"}

      true ->
        {:ok, %{name: name, token: token, policy: local_policy()}}
    end
  end

  defp client(_record), do: {:error, "every client needs a non-empty string :name"}

  defp unique(clients, key, message) do
    values = Enum.map(clients, &Map.fetch!(&1, key))

    case values -- Enum.uniq(values) do
      [] -> :ok
      [duplicate | _] -> {:error, message.(duplicate)}
    end
  end

  defp local_policy do
    %Policy{
      allow: ["compute.llm.chat"],
      fidelity_min: :authoritative,
      provenance: %{source: @local_sources, signed: false}
    }
  end

  @doc """
  The client a bearer token belongs to. Every client is compared, in constant
  time, so how long this takes says nothing about which token came close.
  """
  @spec client_for_token(t(), String.t() | nil) :: {:ok, client()} | :error
  def client_for_token(%__MODULE__{clients: clients}, token)
      when is_binary(token) and token != "" do
    clients
    |> Enum.filter(&Plug.Crypto.secure_compare(&1.token, token))
    |> case do
      [client] -> {:ok, client}
      _ -> :error
    end
  end

  def client_for_token(%__MODULE__{}, _token), do: :error
end
