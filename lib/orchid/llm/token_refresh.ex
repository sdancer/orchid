defmodule Orchid.LLM.TokenRefresh do
  @moduledoc """
  OAuth token refresh for Claude API.
  Reads from ~/.claude/.config.json and refreshes expired tokens.
  """
  require Logger

  @token_url "https://console.anthropic.com/v1/oauth/token"
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  @doc """
  Get a valid access token, refreshing if necessary.
  Returns {:ok, access_token} or {:error, reason}
  """
  def get_token do
    case read_tokens() do
      {:ok, tokens} ->
        if token_expired?(tokens) do
          Logger.info("[TokenRefresh] Token expired, refreshing...")
          refresh_and_save(tokens)
        else
          {:ok, tokens["accessToken"]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Force refresh the token regardless of expiration.
  """
  def force_refresh do
    case read_tokens() do
      {:ok, tokens} -> refresh_and_save(tokens)
      {:error, reason} -> {:error, reason}
    end
  end

  # Read tokens from Claude config
  defp read_tokens do
    config_path = get_config_path()

    if File.exists?(config_path) do
      case File.read(config_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) ->
              {:ok, oauth}

            {:ok, _} ->
              {:error, :no_oauth_tokens}

            {:error, reason} ->
              {:error, {:json_parse_error, reason}}
          end

        {:error, reason} ->
          {:error, {:file_read_error, reason}}
      end
    else
      {:error, :config_not_found}
    end
  end

  # Save tokens back to config
  defp save_tokens(new_tokens) do
    config_path = get_config_path()

    config =
      case File.read(config_path) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{}
      end

    config = Map.put(config, "claudeAiOauth", new_tokens)

    case File.write(config_path, Jason.encode!(config, pretty: true)) do
      :ok ->
        Logger.info("[TokenRefresh] Tokens saved successfully")
        :ok

      {:error, reason} ->
        Logger.error("[TokenRefresh] Failed to save tokens: #{inspect(reason)}")
        {:error, {:save_failed, reason}}
    end
  end

  # Refresh token and save
  defp refresh_and_save(tokens) do
    refresh_token = tokens["refreshToken"]

    if is_nil(refresh_token) do
      {:error, :no_refresh_token}
    else
      case do_refresh(refresh_token) do
        {:ok, new_tokens} ->
          save_tokens(new_tokens)
          {:ok, new_tokens["accessToken"]}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Perform the actual refresh request
  defp do_refresh(refresh_token) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        new_tokens = %{
          "accessToken" => response["access_token"],
          "refreshToken" => response["refresh_token"],
          "expiresAt" => System.system_time(:millisecond) + response["expires_in"] * 1000,
          "scopes" => String.split(response["scope"] || "", " "),
          "subscriptionType" => response["subscription_type"],
          "rateLimitTier" => response["rate_limit_tier"]
        }

        Logger.info("[TokenRefresh] Token refreshed successfully")
        {:ok, new_tokens}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[TokenRefresh] Refresh failed: #{status} - #{inspect(body)}")
        {:error, {:refresh_failed, status, body}}

      {:error, reason} ->
        Logger.error("[TokenRefresh] Request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # Check if token is expired
  defp token_expired?(tokens) do
    expires_at = tokens["expiresAt"]
    is_nil(expires_at) or System.system_time(:millisecond) >= expires_at
  end

  # Get config path - checks multiple locations
  defp get_config_path do
    claude_dir = Path.join(System.user_home!(), ".claude")

    # Check in order of preference
    paths = [
      Path.join(claude_dir, ".credentials.json"),
      Path.join(claude_dir, ".config.json"),
      Path.join(System.user_home!(), ".claude.json")
    ]

    Enum.find(paths, List.first(paths), &File.exists?/1)
  end
end
