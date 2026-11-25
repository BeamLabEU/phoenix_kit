defmodule PhoenixKitWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use PhoenixKitWeb, :controller` and
  `use PhoenixKitWeb, :live_view`.

  ## Performance: Avoiding Unnecessary Layout Diffs

  When using the dashboard layout, **do not pass all assigns**:

      # ❌ BAD - triggers layout diff on ANY assign change
      <PhoenixKitWeb.Layouts.dashboard {assigns}>

      # ✅ GOOD - only passes assigns the layout uses
      <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>

  The `dashboard_assigns/1` function (from `PhoenixKitWeb.LayoutHelpers`)
  extracts only the assigns the layout actually needs, preventing unnecessary
  network traffic when other assigns (like application-specific data) change.

  See `PhoenixKitWeb.LayoutHelpers` for more details.
  """
  @compile {:no_warn_undefined,
            [PhoenixKit.Modules.Legal, PhoenixKit.Modules.Legal.CookieConsent]}

  use PhoenixKitWeb, :html

  embed_templates "layouts/*"

  @kit_bundles ["/assets/vendor/phoenix_kit.js", "/assets/vendor/phoenix_kit_modules.js"]

  @doc """
  The kit's script files the host serves, for the fallback root layout to load before `app.js`.

  The installer puts these two tags in the host's own root layout. When a page is rendered with
  the kit's root layout instead, nothing loaded `phoenix_kit.js` unless the host's `app.js`
  imports it, and the kit's markup depends on that file (hooks, and the listeners that replaced
  its inline event handlers). So the fallback root asks the host's endpoint which of the two
  files it has (`priv/static/assets/vendor/`, written by the `:phoenix_kit_js_sources`
  compiler) and loads those. A host that also imports the bundle in `app.js` runs it twice,
  which the file makes a no-op (`__pkBundleLoads`).

  `[]` when the connection has no endpoint or the host has neither file.
  """
  @spec kit_bundle_paths(Plug.Conn.t() | term) :: [String.t()]
  def kit_bundle_paths(%Plug.Conn{private: %{phoenix_endpoint: endpoint}})
      when is_atom(endpoint) do
    with true <- function_exported?(endpoint, :config, 1),
         otp_app when is_atom(otp_app) and not is_nil(otp_app) <- endpoint.config(:otp_app),
         dir when is_binary(dir) <- static_dir(otp_app) do
      kit_bundle_paths(endpoint, dir)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  def kit_bundle_paths(_conn), do: []

  @doc false
  # The files of `static_dir` (the host's `priv/static`), as the endpoint serves them.
  @spec kit_bundle_paths(module, String.t()) :: [String.t()]
  def kit_bundle_paths(endpoint, static_dir) when is_atom(endpoint) and is_binary(static_dir) do
    for path <- @kit_bundles,
        File.regular?(Path.join(static_dir, path)),
        do: endpoint.static_path(path)
  end

  defp static_dir(otp_app) do
    case :code.priv_dir(otp_app) do
      {:error, _} -> nil
      priv -> Path.join(to_string(priv), "static")
    end
  end
end
