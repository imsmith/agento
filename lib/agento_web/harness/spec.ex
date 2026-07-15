defmodule AgentoWeb.Harness.Spec do
  @moduledoc """
  Builds the OpenAPI 3.x document describing the harness API. Returned by
  `GET /specification` and `OPTIONS /`. Authored here rather than checked in as
  a static file so it ships with the code that implements it.
  """

  @spec document() :: map()
  def document do
    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "Agento Harness API",
        "version" => "0",
        "description" => "Self-describing, multi-tenant harness over LLMAgent."
      },
      "paths" => %{
        "/specification" => %{"get" => op("Return this OpenAPI document.")},
        "/agents" => %{"get" => op("List instantiable agent types.")},
        "/toolbox" => %{"get" => op("List available tools.")},
        "/harness" => %{
          "get" =>
            op("Provision a session. Agent type negotiated via the Accept header.", %{
              "201" => %{"description" => "Session created"}
            })
        },
        "/harness/{session_id}" => %{
          "put" =>
            op("Interact: PUT context-since-fold; stream NDJSON result frames.", %{
              "200" => %{"description" => "NDJSON stream"},
              "404" => %{"description" => "Unknown session"},
              "409" => %{"description" => "Fold diverged"}
            })
        }
      }
    }
  end

  defp op(summary), do: op(summary, %{"200" => %{"description" => "OK"}})
  defp op(summary, responses), do: %{"summary" => summary, "responses" => responses}
end
