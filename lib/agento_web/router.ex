defmodule AgentoWeb.Router do
  @moduledoc false
  use AgentoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AgentoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # No :accepts plug — the Accept header is repurposed for agent negotiation
  # on GET /harness, so standard content negotiation must not run here.
  pipeline :harness do
    plug :put_format, :json
  end

  scope "/", AgentoWeb do
    pipe_through :harness

    match :options, "/", HarnessController, :specification
    get "/specification", HarnessController, :specification
    get "/agents", HarnessController, :agents
    get "/toolbox", HarnessController, :toolbox
    get "/harness", HarnessController, :create
    put "/harness/:session_id", HarnessController, :interact
  end

  scope "/", AgentoWeb do
    pipe_through :browser

    # Root redirects to chat
    get "/", PageController, :home

    # R7.3 — download agent history as JSON
    get "/export/:agent", ExportController, :export

    live_session :default, on_mount: {AgentoWeb.Hooks.Observability, :default} do
      live "/chat", ChatLive
      live "/events", EventsLive
      live "/system", SystemLive
      live "/tools", ToolsLive
    end
  end
end
