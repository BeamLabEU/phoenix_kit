defmodule PhoenixKitWeb.Live.Modules.Storage.CDNSourceComponent do
  @moduledoc "Bucket selection and origin guidance inside a CDN connection form."
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitWeb.Gettext
  alias PhoenixKit.Modules.Storage.CDNSource

  @impl true
  def update(assigns, socket) do
    sources = CDNSource.choices(assigns.owner)
    selected = Enum.find(sources, &(&1.uuid == assigns.bucket_uuid))
    state = {assigns.uuid, assigns.bucket_uuid, assigns.origin}

    socket =
      if socket.assigns[:saved_state] == state do
        socket
      else
        assign(socket,
          selected: selected,
          draft_origin: assigns.origin || (selected && selected.origin),
          saved_state: state,
          result: nil
        )
      end

    {:ok, socket |> assign(assigns) |> assign(:sources, sources)}
  end

  @impl true
  def handle_event("source", %{"source_bucket_uuid" => id}, socket) do
    selected = Enum.find(socket.assigns.sources, &(&1.uuid == id))

    {:noreply,
     assign(socket, selected: selected, draft_origin: selected && selected.origin, result: nil)}
  end

  def handle_event("verify", _, socket) do
    %{uuid: uuid, owner: owner} = socket.assigns

    {:noreply,
     socket
     |> assign(:result, gettext("Checking the saved mapping…"))
     |> start_async(:probe, fn -> CDNSource.verify(uuid, owner) end)}
  end

  @impl true
  def handle_async(:probe, {:ok, result}, socket) do
    message =
      case result do
        :ok ->
          gettext(
            "Verified. The CDN served the test file and stopped serving it after deletion and purge."
          )

        {:error, :test_object_unreadable} ->
          gettext(
            "The CDN could not read the test file. Check the origin folder and its read permissions."
          )

        {:error, :withdrawal_failed} ->
          gettext(
            "The file was delivered, but withdrawal could not be confirmed. Check purge access."
          )

        {:error, :cache_miss} ->
          gettext(
            "The CDN fetched the file, but a second request missed the cache. Check the cache settings."
          )

        {:error, :origin_mismatch} ->
          gettext(
            "The CDN origin differs from the saved Origin URL. Check both the hostname and the folder."
          )

        {:error, reason} when is_binary(reason) ->
          gettext("The storage or CDN request failed. Check the origin and read permissions.")

        {:error, reason} ->
          gettext("Source check failed (%{reason}).", reason: reason)
      end

    {:noreply, assign(socket, :result, message)}
  end

  def handle_async(:probe, {:exit, _}, socket),
    do: {:noreply, assign(socket, :result, gettext("Could not finish the source check."))}

  @impl true
  def render(assigns) do
    ~H"""
    <fieldset id={@id} class="fieldset space-y-2">
      <legend class="fieldset-legend">{gettext("Delivery source")}</legend>
      <label>
        {gettext("Storage bucket")}
        <select
          class="select w-full"
          name="source_bucket_uuid"
          phx-change="source"
          phx-target={@myself}
        >
          <option value="">{gettext("No bucket mapped")}</option>
          <option
            :for={source <- @sources}
            value={source.uuid}
            selected={@selected && source.uuid == @selected.uuid}
          >
            {source.name} ({source.provider})
          </option>
        </select>
      </label>
      <label :if={@selected} for={@id <> "-origin-" <> @selected.uuid}>{gettext(
        "Origin URL for this bucket"
      )}</label>
      <input
        :if={@selected}
        id={@id <> "-origin-" <> @selected.uuid}
        type="url"
        name="source_origin"
        required
        class="input w-full font-mono"
        value={@draft_origin}
      />
      <button
        :if={@selected}
        type="button"
        id={@id <> "-copy"}
        phx-hook="CopyToClipboard"
        data-copy-target={"#" <> @id <> "-origin-" <> @selected.uuid}
        class="btn btn-sm btn-outline"
      >
        <span data-copy-idle>{gettext("Copy")}</span><span data-copy-feedback class="hidden">{gettext(
          "Copied!"
        )}</span>
      </button>
      <p :if={@selected && @adapter == PhoenixKit.Integrations.BunnyCDN}>
        {gettext(
          "Point the Bunny pull zone at an HTTPS address serving the cdn-pilot/ folder of this bucket. Save the connection, then verify it with a temporary test file."
        )}
      </p>
      <div :if={
        @selected && @adapter == PhoenixKit.Integrations.BunnyCDN && @selected.provider != "local"
      }>
        <p>
          {gettext(
            "For a private S3 origin, open the pull zone in Bunny and go to Security → S3 Authentication. Turn on Enable AWS S3 Authentication. Enter the access key ID and secret from your storage provider and the bucket’s signing region. Use a dedicated key with read access limited to the delivery folder."
          )}
        </p>
        <p :if={@selected.region not in [nil, ""]}>
          {gettext("Configured bucket region: %{region}", region: @selected.region)}
        </p>
      </div>
      <p :if={@selected && @selected.provider == "local"}>
        {gettext(
          "Configure your web server to serve that folder over HTTPS. Keep the rest of the local storage directory private."
        )}
      </p>
      <button
        :if={@adapter && @uuid && @selected && @selected.uuid == @persisted_bucket}
        type="button"
        phx-click="verify"
        phx-target={@myself}
        class="btn btn-outline btn-sm"
      >
        {gettext("Verify saved bucket mapping")}
      </button>
      <p :if={@checked_at && !@result}>{gettext("Last verified: %{time}", time: @checked_at)}</p>
      <p :if={@result} role="status">{@result}</p>
    </fieldset>
    """
  end
end
