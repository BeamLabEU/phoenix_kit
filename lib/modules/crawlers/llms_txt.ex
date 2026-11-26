defmodule PhoenixKit.Modules.Crawlers.LlmsTxt do
  @moduledoc """
  Builds the `/llms.txt` document — a markdown summary telling AI assistants
  what this site is about ([llmstxt.org](https://llmstxt.org/)).

  Where `robots.txt` is about *keeping bots out*, `llms.txt` is the opposite
  half of bot policy: making the site legible to the AI tools the operator
  *wants* reading it. The generated document is:

      # <project title>

      <operator-provided extra markdown, verbatim>

  The head is generated from Settings so a fresh install serves something
  truthful with zero configuration; the tail is the operator's, edited on the
  Crawlers settings page and stored as a setting. There is deliberately no
  generated `> summary` blockquote — llmstxt.org allows one, but core has no
  setting that says what the site *is*, and a fabricated line is worse than
  none. Serving happens in
  `PhoenixKit.Modules.Crawlers.Web.Controller`, at the site root and under the
  kit prefix — the root is where tools look, same reasoning as `/sitemap.xml`.

  ## Sections from the host application

  A host can append sections of its own, built at request time:

      config :phoenix_kit, llms_txt_sections: {MyApp.LlmsTxt, :sections}

  The function is called with `%{base_url: origin, locale: code, host: host}`:
  `base_url` is the site origin (never taken from an unknown `Host` header, see
  `PhoenixKit.API.PublicDiscovery.origin/1`), `host` its host, and `locale` an
  enabled language code: the request's `?lang=` when that language is enabled,
  else the site's primary language. It returns markdown (a binary) or a list of
  `%{title: title, body: markdown}` maps, each rendered as `## title` and the
  body. The sections come after the operator's text and before the API section.

  The call runs in its own process with a deadline
  (`config :phoenix_kit, llms_txt_sections_timeout: 2_000`, in milliseconds); a
  raise, a throw, an exit, a timeout or a return of another shape is logged (the
  exception's module only) and the file is served without the sections. A good
  answer is cached per `{host, locale}` for five minutes
  (`config :phoenix_kit, llms_txt_sections_ttl:`, milliseconds), a failure is not.
  With the option unset (the default) nothing is called and the file is exactly
  as before.
  """

  require Logger

  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.Cache
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Settings

  @cache :llms_txt_sections
  @default_timeout 2_000

  @typedoc "What `llms_txt_sections` is called with."
  @type context :: %{base_url: String.t(), locale: String.t(), host: String.t()}

  @doc """
  Build the llms.txt contents from current settings.

  `:host_sections` is markdown from the host's `llms_txt_sections` callback
  (`host_sections/1`), appended after the operator's text; `:api_section` is
  the section about the public API
  (`PhoenixKit.API.PublicDiscovery.llms_section/1`), appended last. `nil` (the
  default for both) appends nothing.
  """
  @spec build(keyword()) :: String.t()
  def build(opts \\ []) do
    build_for(Settings.get_project_title(), Crawlers.llms_txt_extra())
    |> append(Keyword.get(opts, :host_sections))
    |> append(Keyword.get(opts, :api_section))
  end

  defp append(base, section) when is_binary(section) and section != "",
    do: base <> "\n" <> section

  defp append(base, _none), do: base

  @doc """
  The host's sections for `context`, as markdown ending in a newline, or `nil`
  when `llms_txt_sections` is unset or its call failed (see the moduledoc).
  """
  @spec host_sections(context()) :: String.t() | nil
  def host_sections(%{host: host, locale: locale} = context) do
    case Application.get_env(:phoenix_kit, :llms_txt_sections) do
      {module, function} when is_atom(module) and is_atom(function) ->
        result =
          Cache.remember(@cache, {host, locale}, fn -> load(module, function, context) end,
            until: ttl()
          )

        if is_binary(result), do: result, else: nil

      nil ->
        nil

      other ->
        Logger.warning(
          "[PhoenixKit] llms_txt_sections must be {module, function}, got #{inspect(other)}; ignored"
        )

        nil
    end
  end

  defp ttl, do: Application.get_env(:phoenix_kit, :llms_txt_sections_ttl, :timer.minutes(5))

  defp timeout,
    do: Application.get_env(:phoenix_kit, :llms_txt_sections_timeout, @default_timeout)

  # `{:error, _}` is returned to the caller and never cached (`Cache.remember/4`).
  defp load(module, function, context) do
    module
    |> run_callback(function, context)
    |> render_outcome(module, function)
  end

  # A process of its own, monitored and not linked: a callback that kills its process must not
  # take the request with it, and one that hangs is killed at the deadline. `$callers` is set
  # as `Task` sets it, so the callback reaches the database the request may use.
  defp run_callback(module, function, context) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(parent, {ref, call(module, function, context)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:caught, :exit}
    after
      timeout() ->
        Process.exit(pid, :kill)

        # Wait for the `:DOWN`: a reply the callback sent before it was killed reaches this
        # mailbox before that message, so the drain below finds it. Without the wait a late
        # reply could land after the drain and stay in a request process that keep-alive
        # reuses for the next request.
        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  defp call(module, function, context) do
    {:ok, apply(module, function, [context])}
  rescue
    error -> {:raised, error}
  catch
    kind, _reason -> {:caught, kind}
  end

  defp render_outcome({:ok, result}, module, function) do
    case render_sections(result) do
      {:ok, markdown} -> markdown
      :error -> failed(module, function, "returned " <> LogSafe.shape(result))
    end
  end

  defp render_outcome({:raised, error}, module, function),
    do: failed(module, function, "raised " <> LogSafe.exception_label(error))

  defp render_outcome({:caught, kind}, module, function),
    do: failed(module, function, "failed (#{kind})")

  defp render_outcome(:timeout, module, function),
    do: failed(module, function, "did not answer within #{timeout()} ms")

  defp failed(module, function, what) do
    Logger.warning(
      "[PhoenixKit] llms.txt: #{inspect(module)}.#{function}/1 #{what}; served without its sections"
    )

    {:error, :llms_txt_sections}
  end

  @doc false
  # Public for its tests: the callback's answer as markdown.
  @spec render_sections(term()) :: {:ok, String.t()} | :error
  def render_sections(markdown) when is_binary(markdown) do
    case String.valid?(markdown) and String.trim(markdown) do
      false -> :error
      "" -> {:ok, ""}
      trimmed -> {:ok, trimmed <> "\n"}
    end
  end

  def render_sections(sections) when is_list(sections) do
    if Enum.all?(sections, &section?/1) do
      {:ok,
       sections
       |> Enum.map(&render_section/1)
       |> Enum.reject(&(&1 == ""))
       |> Enum.join("\n")}
    else
      :error
    end
  end

  def render_sections(_other), do: :error

  defp section?(%{title: title, body: body}) when is_binary(title) and is_binary(body),
    do: String.valid?(title) and String.valid?(body)

  defp section?(_other), do: false

  defp render_section(%{title: title, body: body}) do
    title = title |> String.replace(~r/\s+/, " ") |> String.trim()
    body = String.trim(body)

    case {title, body} do
      {"", ""} -> ""
      {"", body} -> body <> "\n"
      {title, ""} -> "## #{title}\n"
      {title, body} -> "## #{title}\n\n#{body}\n"
    end
  end

  @doc """
  Pure variant used by tests: build from explicit title and extra markdown.
  """
  @spec build_for(String.t() | nil, String.t() | nil) :: String.t()
  def build_for(title, extra) do
    title = presence(title) || "This site"
    extra = String.trim(extra || "")

    head = "# #{title}\n"

    tail =
      case extra do
        "" -> ""
        markdown -> "\n" <> markdown <> "\n"
      end

    head <> tail
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
