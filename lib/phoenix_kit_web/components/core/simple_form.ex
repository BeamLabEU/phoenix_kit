defmodule PhoenixKitWeb.Components.Core.SimpleForm do
  @moduledoc """
  Provides a simple form UI component.
  """

  use Phoenix.Component

  alias PhoenixKitWeb.Components.Core.FormDraft

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-submit="save">
        <.input field={@form[:email]} type="email" label="Email"/>
        <.input field={@form[:password]} type="password" label="Password" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>

  With `draft`, what is typed is kept in the browser and offered back on
  return ("Restore your unsaved draft?"); the form then needs an `id`. Pass
  options as a keyword list (`draft={[exclude: ["slug"], storage: :session]}`);
  see `PhoenixKitWeb.Components.Core.FormDraft`.

      <.simple_form for={@form} id="post-form" phx-submit="save" draft>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  attr :draft, :any,
    default: false,
    doc: "keep a draft in the browser: `true` or `FormDraft.attrs/1` options (needs `id`)"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    assigns = assign(assigns, :draft_attrs, draft_attrs(assigns.draft, assigns.rest))

    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest} {@draft_attrs}>
      <div class="mt-10 space-y-8 bg-base-100">
        <FormDraft.form_draft_bar :if={@draft_attrs != %{}} for={@rest[:id]} class="" />
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  defp draft_attrs(draft, _rest) when draft in [nil, false], do: %{}

  defp draft_attrs(draft, rest) do
    unless is_binary(rest[:id]) and rest[:id] != "" do
      raise ArgumentError, "<.simple_form draft> needs an id"
    end

    FormDraft.attrs(if is_list(draft), do: draft, else: [])
  end
end
