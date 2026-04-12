# PHOENIX KIT - LANDING PAGE FOR UNAUTHENTICATED USERS WITH REDIRECT 

The problem: We want a landing page that only unauth users can see and to redirect all auth users to phoenix-kit dashboard.

Don't try to use `PhoenixKitWeb.Users.Auth` as a plug directly. Instead, use the routes that phoenix_kit_routes() macro adds, which already handles auth.

## Solution: Don't add custom auth logic - Just use what Phoenix Kit provides!

```elixir
# lib/myapp_web/router.ex

defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Root route - simple, no auth check
  scope "/", MyAppWeb do
    pipe_through :browser
    get "/", PageController, :index
  end

  # Phoenix Kit provides these already:
  # /phoenix_kit/users/log-in
  # /phoenix_kit/users/register
  # /phoenix_kit/dashboard
  # /phoenix_kit/admin
  # And all auth handling is built-in
  phoenix_kit_routes()

  if Mix.env() == :dev do
    scope "/__phoenix" do
      pipe_through :browser
      forward "/live_dashboard", Phoenix.LiveDashboard.Router.init(metrics: MyAppWeb.Telemetry)
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
```

## PageController - Handle the redirect

```elixir
# lib/myapp_web/controllers/page_controller.ex

defmodule MyAppWeb.PageController do
  use MyAppWeb, :controller

  def index(conn, _params) do
    # For now, just show the landing page
    # Check the session to see if user is logged in
    case get_session(conn, "user_token") do
      nil ->
        # Not logged in - show landing page
        render(conn, :index)

      _token ->
        # Logged in - redirect to Phoenix Kit dashboard
        redirect(conn, to: PhoenixKit.Utils.Routes.path("/dashboard"))
    end
  end
end
```

## Page View - Landing page

```elixir
# lib/myapp_web/controllers/page_html.ex

defmodule MyAppWeb.PageHTML do
  use MyAppWeb, :html

  def index(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100">
      <div class="max-w-7xl mx-auto px-4 py-20">
        <h1 class="text-4xl font-bold text-gray-900 mb-4">
          Welcome to MyApp
        </h1>
        <p class="text-xl text-gray-600 mb-8">
          Built with Phoenix Kit
        </p>

        <div class="space-x-4">
          <.link
            navigate={~p"/phoenix_kit/users/log-in"}
            class="inline-block px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700"
          >
            Sign In
          </.link>

          <.link
            navigate={~p"/phoenix_kit/users/register"}
            class="inline-block px-6 py-3 bg-white text-blue-600 border border-blue-600 rounded-lg"
          >
            Sign Up
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
```

## That's it!

Phoenix Kit already provides:
- ✅ Login page at `/phoenix_kit/users/log-in`
- ✅ Register page at `/phoenix_kit/users/register`
- ✅ Dashboard at `/phoenix_kit/dashboard` (authenticated)
- ✅ Admin panel at `/phoenix_kit/admin`
- ✅ All session management
- ✅ Email confirmation
- ✅ Password reset
- ✅ OAuth providers

## How it works:

1. User visits `/` → sees landing page
2. User clicks "Sign In" → goes to `/phoenix_kit/users/log-in` (handled by Phoenix Kit)
3. User logs in → Phoenix Kit creates session and redirects to `/phoenix_kit/dashboard`
4. User visits `/` again → PageController sees session token and redirects to `/phoenix_kit/dashboard`
5. User is logged in and can access all Phoenix Kit features

## Testing:

```bash
# Start Phoenix
mix phx.server

# 1. Visit http://localhost:4000
# You should see your landing page

# 2. Click "Sign In"
# You should go to /phoenix_kit/users/log-in (Phoenix Kit's login)

# 3. Login with your account
# You should go to /phoenix_kit/dashboard

# 4. Visit http://localhost:4000 again
# You should be redirected to /phoenix_kit/dashboard

# 5. You can access all Phoenix Kit features at /phoenix_kit/*
```

## Key Point:

Don't try to add custom auth plugs. Phoenix Kit is ALREADY a complete auth system.
Just use `phoenix_kit_routes()` and check the session token to redirect on the root route.

That's all you need!