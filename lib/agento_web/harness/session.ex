defmodule AgentoWeb.Harness.Session do
  @moduledoc """
  Per-session orchestration for the harness: negotiate the agent type, start the
  backing `LLMAgent` agent bound to a discovered endpoint, and (later) reconcile
  folds and drive interaction. A session IS an `LLMAgent` agent instance.
  """

  alias AgentoWeb.Harness.{Catalog, Registry}

  @default_ttl_ms 900_000
  @fallback_model "llama3.2"
  @fallback_api_host "http://localhost:11434/v1"

  @spec negotiate_agent([String.t()]) :: atom()
  def negotiate_agent(accept_values) do
    wanted =
      accept_values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim()))

    ids = Catalog.agent_ids()
    Enum.find(wanted, &(&1 in ids)) |> to_role()
  end

  @spec open(atom()) :: {:ok, map()} | {:error, term()}
  def open(agent_type) do
    {model, api_host} = endpoint()
    name = String.to_atom("hns_agent_" <> Integer.to_string(System.unique_integer([:positive])))

    opts = [
      name: name,
      role: agent_type,
      model: model,
      api_host: api_host,
      # Tool policy for harness-backed agents. The spec calls for deny-by-default;
      # this reads config so deployments can restrict it. Default is intentionally
      # permissive for now — the SAME security surface deferred for the web UI's
      # R6.3 (gate on auth). Restrict via config/runtime.exs before exposing the
      # API off a trusted network. `:all` or a list of tool atoms.
      allowed_tools: Application.get_env(:agento, :harness_allowed_tools, :all)
    ]

    case LLMAgent.AgentSupervisor.start_agent(opts) do
      {:ok, _pid} ->
        {:ok, session} = Registry.create(name, @default_ttl_ms)
        {:ok, Map.put(session, :agent_type, agent_type)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fold_token(non_neg_integer()) :: String.t()
  def fold_token(n), do: "fold_#{n}"

  @spec parse_fold(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_fold("fold_" <> n) do
    case Integer.parse(n) do
      {i, ""} when i >= 0 -> {:ok, i}
      _ -> :error
    end
  end

  def parse_fold(_), do: :error

  @spec context_hash(list()) :: String.t()
  def context_hash(context) do
    :crypto.hash(:sha256, :erlang.term_to_binary(context)) |> Base.url_encode64(padding: false)
  end

  @spec reconcile(String.t(), String.t(), list()) ::
          {:process, String.t()} | {:replay, [map()]} | {:diverged, String.t()} | {:error, :not_found}
  def reconcile(session_id, fold_str, context) do
    with {:ok, fold} <- parse_fold(fold_str),
         {:ok, current} <- Registry.current_fold(session_id) do
      hash = context_hash(context)

      cond do
        fold == current ->
          {:process, last_user_content(context)}

        match?({:ok, _}, Registry.replay(session_id, fold, hash)) ->
          {:ok, frames} = Registry.replay(session_id, fold, hash)
          {:replay, frames}

        true ->
          {:diverged, fold_token(current)}
      end
    else
      :error -> {:diverged, "fold_0"}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp last_user_content(context) do
    context
    |> Enum.reverse()
    |> Enum.find(&(&1["role"] == "user"))
    |> case do
      %{"content" => c} -> c
      _ -> ""
    end
  end

  defp to_role(nil), do: :default
  defp to_role(id), do: String.to_existing_atom(id)

  defp endpoint do
    case AgentoWeb.Discovery.Endpoints.list() do
      [%{model: m, api_host: h} | _] -> {m, h}
      _ -> {@fallback_model, @fallback_api_host}
    end
  end
end
