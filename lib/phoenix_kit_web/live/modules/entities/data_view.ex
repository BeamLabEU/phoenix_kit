defmodule PhoenixKitWeb.Live.Modules.Entities.DataView do
  @moduledoc """
  LiveView for viewing entity data records.
  Displays data with public form fields separated from other fields.
  Uses FormBuilder with disabled fields for the form section.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKitWeb.Live.Modules.Entities.Hooks

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Entities.FormBuilder
  alias PhoenixKit.Settings

  @impl true
  def mount(%{"entity_slug" => entity_slug, "id" => id} = params, _session, socket) do
    locale =
      params["locale"] || socket.assigns[:current_locale]

    entity = Entities.get_entity_by_name(entity_slug)
    data_record = EntityData.get_data!(String.to_integer(id))

    mount_data_view(socket, entity, data_record, locale)
  end

  def mount(%{"entity_id" => entity_id, "id" => id} = params, _session, socket) do
    locale =
      params["locale"] || socket.assigns[:current_locale]

    entity = Entities.get_entity!(String.to_integer(entity_id))
    data_record = EntityData.get_data!(String.to_integer(id))

    mount_data_view(socket, entity, data_record, locale)
  end

  defp mount_data_view(socket, entity, data_record, locale) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Get public form configuration
    settings = entity.settings || %{}
    public_form_enabled = Map.get(settings, "public_form_enabled", false)
    public_form_fields = Map.get(settings, "public_form_fields", [])

    # Check if this record was submitted via public form
    is_public_submission = public_submission?(data_record.metadata)

    # Get all field definitions
    fields_definition = entity.fields_definition || []

    # Separate fields into form fields and other fields
    # Show form fields separately if:
    # 1. Public form is currently enabled, OR
    # 2. This record was submitted via public form (even if form is now disabled)
    {form_fields, other_fields} =
      if public_form_enabled || is_public_submission do
        Enum.split_with(fields_definition, fn field ->
          field["key"] in public_form_fields
        end)
      else
        # If public form not enabled and not a public submission, all fields go to "other"
        {[], fields_definition}
      end

    # Get data values
    data = data_record.data || %{}

    # Create changeset for FormBuilder (readonly display)
    changeset = EntityData.change(data_record)

    # Create a modified entity with only form fields for FormBuilder
    form_entity = %{entity | fields_definition: form_fields}

    # Create a modified entity with only other fields for display
    other_entity = %{entity | fields_definition: other_fields}

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("View Data"))
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:form_entity, form_entity)
      |> assign(:other_entity, other_entity)
      |> assign(:data_record, data_record)
      |> assign(:changeset, changeset)
      |> assign(:data, data)
      |> assign(:public_form_enabled, public_form_enabled)
      |> assign(:form_fields, form_fields)
      |> assign(:other_fields, other_fields)
      |> assign(:public_form_title, Map.get(settings, "public_form_title", ""))
      |> assign(:public_form_description, Map.get(settings, "public_form_description", ""))
      |> assign(:metadata, data_record.metadata || %{})
      |> assign(:is_public_submission, public_submission?(data_record.metadata))

    {:ok, socket}
  end

  defp public_submission?(nil), do: false
  defp public_submission?(metadata), do: Map.get(metadata, "source") == "public_form"

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={
        gettext("%{project_title} View %{entity}",
          project_title: @project_title,
          entity: @entity.display_name
        )
      }
      current_path={@url_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button --%>
          <.link
            navigate={PhoenixKit.Utils.Routes.path("/admin/entities/#{@entity.name}/data")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_arrow_left />
            {gettext("Back to %{entity} Data", entity: @entity.display_name)}
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">
              {@data_record.title}
            </h1>
            <p class="text-lg text-base-content/70">
              {gettext("Viewing %{entity} record", entity: @entity.display_name)}
            </p>
            <%= if @data_record.slug do %>
              <p class="text-sm text-base-content/50 mt-2">
                <.icon name="hero-link" class="w-4 h-4 inline" />
                {@data_record.slug}
              </p>
            <% end %>
          </div>
        </header>

        <%!-- Record Metadata --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-4">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              {gettext("Record Information")}
            </h2>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <span class="text-sm text-base-content/60">{gettext("Status")}</span>
                <div class="mt-1">
                  <span class={"badge #{status_badge_class(@data_record.status)}"}>
                    {@data_record.status}
                  </span>
                </div>
              </div>
              <div>
                <span class="text-sm text-base-content/60">{gettext("Created")}</span>
                <div class="mt-1 font-medium">
                  {PhoenixKit.Utils.Date.format_datetime_with_user_format(@data_record.date_created)}
                </div>
              </div>
              <div>
                <span class="text-sm text-base-content/60">{gettext("Updated")}</span>
                <div class="mt-1 font-medium">
                  {PhoenixKit.Utils.Date.format_datetime_with_user_format(@data_record.date_updated)}
                </div>
              </div>
            </div>
          </div>
        </div>

        <%= if (@public_form_enabled || @is_public_submission) && length(@form_fields) > 0 do %>
          <%!-- Public Form Fields Section - Using FormBuilder with disabled inputs --%>
          <div class="card bg-base-100 shadow-xl mb-6">
            <div class="card-body">
              <h2 class="card-title text-xl mb-2">
                <.icon name="hero-document-text" class="w-5 h-5" />
                <%= if @public_form_title != "" do %>
                  {@public_form_title}
                <% else %>
                  {gettext("Form Submission")}
                <% end %>
              </h2>
              <%= if @public_form_description != "" do %>
                <p class="text-base-content/70 mb-4">{@public_form_description}</p>
              <% end %>

              <%!-- Use FormBuilder with disabled fields --%>
              {FormBuilder.build_fields(@form_entity, @changeset,
                wrapper_class: "mb-4",
                disabled: true
              )}
            </div>
          </div>
        <% end %>

        <%= if @is_public_submission do %>
          <%!-- Security Warnings Section (if any) --%>
          <%= if @metadata["security_warnings"] && length(@metadata["security_warnings"]) > 0 do %>
            <div class="alert alert-warning mb-6">
              <.icon name="hero-exclamation-triangle" class="w-6 h-6" />
              <div>
                <h3 class="font-bold">{gettext("Security Flags")}</h3>
                <div class="text-sm mt-1">
                  <%= for warning <- @metadata["security_warnings"] do %>
                    <div class="flex items-center gap-2 mt-1">
                      <span class="badge badge-warning badge-sm">
                        {security_warning_label(warning["type"])}
                      </span>
                      <span class="text-xs text-base-content/70">
                        {security_action_label(warning["action"])}
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Submission Metadata Section --%>
          <div class="card bg-base-100 shadow-xl mb-6">
            <div class="card-body">
              <h2 class="card-title text-xl mb-4">
                <.icon name="hero-globe-alt" class="w-5 h-5" />
                {gettext("Submission Details")}
              </h2>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <%= if @metadata["ip_address"] do %>
                  <div class="flex items-start gap-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon name="hero-signal" class="w-5 h-5 text-base-content/60" />
                    </div>
                    <div>
                      <span class="text-sm text-base-content/60">{gettext("IP Address")}</span>
                      <div class="font-mono text-sm">{@metadata["ip_address"]}</div>
                    </div>
                  </div>
                <% end %>

                <%= if @metadata["browser"] do %>
                  <div class="flex items-start gap-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon name="hero-window" class="w-5 h-5 text-base-content/60" />
                    </div>
                    <div>
                      <span class="text-sm text-base-content/60">{gettext("Browser")}</span>
                      <div class="font-medium">{@metadata["browser"]}</div>
                    </div>
                  </div>
                <% end %>

                <%= if @metadata["os"] do %>
                  <div class="flex items-start gap-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon name="hero-computer-desktop" class="w-5 h-5 text-base-content/60" />
                    </div>
                    <div>
                      <span class="text-sm text-base-content/60">{gettext("Operating System")}</span>
                      <div class="font-medium">{@metadata["os"]}</div>
                    </div>
                  </div>
                <% end %>

                <%= if @metadata["device"] do %>
                  <div class="flex items-start gap-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon
                        name={device_icon(@metadata["device"])}
                        class="w-5 h-5 text-base-content/60"
                      />
                    </div>
                    <div>
                      <span class="text-sm text-base-content/60">{gettext("Device")}</span>
                      <div class="font-medium capitalize">{@metadata["device"]}</div>
                    </div>
                  </div>
                <% end %>

                <%= if @metadata["submitted_at"] do %>
                  <div class="flex items-start gap-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon name="hero-clock" class="w-5 h-5 text-base-content/60" />
                    </div>
                    <div>
                      <span class="text-sm text-base-content/60">{gettext("Submitted At")}</span>
                      <div class="font-medium">{format_submitted_at(@metadata["submitted_at"])}</div>
                    </div>
                  </div>
                <% end %>

                <%= if @metadata["time_to_submit_seconds"] do %>
                  <div class="flex items-start gap-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon name="hero-stopwatch" class="w-5 h-5 text-base-content/60" />
                    </div>
                    <div>
                      <span class="text-sm text-base-content/60">{gettext("Time to Submit")}</span>
                      <div class="font-medium">
                        {format_duration(@metadata["time_to_submit_seconds"])}
                      </div>
                    </div>
                  </div>
                <% end %>

                <%= if @metadata["referer"] do %>
                  <div class="flex items-start gap-3 md:col-span-2 lg:col-span-3">
                    <div class="p-2 bg-base-200 rounded-lg">
                      <.icon
                        name="hero-arrow-top-right-on-square"
                        class="w-5 h-5 text-base-content/60"
                      />
                    </div>
                    <div class="min-w-0 flex-1">
                      <span class="text-sm text-base-content/60">{gettext("Referrer")}</span>
                      <div class="font-mono text-sm truncate" title={@metadata["referer"]}>
                        {@metadata["referer"]}
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>

              <%= if @metadata["user_agent"] do %>
                <div class="mt-4 pt-4 border-t border-base-200">
                  <details class="collapse collapse-arrow bg-base-200 rounded-lg">
                    <summary class="collapse-title text-sm font-medium py-2 min-h-0">
                      {gettext("Full User Agent")}
                    </summary>
                    <div class="collapse-content">
                      <code class="text-xs break-all">{@metadata["user_agent"]}</code>
                    </div>
                  </details>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if length(@other_fields) > 0 do %>
          <%!-- Other Fields Section - Using FormBuilder with disabled inputs --%>
          <div class="card bg-base-100 shadow-xl mb-6">
            <div class="card-body">
              <h2 class="card-title text-xl mb-4">
                <.icon name="hero-squares-2x2" class="w-5 h-5" />
                <%= if (@public_form_enabled || @is_public_submission) && length(@form_fields) > 0 do %>
                  {gettext("Additional Data")}
                <% else %>
                  {gettext("Data Fields")}
                <% end %>
              </h2>

              <%!-- Use FormBuilder with disabled fields --%>
              {FormBuilder.build_fields(@other_entity, @changeset,
                wrapper_class: "mb-4",
                disabled: true
              )}
            </div>
          </div>
        <% end %>

        <%= if map_size(@data) == 0 && length(@form_fields) == 0 && length(@other_fields) == 0 do %>
          <%!-- Empty State --%>
          <div class="card bg-base-100 shadow-xl mb-6">
            <div class="card-body text-center py-12">
              <div class="text-4xl mb-4 opacity-50">📄</div>
              <p class="text-base-content/60">{gettext("No data fields have been filled in yet.")}</p>
            </div>
          </div>
        <% end %>

        <%!-- Actions --%>
        <div class="flex justify-between items-center">
          <.link
            navigate={PhoenixKit.Utils.Routes.path("/admin/entities/#{@entity.name}/data")}
            class="btn btn-outline"
          >
            {gettext("Back")}
          </.link>

          <.link
            navigate={
              PhoenixKit.Utils.Routes.path(
                "/admin/entities/#{@entity.name}/data/#{@data_record.id}/edit"
              )
            }
            class="btn btn-primary"
          >
            <.icon name="hero-pencil" class="w-4 h-4 mr-2" />
            {gettext("Edit %{entity}", entity: @entity.display_name)}
          </.link>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp status_badge_class("published"), do: "badge-success"
  defp status_badge_class("draft"), do: "badge-warning"
  defp status_badge_class("archived"), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-ghost"

  defp device_icon("mobile"), do: "hero-device-phone-mobile"
  defp device_icon("tablet"), do: "hero-device-tablet"
  defp device_icon(_), do: "hero-computer-desktop"

  defp format_submitted_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} ->
        PhoenixKit.Utils.Date.format_datetime_with_user_format(datetime)

      _ ->
        iso_string
    end
  end

  defp format_submitted_at(_), do: "-"

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 ->
        ngettext("%{count} second", "%{count} seconds", seconds, count: seconds)

      seconds < 3600 ->
        minutes = div(seconds, 60)
        ngettext("%{count} minute", "%{count} minutes", minutes, count: minutes)

      true ->
        hours = div(seconds, 3600)
        minutes = div(rem(seconds, 3600), 60)

        if minutes > 0 do
          "#{ngettext("%{count} hour", "%{count} hours", hours, count: hours)}, #{ngettext("%{count} minute", "%{count} minutes", minutes, count: minutes)}"
        else
          ngettext("%{count} hour", "%{count} hours", hours, count: hours)
        end
    end
  end

  defp format_duration(_), do: "-"

  defp security_warning_label("honeypot"), do: gettext("Honeypot triggered")
  defp security_warning_label("too_fast"), do: gettext("Submitted too fast")
  defp security_warning_label("rate_limited"), do: gettext("Rate limited")
  defp security_warning_label(type), do: type

  defp security_action_label("save_suspicious"), do: gettext("Marked as suspicious")
  defp security_action_label("save_log"), do: gettext("Logged warning")
  defp security_action_label(action), do: action
end
