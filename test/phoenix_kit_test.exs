defmodule PhoenixKitTest do
  use ExUnit.Case

  alias PhoenixKit.Migrations.Postgres, as: Migrations

  @moduledoc """
  Basic smoke tests for PhoenixKit library.

  PhoenixKit is a library module designed to be integrated into Phoenix applications.
  These tests verify that core modules are loadable and properly configured.

  Comprehensive testing should be performed in the context of a parent Phoenix
  application where database, configuration, and runtime dependencies are available.
  """

  describe "PhoenixKit module" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PhoenixKit)
    end

    test "version is defined" do
      # Verify the version constant exists in mix.exs
      mix_config = Mix.Project.config()
      version = mix_config[:version]

      assert is_binary(version)
      assert String.match?(version, ~r/^\d+\.\d+\.\d+/)
    end

    test "application is properly configured" do
      assert Application.get_application(PhoenixKit) == :phoenix_kit
    end
  end

  describe "Core modules" do
    test "RepoHelper module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.RepoHelper)
    end

    test "Users.Auth module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Users.Auth)
    end

    test "User schema is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Users.Auth.User)
    end

    test "Settings module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Settings)
    end

    test "Migrations.Postgres module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Migrations.Postgres)
    end
  end

  describe "Migration system" do
    test "initial version is defined" do
      assert Migrations.initial_version() == 1
    end

    test "current version is defined and valid" do
      current = Migrations.current_version()
      initial = Migrations.initial_version()

      assert is_integer(current)
      assert current >= initial
      # Current version should be at least V15 as of 1.2.13
      assert current >= 15
    end
  end

  describe "Posts worker modules" do
    test "PublishScheduledPostsJob worker is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Posts.Workers.PublishScheduledPostsJob)
    end

    test "ScheduledPostHandler is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Posts.ScheduledPostHandler)
    end
  end

  describe "ScheduledJobs modules" do
    test "ScheduledJobs context is defined" do
      assert Code.ensure_loaded?(PhoenixKit.ScheduledJobs)
    end

    test "ScheduledJob schema is defined" do
      assert Code.ensure_loaded?(PhoenixKit.ScheduledJobs.ScheduledJob)
    end

    test "Handler behaviour is defined" do
      assert Code.ensure_loaded?(PhoenixKit.ScheduledJobs.Handler)
    end

    test "ProcessScheduledJobsWorker is defined" do
      assert Code.ensure_loaded?(PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker)
    end
  end
end
