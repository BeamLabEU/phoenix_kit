defmodule PhoenixKitWeb.Controllers.Redirects.PublishingRedirectController do
  @moduledoc """
  Handles redirects from legacy /admin/blogging/* routes to new /admin/publishing/* routes.

  This controller ensures backward compatibility for bookmarked URLs and external links
  while the module is being renamed from "blogging" to "publishing".

  All redirects use 301 (Moved Permanently) status to inform browsers and search engines
  that the new URLs are the canonical locations.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Utils.Routes

  @doc """
  Redirects /admin/blogging to /admin/publishing
  """
  def index(conn, params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/publishing", locale)
  end

  @doc """
  Redirects /admin/blogging/:blog to /admin/publishing/:blog
  """
  def blog(conn, %{"blog" => blog} = params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/publishing/#{blog}", locale)
  end

  @doc """
  Redirects /admin/blogging/:blog/edit to /admin/publishing/:blog/edit
  """
  def edit(conn, %{"blog" => blog} = params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/publishing/#{blog}/edit", locale)
  end

  @doc """
  Redirects /admin/blogging/:blog/preview to /admin/publishing/:blog/preview
  """
  def preview(conn, %{"blog" => blog} = params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/publishing/#{blog}/preview", locale)
  end

  @doc """
  Redirects /admin/settings/blogging to /admin/settings/publishing
  """
  def settings(conn, params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/settings/publishing", locale)
  end

  @doc """
  Redirects /admin/settings/blogging/new to /admin/settings/publishing/new
  """
  def new(conn, params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/settings/publishing/new", locale)
  end

  @doc """
  Redirects /admin/settings/blogging/:blog/edit to /admin/settings/publishing/:blog/edit
  """
  def settings_edit(conn, %{"blog" => blog} = params) do
    locale = Map.get(params, "locale")
    redirect_to(conn, "/admin/settings/publishing/#{blog}/edit", locale)
  end

  defp redirect_to(conn, path, locale) do
    full_path = Routes.path(path, locale: locale)

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: full_path)
  end
end
