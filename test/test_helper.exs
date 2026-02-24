# Test helper for PhoenixKit test suite
ExUnit.start()

# Configure test environment
Application.put_env(:phoenix_kit, :repo, PhoenixKit.Test.Repo)

# Start the ModuleRegistry so persistent_term is populated for tests
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# Note: Tests are currently in development phase
# This file provides the foundation for the PhoenixKit test suite
