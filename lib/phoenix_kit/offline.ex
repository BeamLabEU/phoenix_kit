defmodule PhoenixKit.Offline do
  @moduledoc """
  Annotating with no connection (Etcher's offline mode), for the media viewer
  and anything else that draws through Etcher (`phoenix_kit_boards`).

  Off by default; a host turns it on with

      config :phoenix_kit, offline_annotations: true

  On, a file annotated once online is kept on the device: a service worker
  (Etcher's `etcher-offline-sw.js`, served by core at `worker_url/0`) keeps
  the page and the files it loaded, every save is also kept in the browser,
  and opened with no connection the viewer starts from this device's copy.
  When the connection is back the page reloads and sends what was done,
  merged shape by shape with whatever changed on the server meanwhile. A
  shape with a comment thread is never deleted by an offline device.

  The worker answers only for the pages and files a viewer asked it to keep;
  everything else goes to the network untouched. It needs a secure page
  (https, or localhost).
  """

  alias PhoenixKit.Utils.Routes

  @doc """
  Whether offline annotating is on. Only a literal `true` turns it on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:phoenix_kit, :offline_annotations, false) == true

  @doc """
  Where core serves Etcher's offline service worker.

  The same on every page, whatever the language: a site has one worker, and
  registering it under a second URL replaces the first registration.
  """
  @spec worker_url() :: String.t()
  def worker_url, do: Routes.path("/assets/etcher-offline-sw.js", locale: :none)
end
