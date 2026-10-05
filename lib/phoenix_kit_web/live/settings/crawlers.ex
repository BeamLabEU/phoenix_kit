defmodule PhoenixKitWeb.Live.Settings.Crawlers do
  @moduledoc """
  Crawlers settings LiveView — the bot-policy page.

  Sections, top to bottom:

    * **Robots directive** — the global noindex/nofollow staging switch.
    * **Bot access** — per-group allow/block toggles over the curated registry
      (`PhoenixKit.Modules.Crawlers.Bots`).
    * **robots.txt** — the complete generated file for copy-paste, built from
      the toggles above. PhoenixKit deliberately does **not** write or serve
      this file: it is host policy, and `Plug.Static` answers before the
      router, so a generated route would be dead code on most installs and a
      silent override on the rest.
    * **llms.txt** — served (root + prefixed) when the module is enabled;
      the operator's extra markdown is edited here.
    * **Verification** — Google/Bing site-verification meta contents.
    * **Enforcement** — the default-off application-level UA blocker, with its
      advisory-grade caveat stated plainly.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Crawlers.Bots
  alias PhoenixKit.Modules.Crawlers.LlmsTxt
  alias PhoenixKit.Modules.Crawlers.RobotsTxt
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  def mount(_params, _session, socket) do
    if Crawlers.module_enabled?() do
      socket =
        socket
        |> assign(:page_title, gettext("Crawlers"))
        |> assign(
          :page_subtitle,
          gettext(
            "Decide who may read this site — indexing directives, per-bot access, and what crawlers and AI assistants are told."
          )
        )
        |> assign(:page_section, gettext("Settings"))
        |> assign(:page_section_path, Routes.path("/admin/settings"))
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
        # The ROOT urls, deliberately — not `Routes.url/1`, which prefixes
        # them. Core serves /sitemap.xml and /llms.txt at both the root and
        # under the kit prefix precisely because crawlers look at the root,
        # so advertising the prefixed ones would defeat the point.
        |> assign(:sitemap_url, Routes.base_url() <> "/sitemap.xml")
        |> assign(:llms_txt_url, Routes.base_url() <> "/llms.txt")
        |> assign(:robots_txt_present?, File.exists?(robots_txt_path()))
        |> assign(:robots_txt_references_sitemap?, robots_txt_references_sitemap?())
        |> assign(:groups, Bots.groups())
        |> assign_policy_state()

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(
          :error,
          gettext(
            "Crawlers module is disabled. Enable it from the Modules page to configure settings."
          )
        )
        |> redirect(
          to:
            Routes.path("/admin/modules?tab=disabled", locale: socket.assigns.current_locale_base)
        )

      {:ok, socket}
    end
  end

  # The tab lives in the URL (`?tab=sessions`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :active_tab, UrlTabs.active(params, tabs()))}
  end

  defp tabs do
    [
      %{id: "robots", label: gettext("Robots Directive"), icon: "hero-no-symbol"},
      %{id: "bots", label: gettext("Bot Access"), icon: "hero-users"},
      %{id: "robots_txt", label: gettext("robots.txt"), icon: "hero-document-text"},
      %{id: "llms_txt", label: gettext("llms.txt"), icon: "hero-sparkles"},
      %{id: "verification", label: gettext("Verification"), icon: "hero-check-badge"},
      %{id: "enforcement", label: gettext("Enforcement"), icon: "hero-shield-exclamation"}
    ]
  end

  def handle_event("toggle_no_index", _params, socket) do
    new_value = !socket.assigns.no_index_enabled

    result =
      if new_value do
        Crawlers.enable_no_index()
      else
        Crawlers.disable_no_index()
      end

    case result do
      {:ok, _setting} ->
        message =
          if new_value do
            gettext("Noindex/nofollow enabled. Search engines will not index this site.")
          else
            gettext("Noindex/nofollow disabled. Site can be indexed again.")
          end

        {:noreply,
         socket
         |> assign(:no_index_enabled, new_value)
         |> put_flash(:info, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update crawler settings"))}
    end
  end

  def handle_event("toggle_sitemap_exempt_from_no_index", _params, socket) do
    new_value = !socket.assigns.sitemap_exempt_from_no_index

    case Crawlers.update_sitemap_exempt_from_no_index(new_value) do
      {:ok, _setting} ->
        {:noreply, assign(socket, :sitemap_exempt_from_no_index, new_value)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update crawler settings"))}
    end
  end

  def handle_event("toggle_group", %{"group" => group_key}, socket) do
    # Whitelist against the registry — never build an atom or a settings key
    # from raw params.
    case Bots.group(group_key) do
      nil ->
        {:noreply, socket}

      group ->
        new_value = !Crawlers.group_allowed?(group.key)

        case Crawlers.update_group_allowed(group.key, new_value) do
          {:ok, _} ->
            {:noreply, assign_policy_state(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update crawler settings"))}
        end
    end
  end

  def handle_event("toggle_block_at_app", _params, socket) do
    case Crawlers.update_block_at_app(!socket.assigns.block_at_app) do
      {:ok, _} ->
        {:noreply, assign_policy_state(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update crawler settings"))}
    end
  end

  def handle_event("save_verifications", params, socket) do
    google = Map.get(params, "google", "")
    bing = Map.get(params, "bing", "")

    case Crawlers.update_verifications(google, bing) do
      :ok ->
        {:noreply,
         socket
         |> assign_policy_state()
         |> put_flash(:info, gettext("Verification tags saved."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update crawler settings"))}
    end
  end

  def handle_event("save_llms_txt", params, socket) do
    case Crawlers.update_llms_txt_extra(Map.get(params, "extra", "")) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_policy_state()
         |> put_flash(:info, gettext("llms.txt content saved."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update crawler settings"))}
    end
  end

  # One reader for every piece of policy state the page renders, so all
  # events converge on the same refresh and cannot drift from the DB.
  defp assign_policy_state(socket) do
    allowed = Map.new(Bots.group_keys(), &{&1, Crawlers.group_allowed?(&1)})

    socket
    |> assign(:no_index_enabled, Crawlers.no_index_enabled?())
    |> assign(:sitemap_exempt_from_no_index, Crawlers.sitemap_exempt_from_no_index?())
    |> assign(:group_allowed, allowed)
    |> assign(:block_at_app, Crawlers.block_at_app_enabled?())
    |> assign(:google_verification, Crawlers.google_verification())
    |> assign(:bing_verification, Crawlers.bing_verification())
    |> assign(:llms_txt_extra, Crawlers.llms_txt_extra())
    |> assign(:llms_txt_preview, LlmsTxt.build())
    |> assign(
      :robots_txt,
      RobotsTxt.build(sitemap_url: Routes.base_url() <> "/sitemap.xml")
    )
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/crawlers", locale: locale)
  end

  # Where Plug.Static serves it from in a stock Phoenix app. Read-only: this
  # page reports what is there, it never writes the host's robots.txt.
  defp robots_txt_path, do: Path.join(["priv", "static", "robots.txt"])

  defp robots_txt_references_sitemap? do
    case File.read(robots_txt_path()) do
      {:ok, contents} -> contents =~ ~r/^\s*sitemap:/im
      {:error, _} -> false
    end
  end
end
