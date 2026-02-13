defmodule Orchid.LLM do
  @moduledoc """
  Unified interface for LLM providers.

  Providers:
  - :cli - Claude CLI wrapper (uses claude command) - DEFAULT
  - :oauth - OAuth tokens from .claude_tokens.json (subscription)
  - :anthropic - Direct API calls (pay per token, needs ANTHROPIC_API_KEY)
  """

  alias Orchid.LLM.{Anthropic, OAuth, CLI, Gemini, Cerebras, OpenRouter}

  @doc """
  Send a chat request to the configured LLM provider.
  Returns {:ok, %{content: String.t(), tool_calls: list() | nil}}
  """
  def chat(config, context) do
    case resolve_provider(config) do
      :cli -> CLI.chat(config, context)
      :oauth -> OAuth.chat(config, context)
      :anthropic -> Anthropic.chat(config, context)
      :gemini -> Gemini.chat(config, context)
      :cerebras -> Cerebras.chat(config, context)
      :openrouter -> OpenRouter.chat(config, context)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Send a streaming chat request.
  Callback receives text chunks as they arrive.
  """
  def chat_stream(config, context, callback) do
    case resolve_provider(config) do
      :cli -> CLI.chat_stream(config, context, callback)
      :oauth -> OAuth.chat_stream(config, context, callback)
      :anthropic -> Anthropic.chat_stream(config, context, callback)
      :gemini -> Gemini.chat_stream(config, context, callback)
      :cerebras -> Cerebras.chat_stream(config, context, callback)
      :openrouter -> OpenRouter.chat_stream(config, context, callback)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  @doc """
  Get available tools formatted for the LLM provider.
  """
  def format_tools(config, tools) do
    case resolve_provider(config) do
      :anthropic -> Anthropic.format_tools(tools)
      :gemini -> Gemini.format_tools(tools)
      :openrouter -> OpenRouter.format_tools(tools)
      _ -> tools
    end
  end

  @gemini_models [:gemini_pro, :gemini_flash, :gemini_flash_image, :gemini_3_flash]
  @cerebras_models [:llama_3_1_8b, :llama_3_3_70b, :gpt_oss_120b, :qwen_3_32b, :qwen_3_235b, :zai_glm_4_7]
  @openrouter_models [:minimax_m2_5, :glm_5]

  defp resolve_provider(config) do
    cond do
      config[:model] in @gemini_models -> :gemini
      config[:model] in @cerebras_models -> :cerebras
      config[:model] in @openrouter_models -> :openrouter
      true -> config[:provider] || :cli
    end
  end
end
