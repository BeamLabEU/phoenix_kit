defmodule PhoenixKitWeb.Live.Modules.AI.Settings do
  @moduledoc """
  LiveView for AI module configuration and settings management.

  This module provides a comprehensive interface for managing AI provider accounts
  and model configuration in PhoenixKit.

  ## Features

  - **Account Management**: Add, edit, delete AI provider accounts (OpenRouter, etc.)
  - **Model Type Tabs**: Configure slots for Text, Vision, Image Gen, and Embeddings
  - **Slot Configuration**: 3 presets per model type with fallback chain support
  - **Model Selection**: Choose models from available providers
  - **Usage Statistics**: View request history and token usage

  ## Route

  This LiveView is mounted at `{prefix}/admin/ai` and requires
  appropriate admin permissions.

  ## UI States

  - **Setup State**: Shown when no accounts are configured yet
  - **Configuration State**: Shown when at least one account exists
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.AI
  alias PhoenixKit.AI.OpenRouterClient
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Model type tabs configuration
  @model_types [
    %{id: "text", label: "Text", icon: "hero-chat-bubble-left-right", type: :text},
    %{id: "vision", label: "Vision", icon: "hero-eye", type: :vision},
    %{id: "image_gen", label: "Image Gen", icon: "hero-photo", type: :image_gen},
    %{id: "embeddings", label: "Embeddings", icon: "hero-cube-transparent", type: :embeddings}
  ]

  @impl true
  def mount(_params, session, socket) do
    current_path = get_current_path(socket, session)
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load accounts
    accounts = AI.list_accounts()
    has_accounts = length(accounts) > 0

    # Default slot type
    default_slot_type = :text
    slots = AI.get_slots(default_slot_type)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "AI Module")
      |> assign(:project_title, project_title)
      |> assign(:accounts, accounts)
      |> assign(:has_accounts, has_accounts)
      |> assign(:active_tab, if(has_accounts, do: "slots", else: "setup"))
      # Model type tab (text, vision, image_gen, embeddings)
      |> assign(:slot_type, default_slot_type)
      |> assign(:model_types, @model_types)
      |> assign(:slots, slots)
      |> assign(:saving_slots, false)
      # Models are cached per {account_id, model_type}
      |> assign(:models_cache, %{})
      |> assign(:models_loading_for, nil)
      |> assign(:models_error, nil)

    # Fetch models for any slots that already have accounts
    socket = fetch_models_for_existing_slots(socket)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || socket.assigns.active_tab
    {:noreply, assign(socket, :active_tab, tab)}
  end

  # ===========================================
  # TAB NAVIGATION
  # ===========================================

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :active_tab, tab)

    # Lazy load usage data when switching to usage tab
    socket =
      if tab == "usage" && !socket.assigns[:usage_loaded] do
        load_usage_data(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_requests", _params, socket) do
    page = socket.assigns.usage_page + 1
    {new_requests, _total} = AI.list_requests(page: page, page_size: 20, preload: [:account])

    socket =
      socket
      |> assign(:usage_requests, socket.assigns.usage_requests ++ new_requests)
      |> assign(:usage_page, page)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_slot_type", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)
    slots = AI.get_slots(type)

    socket =
      socket
      |> assign(:slot_type, type)
      |> assign(:slots, slots)
      |> assign(:models_error, nil)

    # Fetch models for any slots that already have accounts
    socket = fetch_models_for_existing_slots(socket)

    {:noreply, socket}
  end

  # ===========================================
  # SLOTS CONFIGURATION
  # ===========================================

  @impl true
  def handle_event("update_slot", params, socket) do
    slots = socket.assigns.slots
    slot_type = socket.assigns.slot_type

    # Handle form-based params (nested under "slot")
    if params["slot"] do
      slot = params["slot"]
      slot_index = String.to_integer(slot["index"] || "0")
      current_slot = Enum.at(slots, slot_index)

      new_account_id = parse_int(slot["account_id"])
      old_account_id = current_slot["account_id"]
      account_changed = new_account_id != old_account_id

      new_model = if(account_changed, do: "", else: slot["model"] || "")
      old_model = current_slot["model"] || ""
      model_changed = new_model != old_model && new_model != ""

      # Base slot fields
      new_slot = %{
        "name" => slot["name"] || current_slot["name"] || "",
        "description" => slot["description"] || current_slot["description"] || "",
        "account_id" => new_account_id,
        # Clear model if account changed
        "model" => new_model,
        "enabled" => current_slot["enabled"] || false
      }

      # Add type-specific fields
      new_slot = add_type_specific_fields(new_slot, slot, current_slot, slot_type)

      updated_slots = List.replace_at(slots, slot_index, new_slot)

      socket = assign(socket, :slots, updated_slots)

      # Fetch models for the new account if not already cached
      socket =
        if account_changed && new_account_id do
          maybe_fetch_models_for_account(socket, new_account_id)
        else
          socket
        end

      {:noreply, socket}
    else
      # Handle checkbox toggle (flat params)
      slot_index = String.to_integer(params["slot-index"] || "0")
      current_slot = Enum.at(slots, slot_index)

      # Base slot fields
      new_slot = %{
        "name" => params["slot-name"] || current_slot["name"] || "",
        "description" => params["slot-description"] || current_slot["description"] || "",
        "account_id" => parse_int(params["slot-account_id"]) || current_slot["account_id"],
        "model" => params["slot-model"] || current_slot["model"] || "",
        "enabled" => params["slot-enabled"] == "true"
      }

      # Add type-specific fields from flat params
      new_slot = add_type_specific_fields_flat(new_slot, params, current_slot, slot_type)

      updated_slots = List.replace_at(slots, slot_index, new_slot)
      {:noreply, assign(socket, :slots, updated_slots)}
    end
  end

  @impl true
  def handle_event("save_slots", _params, socket) do
    socket = assign(socket, :saving_slots, true)
    slot_type = socket.assigns.slot_type

    case AI.update_slots(slot_type, socket.assigns.slots) do
      {:ok, slots} ->
        type_label = slot_type_label(slot_type)

        socket =
          socket
          |> assign(:slots, slots)
          |> assign(:saving_slots, false)
          |> put_flash(:info, "#{type_label} configuration saved")

        {:noreply, socket}

      {:error, _} ->
        socket =
          socket
          |> assign(:saving_slots, false)
          |> put_flash(:error, "Failed to save configuration")

        {:noreply, socket}
    end
  end

  defp slot_type_label(:text), do: "Text processing"
  defp slot_type_label(:vision), do: "Vision processing"
  defp slot_type_label(:image_gen), do: "Image generation"
  defp slot_type_label(:embeddings), do: "Embeddings"

  # Add type-specific fields for form-based params
  defp add_type_specific_fields(new_slot, slot, current_slot, slot_type)
       when slot_type in [:text, :vision] do
    Map.merge(new_slot, %{
      "temperature" => parse_float(slot["temperature"], current_slot["temperature"] || 0.7),
      "max_tokens" => parse_int_or_nil(slot["max_tokens"], current_slot["max_tokens"]),
      "top_p" => parse_float_or_nil(slot["top_p"], current_slot["top_p"]),
      "top_k" => parse_int_or_nil(slot["top_k"], current_slot["top_k"]),
      "frequency_penalty" =>
        parse_float_or_nil(slot["frequency_penalty"], current_slot["frequency_penalty"]),
      "presence_penalty" =>
        parse_float_or_nil(slot["presence_penalty"], current_slot["presence_penalty"]),
      "repetition_penalty" =>
        parse_float_or_nil(slot["repetition_penalty"], current_slot["repetition_penalty"]),
      "stop" => parse_stop_sequences(slot["stop"], current_slot["stop"]),
      "seed" => parse_int_or_nil(slot["seed"], current_slot["seed"])
    })
  end

  defp add_type_specific_fields(new_slot, slot, current_slot, :image_gen) do
    Map.merge(new_slot, %{
      "size" => slot["size"] || current_slot["size"] || "1024x1024",
      "quality" => slot["quality"] || current_slot["quality"] || "standard"
    })
  end

  defp add_type_specific_fields(new_slot, slot, current_slot, :embeddings) do
    Map.merge(new_slot, %{
      "dimensions" => parse_int(slot["dimensions"], current_slot["dimensions"])
    })
  end

  # Add type-specific fields for flat params (checkbox toggle)
  defp add_type_specific_fields_flat(new_slot, params, current_slot, slot_type)
       when slot_type in [:text, :vision] do
    Map.merge(new_slot, %{
      "temperature" =>
        parse_float(params["slot-temperature"], current_slot["temperature"] || 0.7),
      "max_tokens" => parse_int_or_nil(params["slot-max_tokens"], current_slot["max_tokens"]),
      "top_p" => current_slot["top_p"],
      "top_k" => current_slot["top_k"],
      "frequency_penalty" => current_slot["frequency_penalty"],
      "presence_penalty" => current_slot["presence_penalty"],
      "repetition_penalty" => current_slot["repetition_penalty"],
      "stop" => current_slot["stop"],
      "seed" => current_slot["seed"]
    })
  end

  defp add_type_specific_fields_flat(new_slot, params, current_slot, :image_gen) do
    Map.merge(new_slot, %{
      "size" => params["slot-size"] || current_slot["size"] || "1024x1024",
      "quality" => params["slot-quality"] || current_slot["quality"] || "standard"
    })
  end

  defp add_type_specific_fields_flat(new_slot, params, current_slot, :embeddings) do
    Map.merge(new_slot, %{
      "dimensions" => parse_int(params["slot-dimensions"], current_slot["dimensions"])
    })
  end

  # Parse float, returning nil if empty/invalid
  defp parse_float_or_nil(nil, default), do: default
  defp parse_float_or_nil("", _default), do: nil
  defp parse_float_or_nil(val, _default) when is_float(val), do: val
  defp parse_float_or_nil(val, _default) when is_integer(val), do: val / 1

  defp parse_float_or_nil(val, default) when is_binary(val) do
    case Float.parse(val) do
      {float, _} -> float
      :error -> default
    end
  end

  # Parse int, returning nil if empty/invalid
  defp parse_int_or_nil(nil, default), do: default
  defp parse_int_or_nil("", _default), do: nil
  defp parse_int_or_nil(val, _default) when is_integer(val), do: val

  defp parse_int_or_nil(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  # Parse stop sequences (comma-separated string to list)
  defp parse_stop_sequences(nil, default), do: default
  defp parse_stop_sequences("", _default), do: nil

  defp parse_stop_sequences(val, _default) when is_binary(val) do
    val
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      sequences -> sequences
    end
  end

  defp parse_stop_sequences(val, _default) when is_list(val), do: val

  # ===========================================
  # MODEL FETCHING
  # ===========================================

  @impl true
  def handle_info({:fetch_models, account_id, api_key, provider, slot_type}, socket) do
    # Currently only OpenRouter is supported, but this can be extended
    result =
      case {provider, slot_type} do
        {"openrouter", :embeddings} ->
          OpenRouterClient.fetch_embedding_models_grouped(api_key)

        {"openrouter", model_type} ->
          OpenRouterClient.fetch_models_by_type(api_key, model_type)

        {_, :embeddings} ->
          OpenRouterClient.fetch_embedding_models_grouped(api_key)

        {_, model_type} ->
          OpenRouterClient.fetch_models_by_type(api_key, model_type)
      end

    case result do
      {:ok, grouped} ->
        # Flatten grouped models into a single list for easy lookup
        all_models =
          grouped
          |> Enum.flat_map(fn {_provider, models} -> models end)

        # Cache models for this {account_id, slot_type} combination
        cache_key = {account_id, slot_type}

        models_cache =
          Map.put(socket.assigns.models_cache, cache_key, %{
            models: all_models,
            grouped: grouped
          })

        socket =
          socket
          |> assign(:models_cache, models_cache)
          |> assign(:models_loading_for, nil)
          |> assign(:models_error, nil)

        # Check if other slots need models fetched
        socket = fetch_models_for_existing_slots(socket)

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:models_loading_for, nil)
          |> assign(:models_error, reason)

        {:noreply, socket}
    end
  end

  defp maybe_fetch_models_for_account(socket, account_id) do
    slot_type = socket.assigns.slot_type
    cache_key = {account_id, slot_type}

    # Check if already cached for this account + slot_type combination
    if Map.has_key?(socket.assigns.models_cache, cache_key) do
      socket
    else
      # Find the account and fetch models
      account = Enum.find(socket.assigns.accounts, &(&1.id == account_id))

      if account && account.api_key do
        send(self(), {:fetch_models, account_id, account.api_key, account.provider, slot_type})

        socket
        |> assign(:models_loading_for, account_id)
        |> assign(:models_error, nil)
      else
        socket
      end
    end
  end

  # Fetch models for all slots that already have an account selected
  defp fetch_models_for_existing_slots(socket) do
    slots = socket.assigns.slots
    slot_type = socket.assigns.slot_type

    # Find the first slot with an account that needs models fetched
    slot_needing_fetch =
      Enum.find(slots, fn slot ->
        account_id = slot["account_id"]
        cache_key = {account_id, slot_type}

        account_id != nil &&
          not Map.has_key?(socket.assigns.models_cache, cache_key)
      end)

    case slot_needing_fetch do
      nil ->
        socket

      slot ->
        # Fetch models for this account (will trigger loading for one at a time)
        maybe_fetch_models_for_account(socket, slot["account_id"])
    end
  end

  # ===========================================
  # USAGE DATA
  # ===========================================

  defp load_usage_data(socket) do
    # Get dashboard statistics
    stats = AI.get_dashboard_stats()

    # Get recent requests with pagination
    {requests, total_requests} = AI.list_requests(page: 1, page_size: 20, preload: [:account])

    socket
    |> assign(:usage_loaded, true)
    |> assign(:usage_stats, stats)
    |> assign(:usage_requests, requests)
    |> assign(:usage_total_requests, total_requests)
    |> assign(:usage_page, 1)
  end

  # ===========================================
  # HELPERS
  # ===========================================

  defp get_current_path(socket, session) do
    case socket.assigns do
      %{url_path: path} when is_binary(path) -> path
      _ -> session["current_path"] || Routes.path("/admin/ai")
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default
  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(val, _default) when is_integer(val), do: val / 1

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {float, _} -> float
      :error -> default
    end
  end

  @doc false
  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 2)
  def format_number(num), do: to_string(num)
end
