defmodule AgentoWeb.Discovery.Endpoints do
  @moduledoc """
  Surfaces LAN-discovered LLM chat endpoints for the UI.

  llmagent browses mDNS (`_llama._tcp`) and registers each reachable
  server as a tool ad at coordinate `compute.llm.chat`. This module reads
  those ads from `LLMAgent.Tools.Discovery` and projects each into a flat
  option map the new-agent dialog can render and submit.

  `list/0` returns the current endpoints; `subscribe/1` registers the caller
  for change notifications so a LiveView dropdown can stay live as servers
  come and go, rather than snapshotting once at mount.

  Projection also normalizes each `api_host` into a dialable URL: bare IPv6
  literals are bracketed, and unroutable IPv6 link-local (`fe80::/10`)
  addresses are dropped.

  Provides a stable interface for LiveViews to query and watch available
  endpoints without coupling directly to LLMAgent's ad internals.
  """

  @coordinate "compute.llm.chat"

  @type endpoint :: %{
          id: String.t(),
          api_host: String.t(),
          model: String.t(),
          label: String.t()
        }

  @doc """
  Returns the currently discovered LLM endpoints as option maps.

  Each map contains: id, api_host, model, label. Returns an empty list
  if discovery is unavailable.
  """
  @spec list() :: [endpoint()]
  def list do
    query_ads()
    |> Enum.map(&to_endpoint/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Subscribe `pid` to `compute.llm.chat` discovery changes.

  On each change llmagent's Discovery sends `pid` a message of the form
  `{event, ad_id, coordinate}` where `event` is one of `:tool_added`,
  `:tool_updated`, `:unregistered`, or `:lease_expired`. The subscriber
  should re-query `list/0` and re-render. Degrades to `:ok` (no
  subscription) if Discovery is unavailable, so a LiveView still mounts.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid) when is_pid(pid) do
    LLMAgent.Tools.Discovery.subscribe(
      LLMAgent.ToolQuery.new(%{coordinate: @coordinate}),
      pid
    )

    :ok
  rescue
    # Discovery module not loaded / not started — mount without live updates.
    _e in [ArgumentError, UndefinedFunctionError] -> :ok
  end

  @doc """
  The discovery change events a subscriber may receive via `subscribe/1`.
  """
  @spec change_events() :: [atom()]
  def change_events, do: [:tool_added, :tool_updated, :unregistered, :lease_expired]

  # -- Private --

  defp query_ads do
    {:ok, ads} =
      LLMAgent.Tools.Discovery.find_all(
        LLMAgent.ToolQuery.new(%{coordinate: @coordinate})
      )

    ads
  rescue
    # Discovery ETS table absent, unexpected ad shape, or module not loaded
    # — degrade to "no endpoints" rather than crash the LiveView.
    _e in [ArgumentError, MatchError, UndefinedFunctionError] -> []
  end

  defp to_endpoint(%{id: id, binding: {:openai_chat, %{api_host: host} = payload}} = ad) do
    case normalize_api_host(host) do
      nil ->
        nil

      normalized ->
        model = payload[:model] || get_in(ad.operational || %{}, [:model_id]) || ""
        %{id: to_string(id), api_host: normalized, model: model, label: "#{model} @ #{normalized}"}
    end
  end

  defp to_endpoint(_), do: nil

  # Normalize a discovered api_host into a dialable URL, or nil if it can't be
  # dialed. The mDNS shim joins address and port as `scheme://addr:port` with
  # no brackets, so IPv6 literals arrive malformed. Bracket them; drop IPv6
  # link-local (fe80::/10), which is unroutable without a zone id.
  defp normalize_api_host(host) when is_binary(host) do
    case String.split(host, "://", parts: 2) do
      [scheme, rest] -> normalize_authority(scheme, rest, host)
      [_only] -> host
    end
  end

  defp normalize_api_host(_), do: nil

  # `rest` is the authority `addr:port`. Already-bracketed IPv6 and non-IPv6
  # (IPv4, hostname) pass through unchanged; a bare IPv6 literal gets bracketed
  # unless it is link-local, in which case it is undialable and dropped.
  defp normalize_authority(scheme, rest, original) do
    cond do
      String.contains?(rest, "]") ->
        original

      true ->
        case split_host_port(rest) do
          {addr, port} -> bracket_ipv6(scheme, addr, port, original)
          :error -> original
        end
    end
  end

  defp bracket_ipv6(scheme, addr, port, original) do
    cond do
      not String.contains?(addr, ":") -> original
      link_local?(addr) -> nil
      true -> "#{scheme}://[#{addr}]:#{port}"
    end
  end

  # Split on the trailing `:port` only; the host is everything before it.
  defp split_host_port(rest) do
    case rest |> String.split(":") |> Enum.reverse() do
      [port | host_parts] ->
        if port =~ ~r/^\d+$/ do
          {host_parts |> Enum.reverse() |> Enum.join(":"), port}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp link_local?(addr), do: String.downcase(addr) =~ ~r/^fe[89ab][0-9a-f]:/
end
