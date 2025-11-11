defmodule PhoenixKitTest do
  use ExUnit.Case
  doctest PhoenixKit

  @moduledoc """
  Basic smoke tests for PhoenixKit library.

  These tests verify the core PhoenixKit module is loadable and functional.
  More comprehensive tests for authentication, roles, email system, and
  migrations are in development.
  """

  describe "PhoenixKit module" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PhoenixKit)
    end

    test "version is defined" do
      # Verify the version constant exists in mix.exs
      mix_config = Mix.Project.config()
      assert is_binary(mix_config[:version])
      assert String.match?(mix_config[:version], ~r/^\d+\.\d+\.\d+/)
    end

    test "application is properly configured" do
      assert Application.get_application(PhoenixKit) == :phoenix_kit
    end
  end

  describe "PhoenixKit.RepoHelper" do
    test "module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.RepoHelper)
    end
  end

  describe "PhoenixKit.Users.Auth" do
    test "authentication module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Users.Auth)
    end

    test "User schema is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Users.Auth.User)
    end
  end

  describe "PhoenixKit.EmailSystem" do
    test "email system module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.EmailSystem)
    end
  end

  describe "PhoenixKit.Migrations" do
    test "migration module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Migrations.Postgres)
    end

    test "initial version is defined" do
      assert PhoenixKit.Migrations.Postgres.initial_version() == 1
    end

    test "current version is defined and greater than initial" do
      current = PhoenixKit.Migrations.Postgres.current_version()
      initial = PhoenixKit.Migrations.Postgres.initial_version()

      assert is_integer(current)
      assert current >= initial
      assert current >= 15  # V15 is latest as of 1.2.13
    end
  end
end
