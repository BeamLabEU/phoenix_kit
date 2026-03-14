defmodule PhoenixKitWeb.Components.AuthPageWrapper do
  @moduledoc """
  Wrapper component for all auth pages (login, registration, etc.).

  Reads branding settings (logo, background image/color) from Settings
  and renders a consistent layout with optional custom branding.
  """
  use Phoenix.Component

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Components.LayoutWrapper

  attr :flash, :map, required: true
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :page_title, :string, required: true
  slot :inner_block, required: true

  def auth_page_wrapper(assigns) do
    assigns =
      assigns
      |> assign_new(:auth_logo_url, fn ->
        case Settings.get_setting("auth_logo_file_uuid", "") do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "medium")
          _ -> ""
        end
      end)
      |> assign_new(:auth_bg_image, fn ->
        case Settings.get_setting("auth_background_image_file_uuid", "") do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "original")
          _ -> ""
        end
      end)
      |> assign_new(:auth_bg_color, fn -> Settings.get_setting("auth_background_color", "") end)
      |> assign_new(:project_title, fn -> Settings.get_project_title() end)

    ~H"""
    <LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
    >
      <div
        class="flex items-center justify-center px-4 py-8 min-h-[80vh]"
        style={bg_style(@auth_bg_image, @auth_bg_color)}
      >
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <%= if @auth_logo_url != "" do %>
              <div class="flex justify-center mb-6">
                <img src={@auth_logo_url} alt={@project_title} class="h-12 object-contain" />
              </div>
            <% end %>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </LayoutWrapper.app_layout>
    """
  end

  defp bg_style("", ""), do: nil

  defp bg_style(image_url, _color) when image_url != "" do
    "background-image: url('#{image_url}'); background-size: cover; background-position: center;"
  end

  defp bg_style("", color), do: "background: #{color};"
end
