defmodule PhoenixKitWeb.PersonCardController do
  @moduledoc """
  The person drawer's content: `GET <prefix>/people/:uuid/card`, an HTML
  fragment the browser puts into the drawer that opens when a mention chip
  (`[data-mention-user]`, core's `<.mention_text>` and the comments
  module's) is clicked — instead of leaving the page for the person's
  profile (Max, 2026-11-24).

  Who sees what, checked on every request against the viewer's live scope:

    * only a signed-in account that reaches the admin area gets a card at
      all (the people a mention can name are admin-area accounts); anyone
      else, an unknown uuid, an inactive account or a service user gets a
      404 that says nothing;
    * the name, username and picture: the chip already shows them;
    * the email: only to a holder of the `users` permission (or the person
      themself);
    * **Open profile**: only where the viewer may open it (`users`);
    * actions from modules: each enabled module may add some through the
      optional `c:PhoenixKit.Module.person_actions/2` callback — a chat
      module's "Message", say. A module that raises adds nothing.
  """

  use PhoenixKitWeb, :controller
  use Phoenix.Component

  require Logger

  alias Phoenix.HTML.Safe
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  def card(conn, %{"uuid" => uuid} = params) do
    conn = WebAuth.fetch_phoenix_kit_current_scope(conn, [])
    scope = conn.assigns[:phoenix_kit_current_scope]
    put_page_language(params["lang"])

    with true <- Scope.can_access_admin_area?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %User{is_active: true, api_only: false} = person <- Auth.get_user(uuid) do
      viewer = scope.user
      may_manage? = Scope.has_module_access?(scope, "users")
      self? = viewer && viewer.uuid == person.uuid

      assigns = %{
        person: person,
        name: User.display_name(person),
        username: present(person.username),
        email: if(may_manage? or self?, do: User.delivery_email(person)),
        profile: if(may_manage?, do: Routes.path("/admin/users/view/#{person.uuid}")),
        actions: module_actions(scope, person)
      }

      conn
      |> put_resp_header("cache-control", "no-store")
      |> html(Safe.to_iodata(card_html(assigns)))
    else
      _ -> conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "")
    end
  end

  defp card_html(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-3 text-center">
      <.user_avatar user={@person} size="lg" />
      <div class="min-w-0">
        <p class="text-lg font-semibold break-words" data-person-name>{@name}</p>
        <p :if={@username} class="text-sm text-base-content/60">@{@username}</p>
        <p :if={@email} class="text-sm text-base-content/70 break-all">{@email}</p>
      </div>
    </div>
    <div :if={@profile || @actions != []} class="mt-5 flex flex-col gap-2">
      <a
        :for={action <- @actions}
        href={action.href}
        class="btn btn-sm btn-outline justify-start gap-2"
      >
        <.icon :if={action[:icon]} name={action.icon} class="w-4 h-4" />{action.label}
      </a>
      <a :if={@profile} href={@profile} data-person-profile class="btn btn-sm btn-primary gap-2">
        <.icon name="hero-user" class="w-4 h-4" />{gettext("Open profile")}
      </a>
    </div>
    """
  end

  # The card's URL has no locale segment, so the drawer sends the page's
  # `<html lang>`. Only an enabled language is used (exact, or the first
  # enabled dialect of that base: "en" -> "en-US"); anything else leaves
  # the default. The value itself is never written into the card.
  defp put_page_language(lang) when is_binary(lang) and byte_size(lang) in 2..20 do
    codes = Languages.enabled_locale_codes()
    base = fn code -> code |> String.downcase() |> String.split(["-", "_"]) |> hd() end
    wanted = String.downcase(lang)

    match =
      Enum.find(codes, &(String.downcase(&1) == wanted)) ||
        Enum.find(codes, &(base.(&1) == base.(lang)))

    if match, do: WebAuth.put_gettext_locale(match)
  rescue
    _ -> :ok
  end

  defp put_page_language(_), do: :ok

  # `%{label, href, icon?}` from every enabled module that answers; a path
  # off this site is dropped (an action is a page of the app).
  defp module_actions(scope, person) do
    ModuleRegistry.enabled_modules()
    |> Enum.filter(&function_exported?(&1, :person_actions, 2))
    |> Enum.flat_map(fn mod ->
      case safe_actions(mod, scope, person) do
        list when is_list(list) -> list
        _ -> []
      end
    end)
    |> Enum.filter(fn action ->
      # A struct is a map without Access: `action[:label]` would raise.
      is_map(action) and not is_struct(action) and is_binary(Map.get(action, :label)) and
        is_binary(Map.get(action, :href)) and Routes.local_path?(action.href)
    end)
  end

  defp safe_actions(mod, scope, person) do
    mod.person_actions(scope, person)
  rescue
    error ->
      Logger.warning(
        "[PersonCard] #{inspect(mod)}.person_actions/2 failed: #{inspect(error.__struct__)}"
      )

      []
  catch
    # An exit, or a throw from a module's callback.
    _kind, _ -> []
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
end
