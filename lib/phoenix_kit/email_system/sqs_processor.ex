defmodule PhoenixKit.EmailSystem.SQSProcessor do
  @moduledoc """
  Processor for handling email events from AWS SQS messages.

  This module is responsible for:
  - Parsing SNS messages from SQS
  - Processing different types of SES events
  - Updating email statuses in the database
  - Creating event records for tracking

  ## Supported Event Types

  - **Send** - Email send confirmation through SES
  - **Delivery** - Successful email delivery to recipient
  - **Bounce** - Email bounce (hard/soft bounce)
  - **Complaint** - Spam complaint
  - **Open** - Email open (AWS SES tracking)
  - **Click** - Link click in email

  ## Processing Architecture

  ```
  SQS Message → SNS Parsing → Event Processing → Database Update
  ```

  ## Security

  - Message structure validation
  - Event type checking
  - Protection against event duplication
  - Graceful handling of invalid data

  ## Examples

      # Parse SNS message
      {:ok, event_data} = SQSProcessor.parse_sns_message(sqs_message)

      # Process event
      {:ok, result} = SQSProcessor.process_email_event(event_data)

  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.EmailSystem.EmailEvent
  alias PhoenixKit.EmailSystem.EmailLog

  ## --- Public API ---

  @doc """
  Parses SNS message from SQS into event data structure.

  ## Parameters

  - `sqs_message` - message from SQS queue

  ## Returns

  - `{:ok, event_data}` - successfully parsed event data
  - `{:error, reason}` - parsing error

  ## Examples

      iex> SQSProcessor.parse_sns_message(sqs_message)
      {:ok, %{
        "eventType" => "delivery",
        "mail" => %{"messageId" => "abc123"},
        "delivery" => %{"timestamp" => "2025-09-20T15:30:45.000Z"}
      }}
  """
  def parse_sns_message(%{"Body" => body}) do
    parse_sns_body(body)
  end

  def parse_sns_message(%{"body" => body}) do
    parse_sns_body(body)
  end

  def parse_sns_message(%{body: body}) do
    parse_sns_body(body)
  end

  def parse_sns_message(_), do: {:error, :invalid_message_format}

  # Helper function to parse SNS body content
  defp parse_sns_body(body) when is_binary(body) do
    Logger.debug("Parsing SNS message body", %{
      body_preview: String.slice(body, 0, 300),
      body_length: String.length(body)
    })

    # Validate body is not empty
    if String.trim(body) == "" do
      Logger.error("Received empty SNS message body")
      {:error, :empty_message_body}
    else
      with {:ok, sns_data} when is_map(sns_data) <- Jason.decode(body),
           {:ok, event_data} <- extract_ses_event(sns_data) do
        {:ok, event_data}
      else
        {:ok, invalid_data} ->
          Logger.error("SNS body decoded but not a map", %{
            data_type: type_of(invalid_data),
            data_preview: inspect(invalid_data) |> String.slice(0, 200)
          })

          {:error, :invalid_sns_format}

        {:error, %Jason.DecodeError{} = error} ->
          Logger.error("Invalid JSON in SNS message body", %{
            error: inspect(error),
            position: error.position,
            body_preview: String.slice(body, 0, 500)
          })

          {:error, :invalid_json}

        {:error, reason} ->
          Logger.debug("SNS message parsing failed", %{reason: reason})
          {:error, reason}
      end
    end
  end

  defp parse_sns_body(_) do
    Logger.error("SNS body is not a binary string")
    {:error, :invalid_body_type}
  end

  # Helper to get type name for better error logging
  defp type_of(data) when is_list(data), do: :list
  defp type_of(data) when is_map(data), do: :map
  defp type_of(data) when is_binary(data), do: :binary
  defp type_of(data) when is_integer(data), do: :integer
  defp type_of(data) when is_float(data), do: :float
  defp type_of(data) when is_atom(data), do: :atom
  defp type_of(_), do: :unknown

  @doc """
  Processes email event and updates corresponding database records.

  ## Parameters

  - `event_data` - event data from SNS

  ## Returns

  - `{:ok, result}` - successful processing
  - `{:error, reason}` - processing error

  ## Examples

      iex> SQSProcessor.process_email_event(event_data)
      {:ok, %{type: "delivery", log_id: 123, updated: true}}
  """
  def process_email_event(event_data) when is_map(event_data) do
    case determine_event_type(event_data) do
      "send" ->
        process_send_event(event_data)

      "delivery" ->
        process_delivery_event(event_data)

      "bounce" ->
        process_bounce_event(event_data)

      "complaint" ->
        process_complaint_event(event_data)

      "open" ->
        process_open_event(event_data)

      "click" ->
        process_click_event(event_data)

      "reject" ->
        process_reject_event(event_data)

      "delivery_delay" ->
        process_delivery_delay_event(event_data)

      "subscription" ->
        process_subscription_event(event_data)

      "rendering_failure" ->
        process_rendering_failure_event(event_data)

      unknown_type ->
        Logger.warning("Unknown email event type", %{type: unknown_type})
        {:error, {:unknown_event_type, unknown_type}}
    end
  end

  def process_email_event(_), do: {:error, :invalid_event_data}

  ## --- Private Helper Functions ---

  # Extracts SES event from SNS message
  defp extract_ses_event(%{"Type" => "Notification", "Message" => message_json}) do
    Logger.debug("Extracting SES event from SNS notification", %{
      message_preview: String.slice(message_json, 0, 200),
      message_length: String.length(message_json)
    })

    with {:ok, :not_empty} <- validate_message_not_empty(message_json),
         {:ok, :not_validation} <- validate_not_sns_validation(message_json),
         {:ok, ses_event} <- decode_ses_message(message_json),
         {:ok, validated_event} <- validate_ses_event_fields(ses_event) do
      {:ok, validated_event}
    else
      error -> error
    end
  end

  defp extract_ses_event(%{"Type" => "SubscriptionConfirmation"}) do
    # SNS subscription confirmation - ignore
    {:error, :subscription_confirmation}
  end

  defp extract_ses_event(%{"Type" => "UnsubscribeConfirmation"}) do
    # SNS unsubscribe confirmation - ignore
    {:error, :unsubscribe_confirmation}
  end

  defp extract_ses_event(data) do
    Logger.error("Unknown SNS event format", %{
      data_keys: Map.keys(data),
      data_preview: inspect(data) |> String.slice(0, 500)
    })

    {:error, :unknown_sns_format}
  end

  # Validates message is not empty
  defp validate_message_not_empty(message_json) do
    if String.trim(message_json) == "" do
      Logger.error("Received empty SES message JSON")
      {:error, :empty_ses_message}
    else
      {:ok, :not_empty}
    end
  end

  # Validates this is not an SNS topic validation message
  defp validate_not_sns_validation(message_json) do
    if String.contains?(message_json, "Successfully validated SNS topic") do
      Logger.debug("Ignoring SNS topic validation message")
      {:error, :sns_validation_message}
    else
      {:ok, :not_validation}
    end
  end

  # Decodes the JSON message
  defp decode_ses_message(message_json) do
    case Jason.decode(message_json) do
      {:ok, ses_event} when is_map(ses_event) ->
        {:ok, ses_event}

      {:ok, invalid_data} ->
        Logger.error("SES message decoded but not a map", %{
          data_type: type_of(invalid_data),
          data_preview: inspect(invalid_data) |> String.slice(0, 500)
        })

        {:error, :invalid_ses_format}

      {:error, %Jason.DecodeError{} = error} ->
        Logger.error("Failed to decode SES message JSON - invalid JSON format", %{
          error: inspect(error),
          position: error.position,
          message_preview: String.slice(message_json, 0, 500),
          message_length: String.length(message_json)
        })

        {:error, :invalid_ses_message}
    end
  end

  # Validates required SES event fields
  defp validate_ses_event_fields(ses_event) do
    event_type = ses_event["eventType"]
    message_id = get_in(ses_event, ["mail", "messageId"])

    if event_type && message_id do
      Logger.debug("Successfully extracted SES event", %{
        event_type: event_type,
        message_id: message_id
      })

      {:ok, ses_event}
    else
      Logger.error("SES event missing required fields", %{
        event_type: event_type,
        message_id: message_id,
        available_keys: Map.keys(ses_event),
        raw_event: inspect(ses_event) |> String.slice(0, 1000)
      })

      {:error, :missing_required_fields}
    end
  end

  # Determines event type based on eventType field
  defp determine_event_type(event_data) do
    event_data
    |> Map.get("eventType", "unknown")
    |> String.downcase()
  end

  ## --- Event Processing Functions ---

  # Processes send event
  defp process_send_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Send events are usually already processed during log creation
        # Can update additional metadata if needed
        Logger.debug("Send event received for already logged email", %{
          log_id: log.id,
          message_id: message_id
        })

        {:ok, %{type: "send", log_id: log.id, updated: false}}

      {:error, :not_found} ->
        # Rare case - received send event without preliminary logging
        Logger.warning("Send event for unknown email - attempting to create placeholder log", %{
          message_id: message_id
        })

        case create_placeholder_log_from_event(event_data, "sent") do
          {:ok, log} ->
            Logger.info("Created placeholder log for send event", %{
              log_id: log.id,
              message_id: message_id
            })

            {:ok, %{type: "send", log_id: log.id, updated: true, created_placeholder: true}}

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for send event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes delivery event
  defp process_delivery_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    delivery_data = event_data["delivery"] || %{}
    delivery_timestamp = get_in(delivery_data, ["timestamp"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Update status to delivered
        update_attrs = %{
          status: "delivered",
          delivered_at: parse_timestamp(delivery_timestamp)
        }

        case EmailLog.update_log(log, update_attrs) do
          {:ok, updated_log} ->
            # Create event record
            create_delivery_event(updated_log, delivery_data)

            Logger.info("Email delivered", %{
              log_id: updated_log.id,
              message_id: message_id,
              delivered_at: updated_log.delivered_at
            })

            {:ok, %{type: "delivery", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update delivery status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning(
          "Delivery event for unknown email - attempting to create placeholder log",
          %{message_id: message_id}
        )

        case create_placeholder_log_from_event(event_data, "delivered") do
          {:ok, log} ->
            # Update status to delivered and add timestamp
            update_attrs = %{
              status: "delivered",
              delivered_at: parse_timestamp(delivery_timestamp)
            }

            case EmailLog.update_log(log, update_attrs) do
              {:ok, updated_log} ->
                # Create event record
                create_delivery_event(updated_log, delivery_data)

                Logger.info("Created placeholder log for delivery event", %{
                  log_id: updated_log.id,
                  message_id: message_id,
                  delivered_at: updated_log.delivered_at
                })

                {:ok,
                 %{
                   type: "delivery",
                   log_id: updated_log.id,
                   updated: true,
                   created_placeholder: true
                 }}

              {:error, reason} ->
                Logger.error("Failed to update placeholder log for delivery", %{
                  log_id: log.id,
                  reason: inspect(reason)
                })

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for delivery event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes bounce event
  defp process_bounce_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    bounce_data = event_data["bounce"]
    # Permanent or Temporary
    bounce_type = get_in(bounce_data, ["bounceType"])
    bounce_subtype = get_in(bounce_data, ["bounceSubType"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Determine status based on bounce type
        status =
          case String.downcase(bounce_type || "") do
            "permanent" -> "hard_bounced"
            "temporary" -> "soft_bounced"
            _ -> "bounced"
          end

        update_attrs = %{
          status: status,
          error_message: build_bounce_error_message(bounce_data)
        }

        case EmailLog.update_log(log, update_attrs) do
          {:ok, updated_log} ->
            # Create event record
            create_bounce_event(updated_log, bounce_data)

            Logger.info("Email bounced", %{
              log_id: updated_log.id,
              message_id: message_id,
              bounce_type: bounce_type,
              bounce_subtype: bounce_subtype
            })

            {:ok, %{type: "bounce", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update bounce status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Bounce event for unknown email", %{message_id: message_id})
        {:error, :email_log_not_found}
    end
  end

  # Processes complaint event
  defp process_complaint_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    complaint_data = event_data["complaint"]
    complaint_type = get_in(complaint_data, ["complaintFeedbackType"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        update_attrs = %{
          status: "complaint",
          error_message: "Spam complaint: #{complaint_type || "unknown"}"
        }

        case EmailLog.update_log(log, update_attrs) do
          {:ok, updated_log} ->
            # Create event record
            create_complaint_event(updated_log, complaint_data)

            Logger.warning("Email complaint received", %{
              log_id: updated_log.id,
              message_id: message_id,
              complaint_type: complaint_type
            })

            {:ok, %{type: "complaint", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update complaint status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning(
          "Complaint event for unknown email - attempting to create placeholder log",
          %{message_id: message_id}
        )

        case create_placeholder_log_from_event(event_data, "complaint") do
          {:ok, log} ->
            # Update status to complaint
            update_attrs = %{
              status: "complaint",
              error_message: "Spam complaint: #{complaint_type || "unknown"}"
            }

            case EmailLog.update_log(log, update_attrs) do
              {:ok, updated_log} ->
                # Create event record
                create_complaint_event(updated_log, complaint_data)

                Logger.info("Created placeholder log for complaint event", %{
                  log_id: updated_log.id,
                  message_id: message_id,
                  complaint_type: complaint_type
                })

                {:ok,
                 %{
                   type: "complaint",
                   log_id: updated_log.id,
                   updated: true,
                   created_placeholder: true
                 }}

              {:error, reason} ->
                Logger.error("Failed to update placeholder log for complaint", %{
                  log_id: log.id,
                  reason: inspect(reason)
                })

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for complaint event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes email open event
  defp process_open_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    open_data = event_data["open"]
    open_timestamp = get_in(open_data, ["timestamp"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Update status only if current status is not "clicked"
        # (click is more important than open)
        status_update =
          case log.status do
            # Do not change
            "clicked" -> %{}
            _ -> %{status: "opened"}
          end

        case EmailLog.update_log(log, status_update) do
          {:ok, updated_log} ->
            # Create event record
            create_open_event(updated_log, open_data, open_timestamp)

            Logger.debug("Email opened", %{
              log_id: updated_log.id,
              message_id: message_id,
              ip_address: get_in(open_data, ["ipAddress"])
            })

            {:ok, %{type: "open", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update open status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Open event for unknown email - attempting to create placeholder log", %{
          message_id: message_id
        })

        case create_placeholder_log_from_event(event_data, "opened") do
          {:ok, log} ->
            # Create event record for created log
            create_open_event(log, open_data, open_timestamp)

            Logger.info("Created placeholder log for open event", %{
              log_id: log.id,
              message_id: message_id
            })

            {:ok, %{type: "open", log_id: log.id, updated: true, created_placeholder: true}}

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for open event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes click event
  defp process_click_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    click_data = event_data["click"]
    click_timestamp = get_in(click_data, ["timestamp"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Click - highest engagement level
        update_attrs = %{status: "clicked"}

        case EmailLog.update_log(log, update_attrs) do
          {:ok, updated_log} ->
            # Create event record
            create_click_event(updated_log, click_data, click_timestamp)

            Logger.info("Email link clicked", %{
              log_id: updated_log.id,
              message_id: message_id,
              link_url: get_in(click_data, ["link"]),
              ip_address: get_in(click_data, ["ipAddress"])
            })

            {:ok, %{type: "click", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update click status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Click event for unknown email - attempting to create placeholder log", %{
          message_id: message_id
        })

        case create_placeholder_log_from_event(event_data, "clicked") do
          {:ok, log} ->
            # Click - highest engagement level
            update_attrs = %{status: "clicked"}

            case EmailLog.update_log(log, update_attrs) do
              {:ok, updated_log} ->
                # Create event record
                create_click_event(updated_log, click_data, click_timestamp)

                Logger.info("Created placeholder log for click event", %{
                  log_id: updated_log.id,
                  message_id: message_id,
                  link_url: get_in(click_data, ["link"]),
                  ip_address: get_in(click_data, ["ipAddress"])
                })

                {:ok,
                 %{
                   type: "click",
                   log_id: updated_log.id,
                   updated: true,
                   created_placeholder: true
                 }}

              {:error, reason} ->
                Logger.error("Failed to update placeholder log for click", %{
                  log_id: log.id,
                  reason: inspect(reason)
                })

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for click event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes reject event
  defp process_reject_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    reject_data = event_data["reject"]
    reject_reason = get_in(reject_data, ["reason"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        update_attrs = %{
          status: "rejected",
          error_message: build_reject_error_message(reject_data)
        }

        case EmailLog.update_log(log, update_attrs) do
          {:ok, updated_log} ->
            # Create event record
            create_reject_event(updated_log, reject_data)

            Logger.warning("Email rejected", %{
              log_id: updated_log.id,
              message_id: message_id,
              reject_reason: reject_reason
            })

            {:ok, %{type: "reject", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update reject status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Reject event for unknown email - attempting to create placeholder log", %{
          message_id: message_id
        })

        case create_placeholder_log_from_event(event_data, "rejected") do
          {:ok, log} ->
            update_attrs = %{
              status: "rejected",
              error_message: build_reject_error_message(reject_data)
            }

            case EmailLog.update_log(log, update_attrs) do
              {:ok, updated_log} ->
                # Create event record
                create_reject_event(updated_log, reject_data)

                Logger.info("Created placeholder log for reject event", %{
                  log_id: updated_log.id,
                  message_id: message_id,
                  reject_reason: reject_reason
                })

                {:ok,
                 %{
                   type: "reject",
                   log_id: updated_log.id,
                   updated: true,
                   created_placeholder: true
                 }}

              {:error, reason} ->
                Logger.error("Failed to update placeholder log for reject", %{
                  log_id: log.id,
                  reason: inspect(reason)
                })

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for reject event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes delivery delay event
  defp process_delivery_delay_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    delay_data = event_data["deliveryDelay"]
    delay_type = get_in(delay_data, ["delayType"])
    expiration_time = get_in(delay_data, ["expirationTime"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Only update if current status is not more advanced
        status_update =
          case log.status do
            s
            when s in [
                   "delivered",
                   "bounced",
                   "hard_bounced",
                   "soft_bounced",
                   "clicked",
                   "opened"
                 ] ->
              %{}

            _ ->
              %{status: "delayed"}
          end

        case EmailLog.update_log(log, status_update) do
          {:ok, updated_log} ->
            # Create event record
            create_delivery_delay_event(updated_log, delay_data)

            Logger.info("Email delivery delayed", %{
              log_id: updated_log.id,
              message_id: message_id,
              delay_type: delay_type,
              expiration_time: expiration_time
            })

            {:ok, %{type: "delivery_delay", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update delay status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning(
          "Delivery delay event for unknown email - attempting to create placeholder log",
          %{
            message_id: message_id
          }
        )

        case create_placeholder_log_from_event(event_data, "delayed") do
          {:ok, log} ->
            # Create event record for created log
            create_delivery_delay_event(log, delay_data)

            Logger.info("Created placeholder log for delay event", %{
              log_id: log.id,
              message_id: message_id,
              delay_type: delay_type
            })

            {:ok,
             %{type: "delivery_delay", log_id: log.id, updated: true, created_placeholder: true}}

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for delay event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes subscription event
  defp process_subscription_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    subscription_data = event_data["subscription"]
    subscription_type = get_in(subscription_data, ["subscriptionType"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        # Create event record
        create_subscription_event(log, subscription_data)

        Logger.info("Email subscription event", %{
          log_id: log.id,
          message_id: message_id,
          subscription_type: subscription_type
        })

        {:ok, %{type: "subscription", log_id: log.id, updated: false}}

      {:error, :not_found} ->
        Logger.warning(
          "Subscription event for unknown email - attempting to create placeholder log",
          %{
            message_id: message_id
          }
        )

        case create_placeholder_log_from_event(event_data, "sent") do
          {:ok, log} ->
            # Create event record for created log
            create_subscription_event(log, subscription_data)

            Logger.info("Created placeholder log for subscription event", %{
              log_id: log.id,
              message_id: message_id,
              subscription_type: subscription_type
            })

            {:ok,
             %{type: "subscription", log_id: log.id, updated: true, created_placeholder: true}}

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for subscription event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  # Processes rendering failure event
  defp process_rendering_failure_event(event_data) do
    message_id = get_in(event_data, ["mail", "messageId"])
    failure_data = event_data["failure"]
    error_message = get_in(failure_data, ["errorMessage"])
    template_name = get_in(failure_data, ["templateName"])

    case find_email_log_by_message_id(message_id) do
      {:ok, log} ->
        update_attrs = %{
          status: "failed",
          error_message: build_rendering_failure_message(failure_data)
        }

        case EmailLog.update_log(log, update_attrs) do
          {:ok, updated_log} ->
            # Create event record
            create_rendering_failure_event(updated_log, failure_data)

            Logger.error("Email rendering failed", %{
              log_id: updated_log.id,
              message_id: message_id,
              template_name: template_name,
              error_message: error_message
            })

            {:ok, %{type: "rendering_failure", log_id: updated_log.id, updated: true}}

          {:error, reason} ->
            Logger.error("Failed to update rendering failure status", %{
              log_id: log.id,
              reason: inspect(reason)
            })

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning(
          "Rendering failure event for unknown email - attempting to create placeholder log",
          %{
            message_id: message_id
          }
        )

        case create_placeholder_log_from_event(event_data, "failed") do
          {:ok, log} ->
            update_attrs = %{
              status: "failed",
              error_message: build_rendering_failure_message(failure_data)
            }

            case EmailLog.update_log(log, update_attrs) do
              {:ok, updated_log} ->
                # Create event record
                create_rendering_failure_event(updated_log, failure_data)

                Logger.info("Created placeholder log for rendering failure event", %{
                  log_id: updated_log.id,
                  message_id: message_id,
                  template_name: template_name
                })

                {:ok,
                 %{
                   type: "rendering_failure",
                   log_id: updated_log.id,
                   updated: true,
                   created_placeholder: true
                 }}

              {:error, reason} ->
                Logger.error("Failed to update placeholder log for rendering failure", %{
                  log_id: log.id,
                  reason: inspect(reason)
                })

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create placeholder log for rendering failure event", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, :email_log_not_found}
        end
    end
  end

  ## --- Helper Functions ---

  # Finds email log by message_id with simplified two-tier search
  # AWS events use AWS message IDs, so we search aws_message_id field first
  defp find_email_log_by_message_id(message_id) when is_binary(message_id) do
    Logger.debug("SQSProcessor: Searching for email log", %{
      message_id: message_id,
      message_id_length: String.length(message_id)
    })

    # Primary search - AWS message_id field (AWS events use AWS IDs)
    case EmailLog.find_by_aws_message_id(message_id) do
      {:ok, log} ->
        Logger.debug("SQSProcessor: Found email log by aws_message_id field", %{
          log_id: log.id,
          internal_message_id: log.message_id,
          aws_message_id: message_id
        })

        {:ok, log}

      {:error, :not_found} ->
        # Secondary fallback - try internal message_id field (backward compatibility)
        case PhoenixKit.EmailSystem.get_log_by_message_id(message_id) do
          {:ok, log} ->
            Logger.info("SQSProcessor: Found email log by internal message_id field", %{
              log_id: log.id,
              message_id: message_id
            })

            {:ok, log}

          {:error, :not_found} ->
            Logger.warning("SQSProcessor: No email log found for message_id", %{
              message_id: message_id,
              searched_fields: ["aws_message_id", "message_id"]
            })

            # Try to find similar records for diagnostics
            log_recent_emails_for_diagnosis(message_id)

            {:error, :not_found}

          {:error, reason} ->
            Logger.error("SQSProcessor: Error during email log search", %{
              message_id: message_id,
              reason: inspect(reason)
            })

            {:error, reason}
        end
    end
  end

  defp find_email_log_by_message_id(message_id) do
    Logger.error("SQSProcessor: Invalid message_id format", %{
      message_id: inspect(message_id),
      message_id_type: type_of(message_id)
    })

    {:error, :invalid_message_id}
  end

  # Logs recent emails for search problem diagnostics
  defp log_recent_emails_for_diagnosis(missing_message_id) do
    # Get last 5 emails for diagnostics
    recent_logs =
      from(l in PhoenixKit.EmailSystem.EmailLog,
        order_by: [desc: l.inserted_at],
        limit: 5,
        select: {l.id, l.message_id, l.inserted_at}
      )
      |> PhoenixKit.RepoHelper.repo().all()

    Logger.debug("SQSProcessor: Recent emails for diagnosis", %{
      missing_message_id: missing_message_id,
      recent_logs:
        Enum.map(recent_logs, fn {id, msg_id, inserted_at} ->
          %{
            id: id,
            message_id: msg_id,
            inserted_at: inserted_at,
            matches_pattern:
              String.contains?(msg_id || "", String.slice(missing_message_id, 0, 10))
          }
        end)
    })
  rescue
    error ->
      Logger.debug("SQSProcessor: Failed to get recent logs for diagnosis: #{inspect(error)}")
  end

  # Creates event record for delivery
  defp create_delivery_event(log, delivery_data) do
    # Check if delivery event already exists to prevent duplicates
    if EmailEvent.event_exists?(log.id, "delivery") do
      Logger.debug("Delivery event already exists for email log #{log.id}, skipping")
      {:ok, :duplicate_event}
    else
      event_attrs = %{
        email_log_id: log.id,
        event_type: "delivery",
        event_data: delivery_data,
        occurred_at: parse_timestamp(get_in(delivery_data, ["timestamp"]))
      }

      PhoenixKit.EmailSystem.create_event(event_attrs)
    end
  end

  # Creates event record for bounce
  defp create_bounce_event(log, bounce_data) do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "bounce",
      event_data: bounce_data,
      occurred_at: parse_timestamp(get_in(bounce_data, ["timestamp"])),
      bounce_type: get_in(bounce_data, ["bounceType"])
    }

    PhoenixKit.EmailSystem.create_event(event_attrs)
  end

  # Creates event record for complaint
  defp create_complaint_event(log, complaint_data) do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "complaint",
      event_data: complaint_data,
      occurred_at: parse_timestamp(get_in(complaint_data, ["timestamp"])),
      complaint_type: get_in(complaint_data, ["complaintFeedbackType"])
    }

    PhoenixKit.EmailSystem.create_event(event_attrs)
  end

  # Creates event record for open
  defp create_open_event(log, open_data, timestamp) do
    # Check if open event already exists to prevent duplicates
    if EmailEvent.event_exists?(log.id, "open") do
      Logger.debug("Open event already exists for email log #{log.id}, skipping")
      {:ok, :duplicate_event}
    else
      event_attrs = %{
        email_log_id: log.id,
        event_type: "open",
        event_data: open_data,
        occurred_at: parse_timestamp(timestamp),
        ip_address: get_in(open_data, ["ipAddress"]),
        user_agent: get_in(open_data, ["userAgent"])
      }

      PhoenixKit.EmailSystem.create_event(event_attrs)
    end
  end

  # Creates event record for click
  defp create_click_event(log, click_data, timestamp) do
    # For clicks, we might want to allow multiple click events (different links)
    # but for now, let's prevent duplicate click events too
    if EmailEvent.event_exists?(log.id, "click") do
      Logger.debug("Click event already exists for email log #{log.id}, skipping")
      {:ok, :duplicate_event}
    else
      event_attrs = %{
        email_log_id: log.id,
        event_type: "click",
        event_data: click_data,
        occurred_at: parse_timestamp(timestamp),
        link_url: get_in(click_data, ["link"]),
        ip_address: get_in(click_data, ["ipAddress"]),
        user_agent: get_in(click_data, ["userAgent"])
      }

      PhoenixKit.EmailSystem.create_event(event_attrs)
    end
  end

  # Creates event record for reject
  defp create_reject_event(log, reject_data) do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "reject",
      event_data: reject_data,
      occurred_at: parse_timestamp(get_in(reject_data, ["timestamp"])),
      reject_reason: get_in(reject_data, ["reason"])
    }

    PhoenixKit.EmailSystem.create_event(event_attrs)
  end

  # Creates event record for delivery delay
  defp create_delivery_delay_event(log, delay_data) do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "delivery_delay",
      event_data: delay_data,
      occurred_at: parse_timestamp(get_in(delay_data, ["timestamp"])),
      delay_type: get_in(delay_data, ["delayType"])
    }

    PhoenixKit.EmailSystem.create_event(event_attrs)
  end

  # Creates event record for subscription
  defp create_subscription_event(log, subscription_data) do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "subscription",
      event_data: subscription_data,
      occurred_at: parse_timestamp(get_in(subscription_data, ["timestamp"])),
      subscription_type: get_in(subscription_data, ["subscriptionType"])
    }

    PhoenixKit.EmailSystem.create_event(event_attrs)
  end

  # Creates event record for rendering failure
  defp create_rendering_failure_event(log, failure_data) do
    event_attrs = %{
      email_log_id: log.id,
      event_type: "rendering_failure",
      event_data: failure_data,
      occurred_at: parse_timestamp(get_in(failure_data, ["timestamp"])),
      failure_reason: get_in(failure_data, ["errorMessage"])
    }

    PhoenixKit.EmailSystem.create_event(event_attrs)
  end

  # Parses timestamp string to DateTime
  defp parse_timestamp(timestamp_string) when is_binary(timestamp_string) do
    case DateTime.from_iso8601(timestamp_string) do
      {:ok, datetime, _} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  # Creates error message for bounce
  defp build_bounce_error_message(bounce_data) do
    bounce_type = get_in(bounce_data, ["bounceType"])
    bounce_subtype = get_in(bounce_data, ["bounceSubType"])

    recipients = get_in(bounce_data, ["bouncedRecipients"]) || []

    recipient_details =
      Enum.map(recipients, fn recipient ->
        email = recipient["emailAddress"]
        status = recipient["status"]
        diagnostic = recipient["diagnosticCode"]

        parts = [email, status, diagnostic] |> Enum.filter(& &1) |> Enum.join(" - ")
        parts
      end)

    base_message = "#{bounce_type} bounce"

    base_message =
      if bounce_subtype, do: "#{base_message} (#{bounce_subtype})", else: base_message

    if Enum.empty?(recipient_details) do
      base_message
    else
      "#{base_message}: #{Enum.join(recipient_details, "; ")}"
    end
  end

  # Creates placeholder email log from event data for cases
  # when we receive events without a pre-created log
  defp create_placeholder_log_from_event(event_data, initial_status) do
    mail_data = event_data["mail"] || %{}
    message_id = get_in(mail_data, ["messageId"])

    # Extract main data from event
    destination = get_in(mail_data, ["destination"]) || []
    source = get_in(mail_data, ["source"])

    # Determine recipient (first in destination list)
    to_email =
      case destination do
        [first | _] when is_binary(first) -> first
        _ -> "unknown@example.com"
      end

    # Determine sender
    from_email =
      case source do
        email when is_binary(email) -> email
        _ -> "unknown@example.com"
      end

    # Get general information from mail object
    subject = get_in(mail_data, ["commonHeaders", "subject"]) || "(no subject)"
    timestamp = get_in(mail_data, ["timestamp"])

    log_attrs = %{
      message_id: message_id,
      # Store AWS message ID in dedicated field
      aws_message_id: message_id,
      to: to_email,
      from: from_email,
      subject: subject,
      status: initial_status,
      sent_at: parse_timestamp(timestamp),
      headers: %{
        "x-placeholder-log" => "true",
        "x-created-from-event" => event_data["eventType"] || "unknown"
      },
      body_preview: "(email body not available - created from event)",
      provider: "aws_ses",
      template_name: "placeholder",
      campaign_id: "recovered_from_event"
    }

    PhoenixKit.EmailSystem.create_log(log_attrs)
  end

  # Builds error message for reject events
  defp build_reject_error_message(reject_data) do
    reason = get_in(reject_data, ["reason"]) || "unknown"
    "Email rejected by SES: #{reason}"
  end

  # Builds error message for rendering failure events
  defp build_rendering_failure_message(failure_data) do
    error_message = get_in(failure_data, ["errorMessage"]) || "unknown error"
    template_name = get_in(failure_data, ["templateName"])

    base_message = "Template rendering failed: #{error_message}"

    if template_name do
      "#{base_message} (template: #{template_name})"
    else
      base_message
    end
  end
end
