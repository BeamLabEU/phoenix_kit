defmodule PhoenixKitWeb.Components.Blogging.EntityForm do
  @moduledoc """
  Embeddable entity form component for blogging pages.
  Renders a public submission form based on entity configuration.

  ## Usage in .phk files

      <EntityForm entity_slug="contact" />

  ## Attributes

  - `entity_slug` (required) - The slug/name of the entity to render form for
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.FormBuilder

  attr :content, :string, default: nil
  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"

  def render(assigns) do
    entity_slug = Map.get(assigns.attributes, "entity_slug", "")

    # Load entity and check if public form is enabled
    entity = if entity_slug != "", do: Entities.get_entity_by_name(entity_slug), else: nil

    {form_enabled, form_fields, form_title, form_description, form_submit_text} =
      if entity do
        settings = entity.settings || %{}
        enabled = Map.get(settings, "public_form_enabled", false)
        fields = Map.get(settings, "public_form_fields", [])
        title = Map.get(settings, "public_form_title", "")
        description = Map.get(settings, "public_form_description", "")
        submit_text = Map.get(settings, "public_form_submit_text", gettext("Submit"))
        {enabled, fields, title, description, submit_text}
      else
        {false, [], "", "", gettext("Submit")}
      end

    # Create a form entity with only the public form fields
    form_entity =
      if entity && form_enabled do
        fields_definition = entity.fields_definition || []

        public_fields =
          Enum.filter(fields_definition, fn field ->
            field["key"] in form_fields
          end)

        %{entity | fields_definition: public_fields}
      else
        nil
      end

    assigns =
      assigns
      |> assign(:entity_slug, entity_slug)
      |> assign(:entity, entity)
      |> assign(:form_entity, form_entity)
      |> assign(:form_enabled, form_enabled)
      |> assign(:form_title, form_title)
      |> assign(:form_description, form_description)
      |> assign(:form_submit_text, form_submit_text)

    ~H"""
    <div class="entity-form-wrapper">
      <%= cond do %>
        <% @entity_slug == "" -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center py-8">
              <div class="text-4xl mb-3">⚠️</div>
              <p class="text-base-content/70">{gettext("Form configuration error.")}</p>
            </div>
          </div>
        <% is_nil(@entity) -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center py-8">
              <div class="text-4xl mb-3">⚠️</div>
              <p class="text-base-content/70">{gettext("Form configuration error.")}</p>
            </div>
          </div>
        <% !@form_enabled -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center py-8">
              <div class="text-4xl mb-3">📝</div>
              <p class="text-base-content/70">{gettext("This form is currently unavailable.")}</p>
            </div>
          </div>
        <% true -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <%= if @form_title != "" do %>
                <h2 class="card-title text-2xl mb-2">{@form_title}</h2>
              <% end %>
              <%= if @form_description != "" do %>
                <p class="text-base-content/70 mb-4">{@form_description}</p>
              <% end %>

              <form
                action={PhoenixKit.Utils.Routes.path("/entities/#{@entity_slug}/submit")}
                method="post"
              >
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

                {FormBuilder.build_fields(@form_entity, build_empty_changeset(@entity),
                  wrapper_class: "mb-4"
                )}

                <div class="form-control mt-6">
                  <button type="submit" class="btn btn-primary">
                    {@form_submit_text}
                  </button>
                </div>
              </form>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp build_empty_changeset(entity) do
    # Create an empty EntityData changeset for the form
    alias PhoenixKit.Entities.EntityData

    %EntityData{entity_id: entity.id, data: %{}}
    |> EntityData.change()
  end
end
