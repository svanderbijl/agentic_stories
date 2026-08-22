defmodule AgenticStories.LLM do
  @moduledoc """
  The provider port for language models.

  All LLM traffic flows through `chat/1`, which dispatches to the adapter
  configured under `config :agentic_stories, AgenticStories.LLM`. Drivers
  implement this module's behaviour; domain code never talks to a driver
  (or to HTTP) directly.
  """

  alias AgenticStories.LLM.{Ledger, Request, Response}

  @callback chat(Request.t()) :: {:ok, Response.t()} | {:error, term()}

  @doc """
  Sends a chat request through the configured adapter. `meta` feeds the cost
  ledger: pass `story_id:` and `purpose:` (`:weave`, `:tick`, `:consolidate`,
  `:direct`, `:residue`, `:recap`) so every story knows what it spent.
  """
  @spec chat(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def chat(%Request{} = request, meta \\ []) do
    case adapter().chat(request) do
      {:ok, %Response{} = response} ->
        Ledger.record(request, response, meta)
        {:ok, response}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Model that weaves a seed into a story."
  @spec weaver_model() :: String.t()
  def weaver_model, do: Keyword.fetch!(config(), :weaver_model)

  @doc "Cheap/fast model that drives character ticks."
  @spec character_model() :: String.t()
  def character_model, do: Keyword.fetch!(config(), :character_model)

  @doc "Model behind the Director — taste matters, frequency is low."
  @spec director_model() :: String.t()
  def director_model, do: Keyword.fetch!(config(), :director_model)

  defp adapter, do: Keyword.fetch!(config(), :adapter)
  defp config, do: Application.fetch_env!(:agentic_stories, __MODULE__)
end
