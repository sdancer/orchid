defmodule Orchid.LLM do
  @moduledoc """
  Unified interface for LLM providers.

  Providers:
  - :oauth - OAuth tokens from .claude_tokens.json (subscription) - DEFAULT
  - :anthropic - Direct API calls (pay per token, needs ANTHROPIC_API_KEY)
  """

  alias Orchid.LLM.{Anthropic, OAuth}

  @doc """
  Send a chat request to the configured LLM provider.
  Returns {:ok, %{content: String.t(), tool_calls: list() | nil}}
  """
  def chat(config, context) do
    case config[:provider] || :oauth do
      :oauth -> OAuth.chat(config, context)
      :anthropic -> Anthropic.chat(config, context)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Send a streaming chat request.
  Callback receives text chunks as they arrive.
  """
  def chat_stream(config, context, callback) do
    case config[:provider] || :oauth do
      :oauth -> OAuth.chat_stream(config, context, callback)
      :anthropic -> Anthropic.chat_stream(config, context, callback)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Get available tools formatted for the LLM provider.
  """
  def format_tools(config, tools) do
    case config.provider do
      :anthropic -> Anthropic.format_tools(tools)
      _ -> tools
    end
  end
end
