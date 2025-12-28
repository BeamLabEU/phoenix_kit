defmodule PhoenixKitWeb.Modules.Emails.Live.Templates do
  @moduledoc """
  LiveView for displaying and managing email templates in PhoenixKit admin panel.

  Provides comprehensive template management interface with filtering, searching,
  creation, editing, and analytics for email templates.

  ## Features

  - **Real-time Template List**: Live updates of templates
  - **Advanced Filtering**: By category, status, system vs custom
  - **Search Functionality**: Search across template names, descriptions
  - **Template Management**: Create, edit, clone, archive templates
  - **Usage Analytics**: View template usage statistics
  - **Test Send**: Send test emails using templates
  - **System Templates**: Manage core system templates

  ## Route

  This LiveView is mounted at `{prefix}/admin/modules/emails/templates` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-templates", PhoenixKitWeb.Live.Modules.Emails.EmailTemplatesLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  @default_per_page 25
  @max_per_page 100

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:page_title, "Email Templates")
      |> assign(:project_title, project_title)
      |> assign(:templates, [])
      |> assign(:total_count, 0)
      |> assign(:stats, %{})
      |> assign(:loading, true)
      |> assign(:show_clone_modal, false)
      |> assign(:clone_template, nil)
      |> assign(:clone_form, %{name: "", display_name: "", errors: %{}})
      |> assign(:confirmation_modal, %{show: false})
      |> assign_filter_defaults()
      |> assign_pagination_defaults()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_templates()
      |> load_stats()

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("filter", params, socket) do
    # Handle both search and filter parameters
    combined_params = %{}

    # Extract search parameters
    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    # Extract filter parameters
    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    # Reset to first page when filtering
    combined_params = Map.put(combined_params, "page", "1")

    # Build new URL parameters
    new_params = build_url_params(socket.assigns, combined_params)

    {:noreply,
     socket
     |> push_patch(to: Routes.path("/admin/modules/emails/templates?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> push_patch(to: Routes.path("/admin/modules/emails/templates"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_templates()
     |> load_stats()}
  end

  @impl true
  def handle_event("show_clone_modal", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      template ->
        {:noreply,
         socket
         |> assign(:show_clone_modal, true)
         |> assign(:clone_template, template)
         |> assign(:clone_form, %{
           name: "#{template.name}_copy",
           display_name: "#{template.display_name} (Copy)",
           errors: %{}
         })}
    end
  end

  @impl true
  def handle_event("hide_clone_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_clone_modal, false)
     |> assign(:clone_template, nil)
     |> assign(:clone_form, %{name: "", display_name: "", errors: %{}})}
  end

  @impl true
  def handle_event("validate_clone", %{"clone" => clone_params}, socket) do
    errors = validate_clone_form(clone_params)

    form = %{
      name: clone_params["name"] || "",
      display_name: clone_params["display_name"] || "",
      errors: errors
    }

    {:noreply, assign(socket, :clone_form, form)}
  end

  @impl true
  def handle_event("clone_template", %{"clone" => clone_params}, socket) do
    errors = validate_clone_form(clone_params)

    if map_size(errors) == 0 and socket.assigns.clone_template do
      case Templates.clone_template(
             socket.assigns.clone_template,
             String.trim(clone_params["name"]),
             %{display_name: clone_params["display_name"]}
           ) do
        {:ok, new_template} ->
          {:noreply,
           socket
           |> assign(:show_clone_modal, false)
           |> assign(:clone_template, nil)
           |> put_flash(:info, "Template cloned successfully as '#{new_template.name}'")
           |> push_navigate(
             to: Routes.path("/admin/modules/emails/templates/#{new_template.id}/edit")
           )}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to clone template")}
      end
    else
      # Show validation errors
      form = %{
        name: clone_params["name"] || "",
        display_name: clone_params["display_name"] || "",
        errors: errors
      }

      {:noreply, assign(socket, :clone_form, form)}
    end
  end

  @impl true
  def handle_event("edit_template", %{"id" => template_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/modules/emails/templates/#{template_id}/edit"))}
  end

  @impl true
  def handle_event("archive_template", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      %Template{is_system: true} ->
        {:noreply,
         socket
         |> put_flash(:error, "System templates cannot be archived")}

      template ->
        case Templates.archive_template(template) do
          {:ok, _archived_template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template '#{template.name}' archived successfully")
             |> load_templates()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to archive template")}
        end
    end
  end

  @impl true
  def handle_event("activate_template", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      template ->
        case Templates.activate_template(template) do
          {:ok, _activated_template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template '#{template.name}' activated successfully")
             |> load_templates()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to activate template")}
        end
    end
  end

  @impl true
  def handle_event("request_delete", %{"id" => id, "name" => name}, socket) do
    modal = %{
      show: true,
      title: "Confirm Delete",
      message:
        "Are you sure you want to delete template '#{name}'? This action cannot be undone.",
      button_text: "Delete Template",
      action: "delete_template",
      id: id
    }

    {:noreply, assign(socket, :confirmation_modal, modal)}
  end

  @impl true
  def handle_event("cancel_confirmation", _params, socket) do
    {:noreply, assign(socket, :confirmation_modal, %{show: false})}
  end

  @impl true
  def handle_event("confirm_action", %{"action" => "delete_template", "id" => id}, socket) do
    socket = assign(socket, :confirmation_modal, %{show: false})
    handle_event("delete_template", %{"id" => id}, socket)
  end

  @impl true
  def handle_event("delete_template", %{"id" => template_id}, socket) do
    case Templates.get_template(String.to_integer(template_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")}

      %Template{is_system: true} ->
        {:noreply,
         socket
         |> put_flash(:error, "System templates cannot be deleted")}

      template ->
        case Templates.delete_template(template) do
          {:ok, _deleted_template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template '#{template.name}' deleted successfully")
             |> load_templates()
             |> load_stats()}

          {:error, :system_template_protected} ->
            {:noreply,
             socket
             |> put_flash(:error, "System templates cannot be deleted")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to delete template")}
        end
    end
  end

  ## --- Template ---

  ## --- Private Helper Functions ---

  # Apply default filter values
  defp assign_filter_defaults(socket) do
    filters = %{
      search: "",
      category: "",
      status: "",
      is_system: ""
    }

    assign(socket, :filters, filters)
  end

  # Apply default pagination values
  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 0)
  end

  # Apply URL parameters to socket assigns
  defp apply_params(socket, params) do
    filters = %{
      search: params["search"] || "",
      category: params["category"] || "",
      status: params["status"] || "",
      is_system: params["is_system"] || ""
    }

    page = String.to_integer(params["page"] || "1")
    per_page = min(String.to_integer(params["per_page"] || "#{@default_per_page}"), @max_per_page)

    socket
    |> assign(:filters, filters)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
  end

  # Load templates based on current filters and pagination
  defp load_templates(socket) do
    %{filters: filters, page: page, per_page: per_page} = socket.assigns

    # Build filters for Templates query
    query_filters = build_query_filters(filters, page, per_page)

    templates = Templates.list_templates(query_filters)

    # Get total count for pagination
    total_count = Templates.count_templates(Map.drop(query_filters, [:limit, :offset]))

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:templates, templates)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:loading, false)
  end

  # Load template statistics
  defp load_stats(socket) do
    stats = Templates.get_template_stats()
    assign(socket, :stats, stats)
  end

  # Build query filters from form filters
  defp build_query_filters(filters, page, per_page) do
    query_filters = %{
      limit: per_page,
      offset: (page - 1) * per_page,
      order_by: :inserted_at,
      order_direction: :desc
    }

    # Add non-empty filters
    filters
    |> Enum.reduce(query_filters, fn
      {:search, search}, acc when search != "" ->
        Map.put(acc, :search, search)

      {:category, category}, acc when category != "" ->
        Map.put(acc, :category, category)

      {:status, status}, acc when status != "" ->
        Map.put(acc, :status, status)

      {:is_system, is_system}, acc when is_system != "" ->
        Map.put(acc, :is_system, is_system == "true")

      _, acc ->
        acc
    end)
  end

  # Build URL parameters from current state
  defp build_url_params(assigns, additional_params) do
    base_params = %{
      "search" => assigns.filters.search,
      "category" => assigns.filters.category,
      "status" => assigns.filters.status,
      "is_system" => assigns.filters.is_system,
      "page" => assigns.page,
      "per_page" => assigns.per_page
    }

    Map.merge(base_params, additional_params)
    |> Enum.reject(fn {_key, value} -> value == "" or is_nil(value) end)
    |> Map.new()
    |> URI.encode_query()
  end

  # Validate clone form
  defp validate_clone_form(params) do
    errors = %{}

    # Validate name
    errors =
      case String.trim(params["name"] || "") do
        "" ->
          Map.put(errors, :name, "Name is required")

        name ->
          if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
            # Check if name already exists
            case Templates.get_template_by_name(name) do
              nil -> errors
              _ -> Map.put(errors, :name, "Name already exists")
            end
          else
            Map.put(
              errors,
              :name,
              "Must start with a letter and contain only lowercase letters, numbers, and underscores"
            )
          end
      end

    # Validate display_name
    errors =
      case String.trim(params["display_name"] || "") do
        "" ->
          Map.put(errors, :display_name, "Display name is required")

        _ ->
          errors
      end

    errors
  end
end
