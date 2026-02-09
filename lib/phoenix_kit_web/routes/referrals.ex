defmodule PhoenixKitWeb.Routes.ReferralsRoutes do
  @moduledoc """
  Referral codes module routes.

  Provides route definitions for referral code settings and management.
  """

  @doc """
  Returns quoted code for referral codes routes.
  """
  def generate(url_prefix) do
    quote do
      # Referral codes admin LiveView routes (localized)
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_referral_codes_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, {:phoenix_kit_ensure_module_access, "referrals"}}] do
          live "/admin/settings/referral-codes",
               PhoenixKit.Modules.Referrals.Web.Settings,
               :index,
               as: :referral_codes_settings_localized

          live "/admin/users/referral-codes", PhoenixKit.Modules.Referrals.Web.List, :index,
            as: :referral_codes_list_localized

          live "/admin/users/referral-codes/new", PhoenixKit.Modules.Referrals.Web.Form, :new,
            as: :referral_codes_new_localized

          live "/admin/users/referral-codes/edit/:code_id",
               PhoenixKit.Modules.Referrals.Web.Form,
               :edit,
               as: :referral_codes_edit_localized
        end
      end

      # Referral codes admin LiveView routes (non-localized)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_referral_codes,
          on_mount: [{PhoenixKitWeb.Users.Auth, {:phoenix_kit_ensure_module_access, "referrals"}}] do
          live "/admin/settings/referral-codes",
               PhoenixKit.Modules.Referrals.Web.Settings,
               :index,
               as: :referral_codes_settings

          live "/admin/users/referral-codes", PhoenixKit.Modules.Referrals.Web.List, :index,
            as: :referral_codes_list

          live "/admin/users/referral-codes/new", PhoenixKit.Modules.Referrals.Web.Form, :new,
            as: :referral_codes_new

          live "/admin/users/referral-codes/edit/:code_id",
               PhoenixKit.Modules.Referrals.Web.Form,
               :edit,
               as: :referral_codes_edit
        end
      end
    end
  end
end
