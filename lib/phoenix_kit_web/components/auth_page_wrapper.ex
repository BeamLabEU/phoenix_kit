defmodule PhoenixKitWeb.Components.AuthPageWrapper do
  @moduledoc """
  Wrapper component for all auth pages (login, registration, etc.).

  Reads branding settings (logo, background image/color) from Settings
  and renders a consistent layout with optional custom branding.
  Supports separate background images for desktop and mobile viewports.

  The language switcher under the form is drawn when the
  `auth_language_switcher_enabled` setting is on (the default), the Languages
  system is on and more than one language is enabled. A caller can override all
  of that for one page with the `show_language_switcher` attribute.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.CssValue
  alias PhoenixKitWeb.Components.Core.DevNotice
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher
  alias PhoenixKitWeb.Components.LayoutWrapper

  attr :flash, :map, required: true
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :page_title, :string, required: true
  attr :current_path, :string, default: nil

  attr :show_language_switcher, :boolean,
    doc:
      "Forces the language switcher on or off. When not given, the `auth_language_switcher_enabled` setting and the enabled languages decide."

  attr :dev_mailbox_message, :string,
    default: nil,
    doc:
      "If set, renders <.dev_mailbox_notice message={...} /> below the card in local-mailer dev mode."

  slot :inner_block, required: true

  def auth_page_wrapper(assigns) do
    assigns =
      assigns
      |> assign_new(:auth_logo_url, fn ->
        case Settings.get_logo_uuid() do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "medium")
          _ -> ""
        end
      end)
      |> assign_new(:auth_bg_image, fn ->
        case Settings.get_setting("auth_background_image_file_uuid", "") do
          uuid when is_binary(uuid) and uuid != "" ->
            CssValue.url(URLSigner.signed_url(uuid, "original"))

          _ ->
            ""
        end
      end)
      |> assign_new(:auth_bg_image_mobile, fn ->
        case Settings.get_setting("auth_background_image_mobile_file_uuid", "") do
          uuid when is_binary(uuid) and uuid != "" ->
            CssValue.url(URLSigner.signed_url(uuid, "original"))

          _ ->
            ""
        end
      end)
      # Sanitised on READ, not only on write: these values reach a `<style>`
      # element, whose contents are raw character data — HTML escaping does not
      # apply there, so a value containing `</style>` closes the element and
      # opens whatever follows. Guarding here also neutralises anything a
      # previous release already stored. See `PhoenixKit.Utils.CssValue`.
      |> assign_new(:auth_bg_color, fn ->
        CssValue.color(Settings.get_setting("auth_background_color", ""))
      end)
      |> assign_new(:project_title, fn -> Settings.get_project_title() end)
      |> assign_new(:show_language_switcher, fn ->
        Settings.get_boolean_setting("auth_language_switcher_enabled", true) and
          Languages.enabled?() and length(Languages.get_enabled_languages()) > 1
      end)

    assigns =
      assigns
      |> assign(:bg_style_tag, bg_style_tag(assigns))
      |> assign(:custom_bg?, custom_bg?(assigns))

    ~H"""
    <LayoutWrapper.auth_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
      current_path={@current_path}
    >
      {raw(@bg_style_tag)}
      <%!-- Sizing here is deliberately free of viewport units.
            `w-[100vw]` overflowed by exactly the scrollbar-gutter width — the
            host root sets `scrollbar-gutter: stable`, so the gutter is always
            reserved and 100vw counts it, producing a horizontal scrollbar on a
            page that has nothing to scroll. `w-full` is a percentage of the
            containing block and excludes it.
            `min-h-full` for the same reason: a percentage can never exceed its
            parent, so it cannot manufacture a vertical scrollbar either. The
            parent's height comes from `auth_layout`'s `min-h-dvh`.
            The old `-my-8` / `-mx-[calc(50vw-50%)]` compensated for a chrome
            wrapper that auth no longer renders inside. --%>
      <%!-- The form starts near the top instead of the middle of the screen,
            which left a tall empty band above it on a big screen. It sits on
            the page itself; a card (a box with a shadow) is drawn only over a
            site's own background image or colour, where the form needs a
            surface of its own to stay readable. --%>
      <div class={[
        "auth-bg min-h-full w-full flex justify-center px-4 py-6 sm:py-12",
        !@custom_bg? && "bg-base-100"
      ]}>
        <div class={[
          "w-full max-w-sm",
          @custom_bg? && "card bg-base-100 shadow-lg self-start"
        ]}>
          <div class={if @custom_bg?, do: "card-body p-6", else: "flex flex-col"}>
            <%= if @auth_logo_url != "" do %>
              <div class="flex justify-center mb-4">
                <img src={@auth_logo_url} alt={@project_title} class="h-20 object-contain" />
              </div>
            <% end %>
            {render_slot(@inner_block)}
            <%= if @show_language_switcher do %>
              <div class="flex justify-center mt-4">
                <LanguageSwitcher.language_switcher_dropdown
                  current_path={@current_path}
                  show_current={true}
                />
              </div>
            <% end %>
            <%= if @dev_mailbox_message do %>
              <DevNotice.dev_mailbox_notice message={@dev_mailbox_message} />
            <% end %>
          </div>
        </div>
      </div>
    </LayoutWrapper.auth_layout>
    """
  end

  # This function builds markup by string concatenation and its result is
  # emitted through `raw/1`, so EVERY value interpolated here must already be
  # known-safe. The assigns are sanitised on read above, and re-sanitised here
  # because `assign_new/3` lets a caller supply them directly — this is the one
  # place the stylesheet is assembled, so this is where the guarantee belongs.
  # `CssValue.color/1` and `CssValue.url/1` return `""` for anything they do not
  # recognise, and `""` degrades to "no background", never to broken markup.
  defp bg_style_tag(assigns) do
    desktop = bg_css(CssValue.url(assigns.auth_bg_image), CssValue.color(assigns.auth_bg_color))

    mobile =
      case CssValue.url(assigns.auth_bg_image_mobile) do
        "" ->
          ""

        url ->
          "@media (max-width: 768px) { .auth-bg { background-image: url('#{url}'); } }"
      end

    "<style#{PhoenixKitWeb.CSP.attr(:style)}>.auth-bg { #{desktop} background-size: cover; background-position: center; } #{mobile}</style>"
  end

  defp custom_bg?(assigns) do
    bg_css(CssValue.url(assigns.auth_bg_image), CssValue.color(assigns.auth_bg_color)) != "" or
      CssValue.url(assigns.auth_bg_image_mobile) != ""
  end

  defp bg_css("", ""), do: ""

  defp bg_css(image_url, _color) when image_url != "",
    do: "background-image: url('#{image_url}');"

  defp bg_css("", color), do: "background: #{color};"
end
