defmodule PhoenixKitWeb.Live.Modules.AI.AccountForm do
  @moduledoc """
  LiveView for creating and editing AI provider accounts.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.AI
  alias PhoenixKit.AI.Account
  alias PhoenixKit.AI.OpenRouterClient
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    if AI.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:current_path, Routes.path("/admin/ai"))
        |> assign(:validating_api_key, false)
        |> assign(:api_key_valid, nil)
        |> assign(:api_key_error, nil)
        |> load_account(params["id"])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "AI module is not enabled")
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  defp load_account(socket, nil) do
    # New account
    changeset = AI.change_account(%Account{})

    socket
    |> assign(:page_title, "New AI Account")
    |> assign(:account, nil)
    |> assign(:form, to_form(changeset))
  end

  defp load_account(socket, id) do
    case AI.get_account(String.to_integer(id)) do
      nil ->
        socket
        |> put_flash(:error, "Account not found")
        |> push_navigate(to: Routes.path("/admin/ai"))

      account ->
        changeset = AI.change_account(account)

        socket
        |> assign(:page_title, "Edit AI Account")
        |> assign(:account, account)
        |> assign(:form, to_form(changeset))
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"account" => params}, socket) do
    changeset =
      (socket.assigns.account || %Account{})
      |> AI.change_account(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate_api_key", _params, socket) do
    api_key =
      socket.assigns.form.params["api_key"] ||
        (socket.assigns.account && socket.assigns.account.api_key) ||
        ""

    if String.length(api_key) > 10 do
      socket = assign(socket, :validating_api_key, true)
      send(self(), {:do_validate_api_key, api_key})
      {:noreply, socket}
    else
      {:noreply, assign(socket, api_key_error: "Please enter an API key first")}
    end
  end

  @impl true
  def handle_event("save", %{"account" => params}, socket) do
    # Merge settings from nested params
    settings = %{
      "http_referer" => get_in(params, ["settings", "http_referer"]) || "",
      "x_title" => get_in(params, ["settings", "x_title"]) || ""
    }

    params = Map.put(params, "settings", settings)

    save_account(socket, params)
  end

  defp save_account(socket, params) do
    result =
      if socket.assigns.account do
        AI.update_account(socket.assigns.account, params)
      else
        AI.create_account(params)
      end

    case result do
      {:ok, _account} ->
        action = if socket.assigns.account, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Account #{action} successfully")
         |> push_navigate(to: Routes.path("/admin/ai/accounts"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:do_validate_api_key, api_key}, socket) do
    case OpenRouterClient.validate_api_key(api_key) do
      {:ok, _data} ->
        socket =
          socket
          |> assign(:validating_api_key, false)
          |> assign(:api_key_valid, true)
          |> assign(:api_key_error, nil)

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:validating_api_key, false)
          |> assign(:api_key_valid, false)
          |> assign(:api_key_error, reason)

        {:noreply, socket}
    end
  end
end
