defmodule PhoenixKitWeb.Live.Modules.AI.EndpointForm do
  @moduledoc """
  LiveView for creating and editing AI endpoints.

  An endpoint combines provider credentials, model selection, and generation
  parameters into a single configuration.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.AI
  alias PhoenixKit.AI.Endpoint
  alias PhoenixKit.AI.OpenRouterClient
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # ===========================================
  # FUNCTION COMPONENTS
  # ===========================================

  attr :key, :string, required: true
  attr :definition, :map, required: true
  attr :form, :map, required: true
  attr :endpoint, :any, default: nil
  attr :selected_model, :map, default: nil
  attr :size, :string, default: "md"

  def param_input(assigns) do
    field = assigns.definition.field
    field_str = Atom.to_string(field)

    current_value =
      assigns.form.params[field_str] ||
        (assigns.endpoint && Map.get(assigns.endpoint, field)) ||
        assigns.definition[:default] ||
        ""

    # For string_list type, convert array to newline-separated string
    current_value =
      case {assigns.definition.type, current_value} do
        {:string_list, list} when is_list(list) -> Enum.join(list, "\n")
        _ -> current_value
      end

    input_class =
      case assigns.size do
        "sm" -> "input input-bordered input-sm"
        _ -> "input input-bordered"
      end

    textarea_class =
      case assigns.size do
        "sm" -> "textarea textarea-bordered textarea-sm"
        _ -> "textarea textarea-bordered"
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:field_str, field_str)
      |> assign(:current_value, current_value)
      |> assign(:input_class, input_class)
      |> assign(:textarea_class, textarea_class)

    ~H"""
    <div class="form-control">
      <label class="label">
        <span class={if @size == "sm", do: "label-text", else: "label-text font-medium"}>
          {@definition.label}
        </span>
      </label>

      <%= case @definition.type do %>
        <% :float -> %>
          <input
            type="number"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            step={@definition[:step] || 0.1}
            min={@definition[:min]}
            max={@definition[:max]}
            placeholder={@definition[:placeholder]}
          />
        <% :integer -> %>
          <input
            type="number"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            min={@definition[:min]}
            max={get_max_for_field(@field_str, @definition, @selected_model)}
            placeholder={get_placeholder_for_field(@field_str, @definition, @selected_model)}
          />
        <% :string_list -> %>
          <textarea
            name={"endpoint[#{@field_str}]"}
            class={@textarea_class}
            rows="2"
            placeholder={@definition[:placeholder] || "One per line"}
          >{@current_value}</textarea>
        <% _ -> %>
          <input
            type="text"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            placeholder={@definition[:placeholder]}
          />
      <% end %>
    </div>
    """
  end

  defp get_max_for_field("max_tokens", _definition, selected_model) do
    selected_model && selected_model["max_completion_tokens"]
  end

  defp get_max_for_field(_field, definition, _selected_model) do
    definition[:max]
  end

  defp get_placeholder_for_field("max_tokens", _definition, selected_model) do
    if selected_model && selected_model["max_completion_tokens"] do
      "Max: #{selected_model["max_completion_tokens"]}"
    else
      "Model default"
    end
  end

  defp get_placeholder_for_field(_field, definition, _selected_model) do
    definition[:placeholder]
  end

  # ===========================================
  # LIFECYCLE
  # ===========================================

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
        |> assign(:models, [])
        |> assign(:models_grouped, [])
        |> assign(:models_loading, false)
        |> assign(:models_error, nil)
        |> assign(:selected_model, nil)
        |> assign(:selected_provider, nil)
        |> assign(:provider_models, [])
        |> load_endpoint(params["id"])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "AI module is not enabled")
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  defp load_endpoint(socket, nil) do
    changeset = AI.change_endpoint(%Endpoint{})

    socket
    |> assign(:page_title, "New AI Endpoint")
    |> assign(:endpoint, nil)
    |> assign(:form, to_form(changeset))
  end

  defp load_endpoint(socket, id) do
    case AI.get_endpoint(String.to_integer(id)) do
      nil ->
        socket
        |> put_flash(:error, "Endpoint not found")
        |> push_navigate(to: Routes.ai_path())

      endpoint ->
        changeset = AI.change_endpoint(endpoint)

        socket =
          socket
          |> assign(:page_title, "Edit AI Endpoint")
          |> assign(:endpoint, endpoint)
          |> assign(:form, to_form(changeset))

        # Load models if endpoint has API key
        if endpoint.api_key && String.length(endpoint.api_key) > 10 do
          send(self(), {:fetch_models, endpoint.api_key})
          assign(socket, :models_loading, true)
        else
          socket
        end
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(params)
      |> Map.put(:action, :validate)

    # Update selected model when model changes
    selected_model =
      case params["model"] do
        nil -> socket.assigns.selected_model
        "" -> nil
        model_id -> find_model(socket.assigns.models, model_id)
      end

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, selected_model)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => ""}, socket) do
    # Reset provider selection
    socket =
      socket
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    # Find models for this provider
    provider_models =
      case Enum.find(socket.assigns.models_grouped, fn {p, _} -> p == provider end) do
        {_, models} -> models
        nil -> []
      end

    socket =
      socket
      |> assign(:selected_provider, provider)
      |> assign(:provider_models, provider_models)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"_target" => ["model"], "model" => ""}, socket) do
    # Ignore when reset to placeholder
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"model" => model_id}, socket) when model_id != "" do
    # Find the model details
    selected_model = find_model(socket.assigns.models, model_id)

    # Update the form with new model
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", model_id)

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, selected_model)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_model", _params, socket) do
    # Clear the model selection
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", "")

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_manual_model", %{"model" => model_id}, socket) when model_id != "" do
    # Set model from manual input (when models list not loaded)
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", model_id)

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_manual_model", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_reasoning", _params, socket) do
    # Toggle the reasoning_enabled value in form params
    current_value =
      socket.assigns.form.params["reasoning_enabled"] == "true" ||
        socket.assigns.form.params["reasoning_enabled"] == true ||
        (socket.assigns.endpoint && socket.assigns.endpoint.reasoning_enabled == true)

    new_value = if current_value, do: "false", else: "true"
    updated_params = Map.put(socket.assigns.form.params, "reasoning_enabled", new_value)

    form = %{socket.assigns.form | params: updated_params}
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("validate_api_key", _params, socket) do
    api_key =
      socket.assigns.form.params["api_key"] ||
        (socket.assigns.endpoint && socket.assigns.endpoint.api_key) ||
        ""

    if String.length(api_key) > 10 do
      socket =
        socket
        |> assign(:validating_api_key, true)
        |> assign(:models_loading, true)

      send(self(), {:do_validate_api_key, api_key})
      {:noreply, socket}
    else
      {:noreply, assign(socket, api_key_error: "Please enter an API key first")}
    end
  end

  @impl true
  def handle_event("save", %{"endpoint" => params}, socket) do
    # Merge provider_settings from nested params
    provider_settings = %{
      "http_referer" => get_in(params, ["provider_settings", "http_referer"]) || "",
      "x_title" => get_in(params, ["provider_settings", "x_title"]) || ""
    }

    params = Map.put(params, "provider_settings", provider_settings)

    # Parse numeric fields and string lists
    params =
      params
      |> parse_float("temperature")
      |> parse_integer("max_tokens")
      |> parse_float("top_p")
      |> parse_integer("top_k")
      |> parse_float("frequency_penalty")
      |> parse_float("presence_penalty")
      |> parse_float("repetition_penalty")
      |> parse_integer("seed")
      |> parse_integer("dimensions")
      |> parse_string_list("stop")

    save_endpoint(socket, params)
  end

  defp parse_float(params, key) do
    case params[key] do
      nil ->
        params

      "" ->
        Map.put(params, key, nil)

      val when is_binary(val) ->
        case Float.parse(val) do
          {num, _} -> Map.put(params, key, num)
          :error -> params
        end

      _ ->
        params
    end
  end

  defp parse_integer(params, key) do
    case params[key] do
      nil ->
        params

      "" ->
        Map.put(params, key, nil)

      val when is_binary(val) ->
        case Integer.parse(val) do
          {num, _} -> Map.put(params, key, num)
          :error -> params
        end

      _ ->
        params
    end
  end

  defp parse_string_list(params, key) do
    case params[key] do
      nil ->
        params

      "" ->
        Map.put(params, key, nil)

      val when is_binary(val) ->
        # Split by newlines and filter empty strings
        list =
          val
          |> String.split(~r/[\r\n]+/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if list == [] do
          Map.put(params, key, nil)
        else
          Map.put(params, key, list)
        end

      _ ->
        params
    end
  end

  defp save_endpoint(socket, params) do
    result =
      if socket.assigns.endpoint do
        AI.update_endpoint(socket.assigns.endpoint, params)
      else
        AI.create_endpoint(params)
      end

    case result do
      {:ok, _endpoint} ->
        action = if socket.assigns.endpoint, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Endpoint #{action} successfully")
         |> push_navigate(to: Routes.ai_path())}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:do_validate_api_key, api_key}, socket) do
    case OpenRouterClient.validate_api_key(api_key) do
      {:ok, _data} ->
        # Also fetch models on successful validation
        send(self(), {:fetch_models, api_key})

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
          |> assign(:models_loading, false)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:fetch_models, api_key}, socket) do
    case OpenRouterClient.fetch_models_grouped(api_key, type: :all) do
      {:ok, grouped} ->
        # Flatten for easy lookup
        models =
          grouped
          |> Enum.flat_map(fn {_provider, models} -> models end)

        # Set selected model if editing existing endpoint
        selected_model =
          case socket.assigns.endpoint do
            %{model: model_id} when is_binary(model_id) and model_id != "" ->
              find_model(models, model_id)

            _ ->
              nil
          end

        socket =
          socket
          |> assign(:models_loading, false)
          |> assign(:models, models)
          |> assign(:models_grouped, grouped)
          |> assign(:models_error, nil)
          |> assign(:selected_model, selected_model)

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:models_loading, false)
          |> assign(:models_error, reason)

        {:noreply, socket}
    end
  end

  # Private helpers

  defp find_model(models, model_id) do
    Enum.find(models, fn m -> m["id"] == model_id end)
  end

  @doc """
  Parameter definitions with type, constraints, and UI metadata.
  Only parameters we support in the UI are defined here.
  """
  def parameter_definitions do
    %{
      # Basic parameters
      "temperature" => %{
        type: :float,
        label: "Temperature",
        min: 0,
        max: 2,
        step: 0.1,
        default: 0.7,
        field: :temperature,
        group: :basic,
        description: "Controls randomness in responses"
      },
      "max_tokens" => %{
        type: :integer,
        label: "Max Tokens",
        min: 1,
        field: :max_tokens,
        group: :basic,
        description: "Maximum tokens to generate"
      },
      "top_p" => %{
        type: :float,
        label: "Top P",
        min: 0,
        max: 1,
        step: 0.1,
        field: :top_p,
        group: :basic,
        description: "Nucleus sampling threshold"
      },
      "top_k" => %{
        type: :integer,
        label: "Top K",
        min: 1,
        field: :top_k,
        group: :basic,
        description: "Top-k sampling parameter"
      },
      # Advanced parameters
      "frequency_penalty" => %{
        type: :float,
        label: "Frequency Penalty",
        min: -2,
        max: 2,
        step: 0.1,
        field: :frequency_penalty,
        group: :advanced,
        description: "Penalize frequent tokens"
      },
      "presence_penalty" => %{
        type: :float,
        label: "Presence Penalty",
        min: -2,
        max: 2,
        step: 0.1,
        field: :presence_penalty,
        group: :advanced,
        description: "Penalize tokens already present"
      },
      "repetition_penalty" => %{
        type: :float,
        label: "Repetition Penalty",
        min: 0,
        max: 2,
        step: 0.1,
        field: :repetition_penalty,
        group: :advanced,
        description: "Penalize repeated sequences"
      },
      "seed" => %{
        type: :integer,
        label: "Seed",
        field: :seed,
        group: :advanced,
        placeholder: "Random",
        description: "For reproducible outputs"
      },
      "stop" => %{
        type: :string_list,
        label: "Stop Sequences",
        field: :stop,
        group: :advanced,
        placeholder: "One per line",
        description: "Sequences that stop generation"
      }
    }
  end

  @doc """
  Returns parameters supported by the model, filtered to ones we have UI for.
  Groups them by :basic and :advanced.
  """
  def get_supported_params(nil) do
    # No model selected - show all parameters
    definitions = parameter_definitions()
    group_parameters(Map.keys(definitions), definitions)
  end

  def get_supported_params(model) when is_map(model) do
    supported = model["supported_parameters"] || []
    definitions = parameter_definitions()

    # Filter to parameters we have definitions for AND model supports
    supported_keys = Enum.filter(supported, &Map.has_key?(definitions, &1))
    group_parameters(supported_keys, definitions)
  end

  defp group_parameters(keys, definitions) do
    keys
    |> Enum.map(fn key -> {key, definitions[key]} end)
    |> Enum.group_by(fn {_key, def} -> def.group end)
    |> Map.new(fn {group, params} ->
      {group, Enum.sort_by(params, fn {key, _} -> key end)}
    end)
  end

  @doc """
  Gets the max tokens limit for the selected model.
  """
  def model_max_tokens(nil), do: nil

  def model_max_tokens(model) when is_map(model) do
    model["max_completion_tokens"] || model["context_length"]
  end

  @doc """
  Formats a number with thousands separators.
  """
  def format_number(nil), do: "0"
  def format_number(num) when is_integer(num), do: Integer.to_string(num) |> add_commas()
  def format_number(num) when is_float(num), do: round(num) |> Integer.to_string() |> add_commas()
  def format_number(num) when is_binary(num), do: num

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
