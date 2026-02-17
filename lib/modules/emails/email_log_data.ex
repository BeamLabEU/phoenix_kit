defmodule PhoenixKit.Modules.Emails.EmailLogData do
  @moduledoc """
  Struct representing extracted email data for logging.

  Constructed in `Interceptor.extract_email_data/2` and passed to
  `Emails.create_log/1` for persistence.

  ## Fields

  - `message_id` - Unique message identifier
  - `to` - Primary recipient email address
  - `from` - Sender email address
  - `subject` - Email subject line
  - `headers` - Extracted email headers
  - `body_preview` - Truncated body preview
  - `body_full` - Full email body (when email_save_body is enabled)
  - `attachments_count` - Number of attachments
  - `size_bytes` - Estimated email size in bytes
  - `template_name` - Template identifier if applicable
  - `campaign_id` - Campaign identifier if applicable
  - `user_id` - Associated user integer ID
  - `user_uuid` - Associated user UUID
  - `provider` - Email delivery provider name
  - `configuration_set` - AWS SES configuration set name
  - `message_tags` - Map of message tags
  """

  @enforce_keys [:message_id, :to, :from, :subject]
  defstruct [
    :message_id,
    :to,
    :from,
    :subject,
    :headers,
    :body_preview,
    :body_full,
    :attachments_count,
    :size_bytes,
    :template_name,
    :campaign_id,
    :user_id,
    :user_uuid,
    :provider,
    :configuration_set,
    :message_tags
  ]

  @type t :: %__MODULE__{
          message_id: String.t(),
          to: String.t(),
          from: String.t(),
          subject: String.t(),
          headers: map() | nil,
          body_preview: String.t() | nil,
          body_full: String.t() | nil,
          attachments_count: integer() | nil,
          size_bytes: integer() | nil,
          template_name: String.t() | nil,
          campaign_id: String.t() | nil,
          user_id: integer() | nil,
          user_uuid: String.t() | nil,
          provider: String.t() | nil,
          configuration_set: String.t() | nil,
          message_tags: map() | nil
        }
end
