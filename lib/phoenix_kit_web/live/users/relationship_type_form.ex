defmodule PhoenixKitWeb.Live.Users.RelationshipTypeForm do
  @moduledoc """
  Add or edit a relationship type: its translated names and, on creation, what people of
  this type can do. The key comes from the name and stays out of the way unless the name
  has no Latin letters to make one from.

  Every type offered here acts for an organization, until the links that grant no access
  exist. What it can do is fixed at creation, so the edit form shows it as text.
  """
  use PhoenixKitWeb, :live_view

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

  @translatable_fields ["name", "inverse_name"]
  @acting %{"from_kind" => "person", "to_kind" => "organization", "can_act" => "true"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, mount_multilang(socket, open_on: :primary)}

  @impl true
  def handle_params(params, _uri, socket) do
    case load_type(socket.assigns.live_action, params) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Relationship type not found"))
         |> push_navigate(to: index_path())}

      type ->
        {:noreply,
         socket
         |> assign(
           type: type,
           page_title: page_title(socket.assigns.live_action),
           page_section: gettext("Users"),
           page_section_path: Routes.path("/admin/users"),
           page_crumbs: [
             %{label: gettext("Relationship types"), path: index_path()}
           ],
           derived_key: nil
         )
         |> assign_changeset(RelationshipTypes.change_type(type, starting_attrs(type)))}
    end
  end

  defp load_type(:new, _params), do: %RelationshipType{}
  defp load_type(:edit, %{"uuid" => uuid}), do: RelationshipTypes.get_type(uuid)

  defp starting_attrs(%RelationshipType{uuid: nil}), do: @acting
  defp starting_attrs(_type), do: %{}

  defp page_title(:new), do: gettext("New relationship type")
  defp page_title(:edit), do: gettext("Edit relationship type")

  defp index_path, do: Routes.path("/admin/users/relationship-types")

  defp assign_changeset(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :relationship_type))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"relationship_type" => params}, socket) do
    {params, derived?} = prepare(params, socket)

    changeset =
      socket.assigns.type
      |> RelationshipTypes.change_type(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:derived_key, derived? && Ecto.Changeset.get_field(changeset, :key))
     |> assign_changeset(changeset)}
  end

  def handle_event("save", %{"relationship_type" => params}, socket) do
    {params, _derived?} = prepare(params, socket)
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Folds the language tabs into `data`. On create a key the form merely echoes back
  # (blank, or the one derived last time) counts as not given, so the next name edit
  # derives a fresh one. On edit nothing fixed at creation is taken from the form.
  defp prepare(params, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    if socket.assigns.live_action == :new do
      params = Map.merge(params, @acting)

      if params["key"] in [nil, "", socket.assigns.derived_key],
        do: {Map.delete(params, "key"), true},
        else: {params, false}
    else
      {Map.drop(params, ["key", "can_manage"]), false}
    end
  end

  defp save(socket, :new, params) do
    finish(socket, RelationshipTypes.create_type(params, actor(socket)), gettext("Type created"))
  end

  defp save(socket, :edit, params) do
    finish(
      socket,
      RelationshipTypes.update_type(socket.assigns.type, params, actor(socket)),
      gettext("Type updated")
    )
  end

  defp finish(socket, {:ok, _type}, message) do
    {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: index_path())}
  end

  defp finish(socket, {:error, %Ecto.Changeset{} = changeset}, _message) do
    {:noreply, assign_changeset(socket, Map.put(changeset, :action, :validate))}
  end

  defp actor(socket), do: [actor_uuid: Actor.uuid(socket)]

  # A new form has no key yet, which is not an error until someone tries.
  defp key_error?(%{action: nil}), do: false
  defp key_error?(changeset), do: Keyword.has_key?(changeset.errors, :key)

  defp can_manage?(changeset), do: Ecto.Changeset.get_field(changeset, :can_manage) == true

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )
      |> assign(:new?, assigns.live_action == :new)

    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
      page_section={@page_section}
      page_section_path={@page_section_path}
      page_crumbs={@page_crumbs}
      current_path={index_path()}
    >
      <div class="max-w-2xl mx-auto px-4 py-6">
        <.form for={@form} id="relationship-type-form" phx-change="validate" phx-submit="save">
          <div class="card bg-base-100 shadow-sm">
            <.multilang_tabs
              multilang_enabled={@multilang_enabled}
              language_tabs={@language_tabs}
              current_lang={@current_lang}
              class="card-body pb-0 pt-4"
            />

            <.multilang_fields_wrapper
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              skeleton_class="card-body pt-0"
            >
              <div class="card-body pb-0 flex flex-col gap-5">
                <.translatable_field
                  field_name="name"
                  form_prefix="relationship_type"
                  changeset={@changeset}
                  schema_field={:name}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={@lang_data}
                  label={gettext("Name")}
                  placeholder={gettext("For example: Warehouse staff")}
                  required={not @type.builtin}
                  class="w-full"
                />
                <.translatable_field
                  field_name="inverse_name"
                  form_prefix="relationship_type"
                  changeset={@changeset}
                  schema_field={:inverse_name}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={@lang_data}
                  label={gettext("Name for several people")}
                  placeholder={gettext("Optional. For example: Warehouse team")}
                  class="w-full"
                />
              </div>
            </.multilang_fields_wrapper>

            <div class="card-body flex flex-col gap-5">
              <fieldset :if={@new?}>
                <legend class="font-semibold mb-2">
                  {gettext("What can people of this type do?")}
                </legend>
                <label class="flex items-start gap-3 py-1 cursor-pointer">
                  <input
                    type="radio"
                    name="relationship_type[can_manage]"
                    value="false"
                    class="radio radio-sm mt-0.5"
                    checked={not can_manage?(@changeset)}
                  />
                  <span>
                    <span class="block">{gettext("Act for an organization")}</span>
                    <span class="block text-sm text-base-content/70">
                      {gettext("They use the roles on their link, and nothing more.")}
                    </span>
                  </span>
                </label>
                <label class="flex items-start gap-3 py-1 cursor-pointer">
                  <input
                    type="radio"
                    name="relationship_type[can_manage]"
                    value="true"
                    class="radio radio-sm mt-0.5"
                    checked={can_manage?(@changeset)}
                  />
                  <span>
                    <span class="block">{gettext("Act for it and manage it")}</span>
                    <span class="block text-sm text-base-content/70">
                      {gettext("They can also invite and remove people and edit its profile.")}
                    </span>
                  </span>
                </label>
                <p class="text-sm text-base-content/70 mt-2">
                  {gettext("This can't be changed later. To change it, make a new type.")}
                </p>
              </fieldset>

              <div :if={not @new?}>
                <div class="font-semibold mb-1">{gettext("What people of this type can do")}</div>
                <p :if={@type.can_manage}>
                  {gettext("Act for an organization and manage its people and profile.")}
                </p>
                <p :if={not @type.can_manage}>
                  {gettext("Act for an organization, but not manage it.")}
                </p>
                <p class="text-sm text-base-content/70 mt-1">
                  {gettext("This can't be changed. To change it, make a new type.")}
                </p>
              </div>

              <details :if={@new?} open={key_error?(@changeset)}>
                <summary class="cursor-pointer text-sm text-base-content/70">
                  {gettext("Technical key")}
                </summary>
                <div class="mt-3">
                  <.input
                    field={@form[:key]}
                    label={gettext("Key")}
                    maxlength={RelationshipType.key_max()}
                    class="font-mono"
                  />
                  <p class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "Used by code, and never shown to people. It is made from the name and can't be changed later."
                    )}
                  </p>
                </div>
              </details>

              <div class="flex justify-end gap-2">
                <.pk_link_button navigate="/admin/users/relationship-types" variant="ghost">
                  {gettext("Cancel")}
                </.pk_link_button>
                <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
              </div>
            </div>
          </div>
        </.form>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
