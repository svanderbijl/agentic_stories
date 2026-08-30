defmodule AgenticStoriesWeb.Router do
  use AgenticStoriesWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AgenticStoriesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AgenticStoriesWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/stories/:id", StoryLive, :show
    get "/stories/:id/read", ReaderController, :show
    get "/avatars/:id", AvatarController, :show
    get "/player-avatars/:id", AvatarController, :player
    get "/boards/:id", BoardController, :show
    get "/player-boards/:id", BoardController, :player
    get "/plates/:id", PlateController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", AgenticStoriesWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:agentic_stories, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AgenticStoriesWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
