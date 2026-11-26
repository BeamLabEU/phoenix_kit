defmodule PhoenixKit.Install.JsIntegrationThemeBootstrapTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.JsIntegration

  describe "theme_bootstrap_plan/1" do
    test "skips a layout that already renders the component" do
      html = """
      <head>
        <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :already_present
    end

    test "places the bootstrap after a stock phx:theme script, not before" do
      # phx.new 1.8's script treats "system" as "remove data-theme". Running
      # BEFORE it would stamp the configured pair and then have that undone.
      html = """
      <head>
        <script>
          localStorage.getItem("phx:theme")
        </script>
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :before_head_close
    end

    test "places the bootstrap after the real phx.new 1.8 script, which clears the theme" do
      html = """
      <head>
        <script>
          (() => {
            const setTheme = (theme) => {
              if (theme === "system") {
                localStorage.removeItem("phx:theme");
                document.documentElement.removeAttribute("data-theme");
              } else {
                localStorage.setItem("phx:theme", theme);
                document.documentElement.setAttribute("data-theme", theme);
              }
            };
            setTheme(localStorage.getItem("phx:theme") || "system");
          })();
        </script>
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :before_head_close
    end

    test "leaves a layout alone when the host stamps data-theme itself" do
      # A host's own stamp from the same key, which never clears the attribute.
      # Injecting after it would override it and kill the host's
      # [data-theme=dark] rules.
      html = """
      <head>
        <script>
          const t = localStorage.getItem("phx:theme") || "light";
          document.documentElement.setAttribute("data-theme", t === "system" ? "light" : t);
        </script>
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :host_managed
    end

    test "a host switcher that sets AND clears, with its own key, stays the host's" do
      # Not the stock script: that one reads `phx:theme`. Treating this as stock
      # would inject the kit after it, and the kit's stamp would win every load.
      html = """
      <head>
        <script>
          const t = localStorage.getItem("theme");
          if (t === "dark") document.documentElement.setAttribute("data-theme", "dark");
          else document.documentElement.removeAttribute("data-theme");
        </script>
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :host_managed
    end

    test "a dataset assignment or a static html attribute also counts as the host's stamp" do
      assert JsIntegration.theme_bootstrap_plan("""
             <head><script>document.documentElement.dataset.theme = "dark"</script></head>
             """) == :host_managed

      assert JsIntegration.theme_bootstrap_plan("""
             <html lang="en" data-theme="corporate"><head></head></html>
             """) == :host_managed
    end

    test "the explicit host marker opts out" do
      html = """
      <head>
        <%!-- phoenix_kit: theme managed by host --%>
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :host_managed
    end

    test "a comment naming ThemeBootstrap still opts out, as hosts rely on" do
      html = """
      <head>
        <%!-- no ThemeBootstrap here: this app stamps its own theme --%>
      </head>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :already_present
    end

    test "a host-managed layout is never rewritten" do
      html = """
      <head>
        <script>document.documentElement.setAttribute("data-theme", "light")</script>
      </head>
      """

      assert JsIntegration.inject_theme_bootstrap_into(html) == html
    end

    test "lands at the top of head when there is no stock script" do
      html = """
      <html>
        <head>
          <meta charset="utf-8" />
        </head>
      </html>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :top_of_head
    end

    test "a <header> is not a <head>" do
      # The previous injector used `<head[^>]*>`, which matches <header>.
      html = """
      <html>
        <body>
          <header class="nav"></header>
        </body>
      </html>
      """

      assert JsIntegration.theme_bootstrap_plan(html) == :top_of_head
    end
  end

  describe "inject_theme_bootstrap_into/1" do
    test "does not inject into a <header> when there is no <head>" do
      html = "<body><header class=\"nav\"></header></body>"
      assert JsIntegration.inject_theme_bootstrap_into(html) == html
    end

    test "injects after <head>, not after a later <header>" do
      html = """
      <head>
        <meta charset="utf-8" />
      </head>
      <body>
        <header>Nav</header>
      </body>
      """

      updated = JsIntegration.inject_theme_bootstrap_into(html)

      assert updated =~ ~r{<head>\s*<%!-- PhoenixKit theme bootstrap}
      refute String.contains?(updated, "<header>\n        <%!-- PhoenixKit theme bootstrap")
    end

    test "on a stock phx:theme layout, lands just before </head>" do
      html = """
      <head>
        <script>localStorage.getItem("phx:theme")</script>
      </head>
      """

      updated = JsIntegration.inject_theme_bootstrap_into(html)
      [before, _after] = String.split(updated, "</head>", parts: 2)

      assert before =~ "phx:theme"
      assert before =~ "ThemeBootstrap.theme_bootstrap"
    end
  end

  describe "removing the kit's root snippet (--remove-root-theme)" do
    @marked """
    <head>
      <%!-- PhoenixKit theme bootstrap: pre-paint theme stamp --%>
      <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />
      <title>x</title>
    </head>
    """

    test "removes the marker and the component line, nothing else" do
      assert {:ok, updated} = JsIntegration.remove_theme_bootstrap_from(@marked)
      refute updated =~ "ThemeBootstrap"
      refute updated =~ "PhoenixKit theme bootstrap"
      assert updated =~ "<title>x</title>"
    end

    test "a host's own unmarked bootstrap is not the kit's and stays" do
      html = "<head>\n  <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />\n</head>\n"
      assert JsIntegration.remove_theme_bootstrap_from(html) == :not_found
    end

    test "inject then remove round-trips the layout" do
      html = "<head>\n  <title>x</title>\n</head>\n"
      injected = JsIntegration.inject_theme_bootstrap_into(html)
      assert injected =~ "ThemeBootstrap"
      assert {:ok, ^html} = JsIntegration.remove_theme_bootstrap_from(injected)
    end
  end
end
