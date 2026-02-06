defmodule PhoenixKit.Modules.Shop.Web.ImportConfigs do
  @moduledoc """
  Import configurations management LiveView.

  Allows administrators to manage CSV import filter configurations
  including keyword filters, category rules, and option mappings.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    # Auto-seed defaults on first visit
    Shop.ensure_default_import_config()

    configs = Shop.list_import_configs(active_only: false)

    socket =
      socket
      |> assign(:page_title, "Import Configurations")
      |> assign(:configs, configs)
      |> assign(:show_modal, false)
      |> assign(:editing_config, nil)
      |> assign(:form_data, initial_form_data())
      |> assign(:delete_confirm_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("show_add_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing_config, nil)
     |> assign(:form_data, initial_form_data())}
  end

  @impl true
  def handle_event("show_edit_modal", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.configs, &(to_string(&1.id) == id))

    if config do
      form_data = %{
        name: config.name || "",
        skip_filter: config.skip_filter || false,
        include_keywords_text: Enum.join(config.include_keywords || [], ", "),
        exclude_keywords_text: Enum.join(config.exclude_keywords || [], ", "),
        exclude_phrases_text: Enum.join(config.exclude_phrases || [], ", "),
        category_rules: config.category_rules || [],
        default_category_slug: config.default_category_slug || "",
        download_images: config.download_images || false,
        is_default: config.is_default || false,
        active: config.active
      }

      {:noreply,
       socket
       |> assign(:show_modal, true)
       |> assign(:editing_config, config)
       |> assign(:form_data, form_data)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing_config, nil)
     |> assign(:form_data, initial_form_data())}
  end

  @impl true
  def handle_event("validate_form", %{"config" => params}, socket) do
    form_data = %{
      name: params["name"] || "",
      skip_filter: params["skip_filter"] == "true",
      include_keywords_text: params["include_keywords_text"] || "",
      exclude_keywords_text: params["exclude_keywords_text"] || "",
      exclude_phrases_text: params["exclude_phrases_text"] || "",
      category_rules: socket.assigns.form_data.category_rules,
      default_category_slug: params["default_category_slug"] || "",
      download_images: params["download_images"] == "true",
      is_default: params["is_default"] == "true",
      active: params["active"] == "true"
    }

    {:noreply, assign(socket, :form_data, form_data)}
  end

  @impl true
  def handle_event("save_config", %{"config" => params}, socket) do
    form_data = %{
      name: params["name"] || "",
      skip_filter: params["skip_filter"] == "true",
      include_keywords_text: params["include_keywords_text"] || "",
      exclude_keywords_text: params["exclude_keywords_text"] || "",
      exclude_phrases_text: params["exclude_phrases_text"] || "",
      category_rules: socket.assigns.form_data.category_rules,
      default_category_slug: params["default_category_slug"] || "",
      download_images: params["download_images"] == "true",
      is_default: params["is_default"] == "true",
      active: params["active"] == "true"
    }

    attrs = build_attrs(form_data)
    editing = socket.assigns.editing_config

    result =
      if editing do
        Shop.update_import_config(editing, attrs)
      else
        Shop.create_import_config(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:configs, Shop.list_import_configs(active_only: false))
         |> assign(:show_modal, false)
         |> assign(:editing_config, nil)
         |> assign(:form_data, initial_form_data())
         |> put_flash(:info, if(editing, do: "Config updated", else: "Config created"))}

      {:error, changeset} ->
        message = format_changeset_errors(changeset)
        {:noreply, put_flash(socket, :error, "Error: #{message}")}
    end
  end

  @impl true
  def handle_event("delete_config", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.configs, &(to_string(&1.id) == id))

    if config do
      case Shop.delete_import_config(config) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:configs, Shop.list_import_configs(active_only: false))
           |> put_flash(:info, "Config deleted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete config")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.configs, &(to_string(&1.id) == id))

    if config do
      case Shop.update_import_config(config, %{active: !config.active}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:configs, Shop.list_import_configs(active_only: false))
           |> put_flash(:info, "Config #{if config.active, do: "deactivated", else: "activated"}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update config")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_default", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.configs, &(to_string(&1.id) == id))

    if config do
      case Shop.update_import_config(config, %{is_default: true}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:configs, Shop.list_import_configs(active_only: false))
           |> put_flash(:info, "\"#{config.name}\" set as default")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to set default")}
      end
    else
      {:noreply, socket}
    end
  end

  # Category rule management
  @impl true
  def handle_event("add_category_rule", _params, socket) do
    form_data = socket.assigns.form_data
    new_rule = %{"keywords" => [], "slug" => "", "keywords_text" => ""}
    updated = %{form_data | category_rules: form_data.category_rules ++ [new_rule]}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("remove_category_rule", %{"index" => idx}, socket) do
    form_data = socket.assigns.form_data
    index = String.to_integer(idx)
    updated = %{form_data | category_rules: List.delete_at(form_data.category_rules, index)}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("update_category_rule", %{"index" => idx} = params, socket) do
    form_data = socket.assigns.form_data
    index = String.to_integer(idx)
    rule = Enum.at(form_data.category_rules, index)

    if rule do
      keywords_text = params["keywords"] || Map.get(rule, "keywords_text", "")
      slug = params["slug"] || Map.get(rule, "slug", "")
      keywords = parse_comma_list(keywords_text)

      updated_rule = %{
        "keywords" => keywords,
        "slug" => slug,
        "keywords_text" => keywords_text
      }

      updated_rules = List.replace_at(form_data.category_rules, index, updated_rule)
      {:noreply, assign(socket, :form_data, %{form_data | category_rules: updated_rules})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_skip_filter", _params, socket) do
    form_data = socket.assigns.form_data
    {:noreply, assign(socket, :form_data, %{form_data | skip_filter: !form_data.skip_filter})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop/settings")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">Import Configurations</h1>
              <p class="text-base-content/70 mt-1">
                Configure keyword filters and category rules for CSV product imports
              </p>
            </div>
          </div>
        </header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="flex flex-col lg:flex-row gap-4 justify-end">
            <button type="button" phx-click="show_add_modal" class="btn btn-primary">
              <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Config
            </button>
          </div>
        </div>

        <%!-- Info Alert --%>
        <div class="alert alert-info mb-6">
          <.icon name="hero-information-circle" class="w-6 h-6" />
          <div>
            <p class="font-medium">Import filter configurations</p>
            <p class="text-sm">
              Each config defines keyword filters and category rules for CSV imports.
              The default config is used when no specific config is selected during import.
            </p>
          </div>
        </div>

        <%!-- Configs List --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-funnel" class="w-5 h-5" /> Configurations
            </h2>

            <%= if @configs == [] do %>
              <div class="text-center py-12 text-base-content/60">
                <.icon name="hero-funnel" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                <p class="text-lg">No configurations defined yet</p>
                <p class="text-sm">Add your first import configuration to get started</p>
              </div>
            <% else %>
              <div class="flex flex-col gap-3">
                <%= for config <- @configs do %>
                  <div class="p-4 bg-base-200 rounded-lg hover:bg-base-300 transition-colors">
                    <div class="flex items-start justify-between">
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2 flex-wrap">
                          <span class="font-medium text-lg">{config.name}</span>
                          <%= if config.is_default do %>
                            <span class="badge badge-primary badge-sm">Default</span>
                          <% end %>
                          <%= if config.active do %>
                            <span class="badge badge-success badge-sm">Active</span>
                          <% else %>
                            <span class="badge badge-neutral badge-sm">Inactive</span>
                          <% end %>
                          <%= if config.skip_filter do %>
                            <span class="badge badge-warning badge-sm">Skip Filter</span>
                          <% end %>
                          <%= if config.download_images do %>
                            <span class="badge badge-info badge-sm">Download Images</span>
                          <% end %>
                        </div>
                        <div class="text-sm text-base-content/60 mt-1 flex flex-wrap gap-3">
                          <span>
                            <.icon name="hero-plus-circle" class="w-3 h-3 inline" />
                            {length(config.include_keywords)} include
                          </span>
                          <span>
                            <.icon name="hero-minus-circle" class="w-3 h-3 inline" />
                            {length(config.exclude_keywords)} exclude
                          </span>
                          <span>
                            <.icon name="hero-tag" class="w-3 h-3 inline" />
                            {length(config.category_rules)} category rules
                          </span>
                          <%= if config.default_category_slug && config.default_category_slug != "" do %>
                            <span>
                              <.icon name="hero-folder" class="w-3 h-3 inline" />
                              default: {config.default_category_slug}
                            </span>
                          <% end %>
                        </div>
                      </div>

                      <div class="flex items-center gap-1 shrink-0 ml-4">
                        <%= unless config.is_default do %>
                          <button
                            type="button"
                            phx-click="set_default"
                            phx-value-id={config.id}
                            class="btn btn-ghost btn-sm"
                            title="Set as default"
                          >
                            <.icon name="hero-star" class="w-4 h-4" />
                          </button>
                        <% end %>
                        <button
                          type="button"
                          phx-click="toggle_active"
                          phx-value-id={config.id}
                          class="btn btn-ghost btn-sm"
                          title={if config.active, do: "Deactivate", else: "Activate"}
                        >
                          <.icon
                            name={if config.active, do: "hero-eye", else: "hero-eye-slash"}
                            class="w-4 h-4"
                          />
                        </button>
                        <button
                          type="button"
                          phx-click="show_edit_modal"
                          phx-value-id={config.id}
                          class="btn btn-ghost btn-sm"
                        >
                          <.icon name="hero-pencil" class="w-4 h-4" />
                        </button>
                        <button
                          type="button"
                          phx-click="delete_config"
                          phx-value-id={config.id}
                          data-confirm="Delete this configuration?"
                          class="btn btn-ghost btn-sm text-error"
                        >
                          <.icon name="hero-trash" class="w-4 h-4" />
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Modal for Add/Edit Config --%>
      <%= if @show_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-2xl">
            <h3 class="font-bold text-lg mb-4">
              {if @editing_config, do: "Edit Configuration", else: "Add Configuration"}
            </h3>

            <.form
              for={%{}}
              phx-change="validate_form"
              phx-submit="save_config"
              class="space-y-4"
            >
              <%!-- Name --%>
              <div class="form-control">
                <label class="label"><span class="label-text">Name *</span></label>
                <input
                  type="text"
                  name="config[name]"
                  value={@form_data.name}
                  class="input input-bordered"
                  placeholder="e.g., decor_3d_default"
                  required
                />
              </div>

              <%!-- Status Toggles --%>
              <div class="grid grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input type="hidden" name="config[active]" value="false" />
                    <input
                      type="checkbox"
                      name="config[active]"
                      value="true"
                      checked={@form_data.active}
                      class="checkbox checkbox-primary"
                    />
                    <span class="label-text">Active</span>
                  </label>
                </div>
                <div class="form-control">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input type="hidden" name="config[is_default]" value="false" />
                    <input
                      type="checkbox"
                      name="config[is_default]"
                      value="true"
                      checked={@form_data.is_default}
                      class="checkbox checkbox-primary"
                    />
                    <span class="label-text">Default</span>
                  </label>
                </div>
              </div>

              <%!-- Skip Filter --%>
              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    class="toggle toggle-warning"
                    checked={@form_data.skip_filter}
                    phx-click="toggle_skip_filter"
                  />
                  <div>
                    <span class="label-text font-medium">Skip Filter</span>
                    <p class="text-xs text-base-content/60">
                      All products will be imported without keyword filtering
                    </p>
                  </div>
                </label>
              </div>
              <input
                type="hidden"
                name="config[skip_filter]"
                value={to_string(@form_data.skip_filter)}
              />

              <%!-- Filter Keywords (hidden when skip_filter is on) --%>
              <%= unless @form_data.skip_filter do %>
                <div class="divider text-sm text-base-content/50">Keyword Filters</div>

                <%!-- Include Keywords --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">
                      <.icon name="hero-plus-circle" class="w-4 h-4 inline text-success" />
                      Include Keywords
                    </span>
                  </label>
                  <textarea
                    name="config[include_keywords_text]"
                    class="textarea textarea-bordered h-20"
                    placeholder="shelf, mask, vase, planter, holder, stand, lamp"
                  >{@form_data.include_keywords_text}</textarea>
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">
                      Comma-separated. Product must match at least one keyword.
                    </span>
                    <span class="label-text-alt badge badge-sm badge-ghost">
                      {length(parse_comma_list(@form_data.include_keywords_text))} keywords
                    </span>
                  </label>
                </div>

                <%!-- Exclude Keywords --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">
                      <.icon name="hero-minus-circle" class="w-4 h-4 inline text-error" />
                      Exclude Keywords
                    </span>
                  </label>
                  <textarea
                    name="config[exclude_keywords_text]"
                    class="textarea textarea-bordered h-20"
                    placeholder="decal, sticker, mural, wallpaper, poster"
                  >{@form_data.exclude_keywords_text}</textarea>
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">
                      Comma-separated. Products matching these are excluded.
                    </span>
                    <span class="label-text-alt badge badge-sm badge-ghost">
                      {length(parse_comma_list(@form_data.exclude_keywords_text))} keywords
                    </span>
                  </label>
                </div>

                <%!-- Exclude Phrases --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">
                      <.icon name="hero-x-circle" class="w-4 h-4 inline text-error" /> Exclude Phrases
                    </span>
                  </label>
                  <textarea
                    name="config[exclude_phrases_text]"
                    class="textarea textarea-bordered h-16"
                    placeholder="wall art, home decor stickers"
                  >{@form_data.exclude_phrases_text}</textarea>
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">
                      Comma-separated phrases. Exact phrase match causes exclusion.
                    </span>
                  </label>
                </div>
              <% end %>

              <%!-- Category Rules --%>
              <div class="divider text-sm text-base-content/50">Category Rules</div>

              <div class="space-y-3">
                <%= for {rule, idx} <- Enum.with_index(@form_data.category_rules) do %>
                  <div class="flex gap-2 items-start bg-base-200 p-3 rounded-lg">
                    <div class="flex-1">
                      <input
                        type="text"
                        value={
                          Map.get(
                            rule,
                            "keywords_text",
                            Enum.join(Map.get(rule, "keywords", []), ", ")
                          )
                        }
                        class="input input-bordered input-sm w-full"
                        placeholder="Keywords (comma-separated)"
                        phx-blur="update_category_rule"
                        phx-value-index={idx}
                        name="keywords"
                      />
                    </div>
                    <div class="flex-1">
                      <input
                        type="text"
                        value={Map.get(rule, "slug", "")}
                        class="input input-bordered input-sm w-full"
                        placeholder="Category slug"
                        phx-blur="update_category_rule"
                        phx-value-index={idx}
                        name="slug"
                      />
                    </div>
                    <button
                      type="button"
                      phx-click="remove_category_rule"
                      phx-value-index={idx}
                      class="btn btn-ghost btn-sm text-error"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                <% end %>

                <button type="button" phx-click="add_category_rule" class="btn btn-ghost btn-sm">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Category Rule
                </button>
              </div>

              <%!-- Default Category Slug --%>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Default Category Slug</span>
                </label>
                <input
                  type="text"
                  name="config[default_category_slug]"
                  value={@form_data.default_category_slug}
                  class="input input-bordered input-sm"
                  placeholder="e.g., other-3d"
                />
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    Used when no category rule matches
                  </span>
                </label>
              </div>

              <%!-- Download Images --%>
              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input type="hidden" name="config[download_images]" value="false" />
                  <input
                    type="checkbox"
                    name="config[download_images]"
                    value="true"
                    checked={@form_data.download_images}
                    class="checkbox checkbox-primary"
                  />
                  <div>
                    <span class="label-text">Download Images</span>
                    <p class="text-xs text-base-content/60">
                      Download images from CDN URLs during import
                    </p>
                  </div>
                </label>
              </div>

              <%!-- Actions --%>
              <div class="modal-action">
                <button type="button" phx-click="close_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">
                  {if @editing_config, do: "Update", else: "Create"}
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_modal"></div>
        </div>
      <% end %>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # Private helpers

  defp initial_form_data do
    %{
      name: "",
      skip_filter: false,
      include_keywords_text: "",
      exclude_keywords_text: "",
      exclude_phrases_text: "",
      category_rules: [],
      default_category_slug: "",
      download_images: false,
      is_default: false,
      active: true
    }
  end

  defp build_attrs(form_data) do
    category_rules =
      form_data.category_rules
      |> Enum.map(fn rule ->
        keywords_text =
          Map.get(rule, "keywords_text", Enum.join(Map.get(rule, "keywords", []), ", "))

        %{
          "keywords" => parse_comma_list(keywords_text),
          "slug" => Map.get(rule, "slug", "")
        }
      end)
      |> Enum.reject(fn rule -> rule["slug"] == "" and rule["keywords"] == [] end)

    %{
      name: form_data.name,
      skip_filter: form_data.skip_filter,
      include_keywords: parse_comma_list(form_data.include_keywords_text),
      exclude_keywords: parse_comma_list(form_data.exclude_keywords_text),
      exclude_phrases: parse_comma_list(form_data.exclude_phrases_text),
      category_rules: category_rules,
      default_category_slug: form_data.default_category_slug,
      download_images: form_data.download_images,
      is_default: form_data.is_default,
      active: form_data.active
    }
  end

  defp parse_comma_list(text) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_comma_list(_), do: []

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end
end
