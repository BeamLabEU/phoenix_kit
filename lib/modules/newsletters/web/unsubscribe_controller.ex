defmodule PhoenixKit.Modules.Newsletters.Web.UnsubscribeController do
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Newsletters
  alias PhoenixKit.Utils.Routes

  plug :put_view, html: PhoenixKit.Modules.Newsletters.Web.UnsubscribeHTML

  # GET /mailing/unsubscribe?token=...
  # Shows unsubscribe options page (per-list + global)
  def unsubscribe(conn, %{"token" => token}) do
    case Phoenix.Token.verify(PhoenixKitWeb.Endpoint, "unsubscribe", token, max_age: 604_800) do
      {:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
        list = Newsletters.get_list(list_uuid)
        all_lists = Newsletters.list_user_subscriptions(user_uuid)

        conn
        |> assign(:token, token)
        |> assign(:list, list)
        |> assign(:all_lists, all_lists)
        |> assign(:user_uuid, user_uuid)
        |> render(:unsubscribe)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid or expired unsubscribe link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  # POST /mailing/unsubscribe — process the choice
  def process_unsubscribe(conn, %{"token" => token, "scope" => "list"}) do
    case Phoenix.Token.verify(PhoenixKitWeb.Endpoint, "unsubscribe", token, max_age: 604_800) do
      {:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
        Newsletters.unsubscribe_user(list_uuid, user_uuid)

        conn
        |> put_flash(:info, "You have been unsubscribed from this list.")
        |> redirect(to: Routes.path("/"))

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  def process_unsubscribe(conn, %{"token" => token, "scope" => "all"}) do
    case Phoenix.Token.verify(PhoenixKitWeb.Endpoint, "unsubscribe", token, max_age: 604_800) do
      {:ok, %{user_uuid: user_uuid}} ->
        Newsletters.unsubscribe_from_all(user_uuid)

        conn
        |> put_flash(:info, "You have been unsubscribed from all lists.")
        |> redirect(to: Routes.path("/"))

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end
end
