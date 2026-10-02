defmodule Agento.Hub.RouteVerb do
  @moduledoc """
  `HUB`, the module a routing rule answers through.

      [HUB::route :host "skynet001.local"]   ; or :model "x.gguf", or :ad_id "..."
      [HUB::refuse :because "not during the backup window"]

  Bound in the `:agento` runtime from the start. A verb here decides
  nothing: it records an answer, tagged as this module's, and
  `Agento.Hub.Router` reads the answers a `HUB_ROUTE` dispatch produced.
  """

  @behaviour Anemos.Runtime.Module

  @impl true
  def handle_verb("route", args, _context) do
    with {:ok, pairs} <- pairs(args) do
      case Map.take(pairs, ["host", "model", "ad_id"]) do
        choice when map_size(choice) == 1 -> {:ok, %{hub: :route, choice: choice}}
        _ -> {:error, :route_takes_one_of_host_model_ad_id}
      end
    end
  end

  def handle_verb("refuse", args, _context) do
    with {:ok, pairs} <- pairs(args) do
      {:ok, %{hub: :refuse, because: Map.get(pairs, "because", "refused by a rule")}}
    end
  end

  def handle_verb(_verb, _args, _context), do: {:error, :unknown_verb}

  defp pairs(args) do
    if rem(length(args), 2) == 0 and Enum.all?(Enum.take_every(args, 2), &is_binary/1) do
      {:ok, args |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)}
    else
      {:error, :args_must_be_key_value_pairs}
    end
  end
end
