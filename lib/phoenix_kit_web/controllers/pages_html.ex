defmodule PhoenixKitWeb.PagesHTML do
  @moduledoc """
  Renders public pages from markdown files.
  """
  use PhoenixKitWeb, :html

  embed_templates "pages_html/*"
end
