defmodule AgentoWeb.ExportController do
  @moduledoc false
  use AgentoWeb, :controller

  def export(conn, %{"agent" => agent_str} = params) do
    kind = Map.get(params, "kind", "events")

    with {:ok, agent} <- to_agent_atom(agent_str),
         {:ok, payload, suffix} <- fetch_payload(agent, kind) do
      filename = "#{agent_str}-#{suffix}.json"
      body = payload |> to_jsonable() |> Jason.encode!(pretty: true)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, body)
    else
      {:error, :unknown_agent} ->
        send_resp(conn, 404, "unknown agent")

      {:error, :unknown_kind} ->
        send_resp(conn, 400, "kind must be 'events' or 'messages'")
    end
  end

  defp to_agent_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> {:error, :unknown_agent}
  end

  defp fetch_payload(agent, "events"), do: {:ok, LLMAgent.DurableLog.events_for(agent), "events"}
  defp fetch_payload(agent, "messages"), do: {:ok, LLMAgent.DurableLog.messages_for(agent), "messages"}
  defp fetch_payload(_agent, _kind), do: {:error, :unknown_kind}

  defp to_jsonable(%_{} = struct), do: struct |> Map.from_struct() |> to_jsonable()
  defp to_jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, to_jsonable(v)} end)
  defp to_jsonable(list) when is_list(list), do: Enum.map(list, &to_jsonable/1)
  defp to_jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> to_jsonable()
  defp to_jsonable(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp to_jsonable(pid) when is_pid(pid), do: inspect(pid)
  defp to_jsonable(ref) when is_reference(ref), do: inspect(ref)
  defp to_jsonable(other), do: other
end
