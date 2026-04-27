defmodule LlmagentWebWeb.Router do
  use LlmagentWebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LlmagentWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LlmagentWebWeb do
    pipe_through :browser

    # Root redirects to chat
    get "/", PageController, :home

    live_session :default, on_mount: {LlmagentWebWeb.Hooks.Observability, :default} do
      live "/chat", ChatLive
      live "/events", EventsLive
      live "/system", SystemLive
      live "/tools", ToolsLive
    end
  end
end
