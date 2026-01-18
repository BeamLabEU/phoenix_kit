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
  use PhoenixKitWeb, :html

  embed_templates "layouts/*"
end
