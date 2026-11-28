defmodule Mix.Tasks.PhoenixKit.Update.NextStepTest do
  @moduledoc """
  The line `mix phoenix_kit.update` ends with. It used to say
  "Visit: /users/register" — built from the `--prefix` option, which is a
  database schema, not the URL prefix — and on an install without an Owner it
  pointed at a sign-up that no longer makes one.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Utils.Routes

  test "with an Owner: the admin area, under the url_prefix" do
    line = Update.next_step_line(:exists)
    assert line =~ Routes.path("/admin", locale: :none)
    refute line =~ "create_owner"
  end

  test "without an Owner: the create_owner task" do
    assert Update.next_step_line(:none) =~ "mix phoenix_kit.create_owner"
  end

  test "when the count cannot be read: both, prefixed" do
    line = Update.next_step_line(:unknown)
    assert line =~ Routes.path("/admin", locale: :none)
    assert line =~ "mix phoenix_kit.create_owner"
  end

  # The "After update completes" block of the migration notice used to end on
  # "Visit your application: <prefix>/users/register" — the sign-up page,
  # which no longer makes the first Owner — while the closing line already
  # pointed at the admin area or create_owner.
  test "the post-migration steps end on the same pointer, not the sign-up page" do
    source = File.read!("lib/mix/tasks/phoenix_kit.update.ex")

    [_, block] = Regex.run(~r/After update completes:(.*?)\"\"\"/s, source)

    refute block =~ "users/register"
    refute block =~ "Visit your application"
    assert block =~ "next_step_line()"
  end
end
