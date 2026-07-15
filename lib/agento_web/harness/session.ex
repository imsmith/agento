defmodule AgentoWeb.Harness.Session do
  @moduledoc """
  Session orchestration for the harness: negotiate the agent type, open a
  session **record** (not a process), and reconcile folds.

  A session is web-tier state — a record in `Harness.Registry` holding the
  chosen agent type, endpoint, tool policy, and the canonical conversation.
  Turns run as function calls over that record (`Harness.Turn`); nothing is
  spawned or named per session.
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

  @spec open(atom()) :: {:ok, map()}
  def open(agent_type) do
    {model, api_host} = endpoint()

    config = %{
      agent_type: agent_type,
      model: model,
      api_host: api_host,
      # Tool policy for harness turns. The spec calls for deny-by-default; this
      # reads config so deployments can restrict it. Default is intentionally
      # permissive for now — the SAME security surface deferred for the web UI's
      # R6.3 (gate on auth). Restrict via config/runtime.exs before exposing the
      # API off a trusted network. `:all` or a list of tool atoms.
      allowed_tools: Application.get_env(:agento, :harness_allowed_tools, :all),
      # The LLM client the turn loop uses. Test env overrides this via
      # `config :agento, :harness_llm_client, AgentoWeb.TestLLMClient`.
      llm_client: Application.get_env(:agento, :harness_llm_client, LLMAgent.LLMClient.OpenAI)
    }

    history = [%{role: "system", content: LLMAgent.RolePrompt.get(agent_type)}]
    Registry.create(config, history, @default_ttl_ms)
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
    case Registry.current_fold(session_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, current} ->
        reconcile_known(session_id, fold_str, context, current)
    end
  end

  defp reconcile_known(session_id, fold_str, context, current) do
    case parse_fold(fold_str) do
      :error ->
        {:diverged, fold_token(current)}

      {:ok, ^current} ->
        {:process, last_user_content(context)}

      {:ok, fold} ->
        case Registry.replay(session_id, fold, context_hash(context)) do
          {:ok, frames} -> {:replay, frames}
          :miss -> {:diverged, fold_token(current)}
        end
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
