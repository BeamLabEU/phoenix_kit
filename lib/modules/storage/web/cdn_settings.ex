defmodule PhoenixKitWeb.Live.Modules.Storage.CDNSettings do
  @moduledoc "Site CDN connection and rendition defaults for Media settings."
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitWeb.Gettext
  alias PhoenixKit.Modules.Storage.{CDN, VariantSets}

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(:notice, nil) |> load()}
  end

  defp load(socket) do
    profiles =
      for set <- VariantSets.list_variant_sets(),
          do: %{set: set, rows: CDN.rows(set.uuid), selected: CDN.site_renditions(set.uuid)}

    assign(socket,
      profiles: profiles,
      connections: CDN.connections(:system),
      current: CDN.site_connection()
    )
  end

  @impl true
  def handle_event("connection", %{"connection" => id}, socket),
    do: saved(socket, CDN.save_site(socket.assigns.scope, id))

  def handle_event("renditions", %{"profile" => id} = params, socket),
    do: saved(socket, CDN.save_site_renditions(socket.assigns.scope, id, params["public"] || []))

  defp saved(socket, result) do
    notice =
      if match?({:ok, _}, result),
        do: gettext("Saved"),
        else: gettext("Could not save CDN preferences")

    {:noreply, socket |> load() |> assign(:notice, notice)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="card bg-base-100 shadow mt-6">
      <div class="card-body">
        <form id="site-cdn-connection" phx-submit="connection" phx-target={@myself}>
          <label class="fieldset">
            <span>{gettext("Default CDN connection")}</span>
            <select name="connection" class="select">
              <option value="off" selected={@current == "off"}>{gettext("Off")}</option>
              <option
                :if={@current != "off" and not List.keymember?(@connections, @current, 0)}
                value={@current}
                selected
                disabled
              >
                {gettext("Unavailable")}
              </option>
              <option :for={{id, name} <- @connections} value={id} selected={id == @current}>
                {name}
              </option>
            </select>
          </label>
          <button class="btn btn-primary btn-sm mt-2">{gettext("Save")}</button>
        </form>
        <p>
          {gettext("Delivery currently uses library storage.")}
        </p>
        <form
          :for={profile <- @profiles}
          id={"cdn-profile-#{profile.set.uuid}"}
          phx-submit="renditions"
          phx-target={@myself}
        >
          <h3 class="font-semibold">{profile.set.name}</h3>
          <input type="hidden" name="profile" value={profile.set.uuid} />
          <.matrix rows={profile.rows} selected={profile.selected} disabled={false} />
          <button class="btn btn-sm">{gettext("Save")}</button>
        </form>
        <p role="status">{@notice}</p>
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :selected, :list, required: true
  attr :disabled, :boolean, required: true

  def matrix(assigns) do
    ~H"""
    <table class="table">
      <thead>
        <tr>
          <th>{gettext("Rendition")}</th><th>{gettext("Public")}</th>
          <th>{gettext("Signed-in only")}</th><th>{gettext("Private")}</th>
        </tr>
      </thead><tbody>
        <tr :for={{id, name} <- @rows}>
          <th scope="row">{name}</th>
          <td>
            <input
              class="checkbox"
              aria-label={"#{name} · #{gettext("Public")}"}
              type="checkbox"
              name="public[]"
              value={id}
              checked={id in @selected}
              disabled={@disabled}
            />
          </td>
          <td :for={audience <- [gettext("Signed-in only"), gettext("Private")]}>
            <input
              class="checkbox"
              aria-label={"#{name} · #{audience}"}
              type="checkbox"
              disabled
              title={gettext("Requires access checks at the CDN")}
            />
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end
