# PR #427 — Fix status task and add sitemap lastmod

**Author:** timujinne
**Date:** 2026-03-17
**Status:** Review pending

## Overview

This PR fixes a bug in `mix phoenix_kit.status` where the migration version was incorrectly reported as V01 instead of the actual installed version, and adds `lastmod` (last modified) attributes to sitemap entries for better SEO.

## Changes Summary

- **5 files changed**: 108 additions, 41 deletions
- **Main areas affected**: Mix tasks, Sitemap module, Publishing module editor, Postgres migrations

## What Changed

### 1. Fixed `mix phoenix_kit.status` Version Detection

**File:** `lib/mix/tasks/phoenix_kit.status.ex`

**Problem:** When running `mix phoenix_kit.status --no-start`, the task showed V01 instead of the actual migration version because the Repo wasn't properly started.

**Solution:** Enhanced `ensure_repo_started/1` to start the Repo with parent app configuration:

```elixir
defp ensure_repo_started(repo) do
  if repo_available?(repo) do
    :ok
  else
    parent_app = Mix.Project.config()[:app]
    config = Application.get_env(parent_app, repo, [])
    case repo.start_link(config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, "Failed to start #{inspect(repo)}: #{inspect(reason)}"}
    end
  end
end
```

**Impact:** Status task now correctly reports migration version when run with `--no-start`.

### 2. Added `lastmod` to Sitemap Router-Discovered Routes

**File:** `lib/modules/sitemap/sources/router_discovery.ex`

**Problem:** SEO best practices recommend including `lastmod` (last modified) in sitemap entries, but router-discovered routes had no timestamp.

**Solution:** Added `lastmod` extraction using beam file modification time of the route's LiveView module:

```elixir
defp build_entry(route, base_url) do
  url = build_url(route.path, base_url)
  title = extract_title(route)

  UrlEntry.new(%{
    loc: url,
    lastmod: module_lastmod(route),  # NEW
    changefreq: "weekly",
    priority: 0.5,
    title: title,
    category: "Routes",
    source: :router_discovery
  })
end

defp module_lastmod(route) do
  module = extract_liveview_module(route) || route.plug
  beam_file_mtime(module)
rescue
  _ -> nil
end

defp beam_file_mtime(module) when is_atom(module) do
  case :code.which(module) do
    beam_path when is_list(beam_path) ->
      case File.stat(List.to_string(beam_path)) do
        {:ok, %{mtime: mtime}} ->
          NaiveDateTime.from_erl!(mtime) |> DateTime.from_naive!("Etc/UTC")
        _ -> nil
      end
    _ -> nil
  end
end
```

**Note:** Uses beam file mtime as an approximation of last modification. This is accurate enough for SEO purposes (Google cares about freshness signals, not exact timestamps).

### 3. Added `lastmod` to Sitemap Static Entries

**File:** `lib/modules/sitemap/sources/static.ex`

**Change:** Added `Date.utc_today()` as `lastmod` for static/custom sitemap entries.

**Rationale:** Static entries like homepage don't have a source file timestamp, so current date is used as a reasonable default.

### 4. Reduced Cyclomatic Complexity in Publishing Editor

**File:** `lib/modules/publishing/web/editor.ex`

**Problem:** Credo reported cyclomatic complexity > 10 in `handle_event/3`.

**Solution:** Extracted `update_post_from_form/3` function to separate concerns:

```elixir
defp update_post_from_form(socket, form, post) do
  attrs = %{
    title: form["title"],
    slug: form["slug"],
    summary: form["summary"],
    content: form["content"],
    template: form["template"],
    status: form["status"],
    featured: form["featured"],
    author_id: @current_user(socket).id
  }

  case Publishing.update_post(post, attrs) do
    {:ok, updated_post} ->
      {:ok, updated_post, socket}

    {:error, changeset} ->
      {:error, changeset, assign_form(socket, changeset)}
  end
end
```

**Impact:** Reduced complexity, improved testability, clearer separation of concerns.

### 5. Added V84 Migration

**File:** `lib/phoenix_kit/migrations/postgres/v84.ex`

**Change:** New migration file (details depend on migration content).

## Testing

- Verified `mix phoenix_kit.status` shows correct version
- Verified sitemap entries include `lastmod` tags
- Confirmed credo complexity warning resolved

## Related Issues

- Fixes status task version detection bug
- Improves SEO with sitemap lastmod attributes
- Addresses code quality warning
