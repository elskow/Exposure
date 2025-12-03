defmodule ExposureWeb.Router do
  use ExposureWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ExposureWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(ExposureWeb.Plugs.SecurityHeaders)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :admin do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ExposureWeb.Layouts, :admin})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(ExposureWeb.Plugs.SecurityHeaders)
  end

  scope "/", ExposureWeb do
    pipe_through(:browser)

    get("/", HomeController, :index)

    get("/places/:country/:location/:name", PlaceController, :index)
    get("/places/:country/:location/:name/:photo", PlaceController, :detail)
  end

  # Admin routes
  scope "/admin", ExposureWeb do
    pipe_through(:admin)

    get("/", AdminController, :index)
    get("/login", AdminController, :login)
    post("/login", AdminController, :do_login)
    post("/logout", AdminController, :logout)

    # OIDC routes
    get("/auth/oidc", AdminController, :oidc_login)
    get("/auth/callback", AdminController, :oidc_callback)

    get("/create", AdminController, :create)
    post("/create", AdminController, :do_create)

    get("/edit/:id", AdminController, :edit)
    post("/update/:id", AdminController, :update)
    post("/delete/:id", AdminController, :delete)
    post("/places/reorder", AdminController, :reorder_places)

    get("/photos/:id", AdminController, :photos)
    post("/photos/upload", AdminController, :upload_photos)
    post("/photos/delete", AdminController, :delete_photo)
    post("/photos/reorder", AdminController, :reorder_photos)
    post("/photos/favorite", AdminController, :set_favorite)

    get("/totp-setup", AdminController, :totp_setup)
    post("/verify-totp", AdminController, :verify_totp)
    post("/disable-totp", AdminController, :disable_totp)
  end

  # Other scopes may use custom stacks.
  # scope "/api", ExposureWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:exposure, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: ExposureWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
