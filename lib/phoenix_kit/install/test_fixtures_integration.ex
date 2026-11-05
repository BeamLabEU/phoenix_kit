defmodule PhoenixKit.Install.TestFixturesIntegration do
  use PhoenixKit.Install.IgniterCompat

  @moduledoc """
  Puts `import PhoenixKit.Test.Fixtures` into the host's `ConnCase`, so its
  tests can call `register_and_log_in_user/1` and the other helpers instead of
  repeating `register_user` + `generate_user_session_token` +
  `init_test_session` by hand in every file.

  Conservative on purpose. An import that collides with a function the host
  already defines is a compile error at every call site, so the import is
  added only when nothing under `test/` defines a function with one of the
  fixture names (phx.gen.auth's `ConnCase` defines `register_and_log_in_user/1`
  and `log_in_user/2`, for one). Otherwise, and whenever the `ConnCase` is not
  the shape phx.new generates, the installer prints a notice and leaves the
  file alone.

  Idempotent. Called from both `mix phoenix_kit.install` and
  `mix phoenix_kit.update`.
  """

  @conn_case_path "test/support/conn_case.ex"
  @import_line "import PhoenixKit.Test.Fixtures"

  # Every public function of `PhoenixKit.Test.Fixtures`. A host definition of
  # any of these would clash with the import.
  @fixture_names ~w(user_fixture confirmed_user_fixture register_and_log_in_user
                    log_in_user scope_for admin_fixture unique_user_email
                    valid_user_password)

  # phx.new's ConnCase imports these inside `using do quote do … end end`;
  # the fixture import goes right after the first one found.
  @anchor ~r/^([ \t]*)import Phoenix\.ConnTest[ \t]*$/m

  @doc "Adds the fixtures import to the host's ConnCase when it is safe to."
  def ensure_conn_case_import(igniter) do
    if File.exists?(@conn_case_path) do
      content = File.read!(@conn_case_path)

      case conn_case_plan(content, test_sources()) do
        :already_present ->
          igniter

        {:conflict, name} ->
          Igniter.add_notice(igniter, conflict_notice(name))

        :inject ->
          File.write!(@conn_case_path, inject_import(content))

          Igniter.add_notice(
            igniter,
            "✅ Added `#{@import_line}` to #{@conn_case_path}. " <>
              "Tests can now call register_and_log_in_user/1."
          )

        :no_anchor ->
          Igniter.add_notice(igniter, manual_notice())
      end
    else
      igniter
    end
  end

  @doc """
  What to do with a ConnCase, given its content and the content of every other
  test source. Public so the rules can be asserted without a host on disk.

    * `:already_present` — the ConnCase (or anything it pulls in) already
      mentions `PhoenixKit.Test.Fixtures`.
    * `{:conflict, name}` — a test source defines a function the import would
      clash with.
    * `:inject` — safe, and the phx.new anchor line is there.
    * `:no_anchor` — safe, but the file is not the shape phx.new generates.
  """
  @spec conn_case_plan(String.t(), [String.t()]) ::
          :already_present | {:conflict, String.t()} | :inject | :no_anchor
  def conn_case_plan(content, other_sources \\ []) do
    cond do
      String.contains?(content, "PhoenixKit.Test.Fixtures") -> :already_present
      name = defined_fixture_name([content | other_sources]) -> {:conflict, name}
      Regex.match?(@anchor, content) -> :inject
      true -> :no_anchor
    end
  end

  @doc "The ConnCase with the import added after `import Phoenix.ConnTest`."
  @spec inject_import(String.t()) :: String.t()
  def inject_import(content) do
    Regex.replace(@anchor, content, "\\0\n\\1#{@import_line}", global: false)
  end

  defp defined_fixture_name(sources) do
    Enum.find_value(sources, fn source ->
      Enum.find(@fixture_names, fn name ->
        Regex.match?(~r/^\s*defp?\s+#{name}\b/m, source)
      end)
    end)
  end

  defp test_sources do
    "test/**/*.{ex,exs}"
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @conn_case_path))
    |> Enum.map(&File.read!/1)
  end

  defp conflict_notice(name) do
    """
    ℹ️  Did not add `#{@import_line}` to #{@conn_case_path}: your tests already
    define `#{name}`, and the import would clash with it. The kit's helpers
    (register_and_log_in_user/1, log_in_user/2, user_fixture/1, …) are there
    whenever you want them; see PhoenixKit.Test.Fixtures.
    """
  end

  defp manual_notice do
    """
    ℹ️  PhoenixKit ships test helpers. Add this inside the `quote` block of
    #{@conn_case_path} to use them:

        #{@import_line}

    Then `register_and_log_in_user/1` signs a user in for a test.
    See PhoenixKit.Test.Fixtures.
    """
  end
end
