defmodule PhoenixKit.Modules.Referrals.Web.Form do
  @moduledoc """
  Referral code form LiveView for PhoenixKit admin panel.

  Provides form interface for creating and editing user referral codes.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Referrals
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    code_id = params["id"]
    mode = if code_id, do: :edit, else: :new

    # Get project title from settings
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:code_id, code_id)
      |> assign(:page_title, page_title(mode))
      |> assign(:project_title, project_title)
      |> assign(:search_results, [])
      |> assign(:selected_beneficiary, nil)
      |> load_code_data(mode, code_id)
      |> load_form_data()

    {:ok, socket}
  end

  def handle_event("validate_code", params, socket) do
    # Extract referrals params (matches form name from changeset)
    code_params = Map.get(params, "referrals", %{})

    # Add beneficiary if selected
    updated_params =
      case socket.assigns.selected_beneficiary do
        nil -> code_params
        beneficiary -> Map.put(code_params, "beneficiary", beneficiary.id)
      end

    # Create changeset for validation
    changeset =
      case socket.assigns.mode do
        :new -> Referrals.changeset(%Referrals{}, updated_params)
        :edit -> Referrals.changeset(socket.assigns.code, updated_params)
      end
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_code", params, socket) do
    # Extract referrals params (matches form name from changeset)
    code_params = Map.get(params, "referrals", %{})

    # Ensure beneficiary is included if selected
    updated_code_params =
      case socket.assigns.selected_beneficiary do
        nil -> code_params
        beneficiary -> Map.put(code_params, "beneficiary", beneficiary.id)
      end

    case socket.assigns.mode do
      :new -> create_code(socket, updated_code_params)
      :edit -> update_code(socket, updated_code_params)
    end
  end

  def handle_event("generate_code", _params, socket) do
    random_code = Referrals.generate_random_code()

    # Get current changeset changes and add the generated code
    current_changes = socket.assigns.changeset.changes
    updated_changes = Map.put(current_changes, :code, random_code)

    # Add beneficiary if selected
    final_changes =
      case socket.assigns.selected_beneficiary do
        nil -> updated_changes
        beneficiary -> Map.put(updated_changes, :beneficiary, beneficiary.id)
      end

    changeset =
      case socket.assigns.mode do
        :new -> Referrals.changeset(%Referrals{}, final_changes)
        :edit -> Referrals.changeset(socket.assigns.code, final_changes)
      end

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("search_beneficiary", %{"search" => search_term}, socket) do
    search_results =
      if String.length(search_term) >= 2 do
        Auth.search_users(search_term)
      else
        []
      end

    socket =
      socket
      |> assign(:search_results, search_results)

    {:noreply, socket}
  end

  def handle_event("select_beneficiary", %{"user_id" => user_id}, socket) do
    # Find the selected user from search results
    selected_user =
      Enum.find(socket.assigns.search_results, fn user ->
        to_string(user.id) == user_id
      end)

    # Update the changeset with the selected beneficiary, preserving other changes
    current_changes = socket.assigns.changeset.changes
    updated_changes = Map.put(current_changes, :beneficiary, String.to_integer(user_id))

    changeset =
      case socket.assigns.mode do
        :new -> Referrals.changeset(%Referrals{}, updated_changes)
        :edit -> Referrals.changeset(socket.assigns.code, updated_changes)
      end

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:selected_beneficiary, selected_user)
      |> assign(:search_results, [])

    {:noreply, socket}
  end

  def handle_event("clear_beneficiary", _params, socket) do
    # Clear the beneficiary selection while preserving other changes
    current_changes = socket.assigns.changeset.changes
    updated_changes = Map.delete(current_changes, :beneficiary)

    changeset =
      case socket.assigns.mode do
        :new -> Referrals.changeset(%Referrals{}, updated_changes)
        :edit -> Referrals.changeset(socket.assigns.code, updated_changes)
      end

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:selected_beneficiary, nil)
      |> assign(:search_results, [])

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/users/referral-codes"))}
  end

  # Private functions

  defp load_code_data(socket, :new, _code_id) do
    assign(socket, :code, nil)
  end

  defp load_code_data(socket, :edit, code_id) do
    code = Referrals.get_code!(code_id)
    assign(socket, :code, code)
  end

  defp load_form_data(socket) do
    code = socket.assigns.code || %Referrals{}

    # For new codes, initialize with empty changeset
    # For edit mode, initialize changeset with current code data to pre-populate form
    initial_params =
      case socket.assigns.mode do
        :new ->
          %{}

        :edit ->
          %{
            "code" => code.code,
            "description" => code.description,
            "max_uses" => code.max_uses,
            "expiration_date" => code.expiration_date,
            "status" => code.status
          }
      end

    changeset = Referrals.changeset(code, initial_params)

    # Load selected beneficiary if editing existing code with beneficiary ID
    selected_beneficiary =
      case code.beneficiary do
        nil -> nil
        beneficiary_id -> Auth.get_user_for_selection(beneficiary_id)
      end

    socket
    |> assign(:changeset, changeset)
    |> assign(:selected_beneficiary, selected_beneficiary)
  end

  defp create_code(socket, code_params) do
    {code_params_with_creator, user_id} = extract_user_info(socket, code_params)

    socket
    |> create_code_with_validation(code_params_with_creator, user_id)
    |> then(&{:noreply, &1})
  end

  defp extract_user_info(socket, code_params) do
    case socket.assigns.phoenix_kit_current_user do
      user when not is_nil(user) ->
        {Map.put(code_params, "created_by", user.id), user.id}

      _ ->
        extract_user_from_scope(socket, code_params)
    end
  end

  defp extract_user_from_scope(socket, code_params) do
    case socket.assigns do
      %{phoenix_kit_current_scope: %{user_id: user_id}} when not is_nil(user_id) ->
        {Map.put(code_params, "created_by", user_id), user_id}

      _ ->
        Logger.warning("Socket assigns when current_user is nil: #{inspect(socket.assigns)}")
        {code_params, nil}
    end
  end

  defp create_code_with_validation(socket, code_params_with_creator, user_id) do
    case validate_user_limit(user_id) do
      {:ok, :valid} -> do_create_code(socket, code_params_with_creator)
      {:error, limit_message} -> put_flash(socket, :error, limit_message)
      nil -> do_create_code(socket, code_params_with_creator)
    end
  end

  defp validate_user_limit(nil), do: nil
  defp validate_user_limit(user_id), do: Referrals.validate_user_code_limit(user_id)

  defp do_create_code(socket, code_params_with_creator) do
    case Referrals.create_code(code_params_with_creator) do
      {:ok, _code} ->
        socket
        |> put_flash(:info, "Referral code created successfully!")
        |> push_navigate(to: Routes.path("/admin/users/referral-codes"))

      {:error, changeset} ->
        socket
        |> assign(:changeset, changeset)
        |> put_flash(:error, "Failed to create referral code. Please check the errors below.")
    end
  end

  defp update_code(socket, code_params) do
    case Referrals.update_code(socket.assigns.code, code_params) do
      {:ok, _code} ->
        socket
        |> put_flash(:info, "Referral code updated successfully!")
        |> push_navigate(to: Routes.path("/admin/users/referral-codes"))

      {:error, changeset} ->
        socket
        |> assign(:changeset, changeset)
        |> put_flash(:error, "Failed to update referral code. Please check the errors below.")
    end
    |> then(&{:noreply, &1})
  end

  defp page_title(:new), do: "New Referral Code"
  defp page_title(:edit), do: "Edit Referral Code"
end
