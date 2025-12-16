defmodule PhoenixKitWeb.Live.Modules.AI.Accounts do
  @moduledoc """
  LiveView for listing and managing AI provider accounts.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.AI
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if AI.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")
      accounts = AI.list_accounts()

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:page_title, "AI Accounts")
        |> assign(:current_path, Routes.path("/admin/ai/accounts"))
        |> assign(:accounts, accounts)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "AI module is not enabled")
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_account", %{"id" => id}, socket) do
    account = AI.get_account!(String.to_integer(id))

    case AI.delete_account(account) do
      {:ok, _} ->
        accounts = AI.list_accounts()

        socket =
          socket
          |> assign(:accounts, accounts)
          |> put_flash(:info, "Account deleted")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete account")}
    end
  end

  @impl true
  def handle_event("toggle_account", %{"id" => id}, socket) do
    account = AI.get_account!(String.to_integer(id))

    case AI.update_account(account, %{enabled: !account.enabled}) do
      {:ok, _} ->
        accounts = AI.list_accounts()

        socket =
          socket
          |> assign(:accounts, accounts)
          |> put_flash(
            :info,
            if(account.enabled, do: "Account disabled", else: "Account enabled")
          )

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update account")}
    end
  end
end
