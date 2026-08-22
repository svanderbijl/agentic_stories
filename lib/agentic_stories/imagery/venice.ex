defmodule AgenticStories.Imagery.Venice do
  @moduledoc """
  Venice.ai driver for `AgenticStories.Imagery`: photorealistic, uncensored
  image generation. Plain renders go through `POST /v1/image/generate`
  (base64 JSON response); compositions with character references go through
  `POST /v1/image/multi-edit` (raw image response), which takes up to three
  input images — the same cap `Imagery.compose/2` already enforces.

  `safe_mode` is forced off (Venice's default blurs adult output) and the
  Venice watermark is hidden.

  Configuration under `config :agentic_stories, AgenticStories.Imagery.Venice`:

    * `:api_key` — set from `VENICE_API_KEY` in `config/runtime.exs`
    * `:model` — defaults to `lustify-v8` (photorealistic, Venice's
      `most_uncensored` trait; `qwen-image` is their `highest_quality`
      alternative)
    * `:edit_model` — defaults to `qwen-edit-uncensored` for compositions
    * `:base_url` — defaults to the public API
    * `:plug` — used by the driver tests to route requests to `Req.Test`
  """

  @behaviour AgenticStories.Imagery

  @default_base_url "https://api.venice.ai/api"
  @default_model "lustify-v8"
  @default_edit_model "qwen-edit-uncensored"

  @impl true
  def generate(prompt) do
    config = config()

    body = %{
      model: Keyword.get(config, :model, @default_model),
      prompt: prompt,
      width: 1024,
      height: 1024,
      format: "jpeg",
      safe_mode: false,
      hide_watermark: true
    }

    case Req.post(client(config), url: "/v1/image/generate", json: body) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @impl true
  def compose(prompt, []), do: generate(prompt)

  def compose(prompt, references) when is_list(references) do
    config = config()

    body = %{
      modelId: Keyword.get(config, :edit_model, @default_edit_model),
      prompt: prompt,
      images: Enum.map(references, &data_uri/1),
      output_format: "jpeg"
    }

    case Req.post(client(config), url: "/v1/image/multi-edit", json: body) do
      {:ok, %Req.Response{status: 200, body: binary} = response} when is_binary(binary) ->
        {:ok, %{binary: binary, content_type: content_type(response)}}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:unexpected_response, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp data_uri(%{binary: binary, content_type: content_type}) do
    "data:#{content_type};base64," <> Base.encode64(binary)
  end

  defp decode(%{"images" => [b64 | _rest]}) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, %{binary: binary, content_type: "image/jpeg"}}
      :error -> {:error, :invalid_image_payload}
    end
  end

  defp decode(body), do: {:error, {:unexpected_response, body}}

  defp content_type(%Req.Response{} = response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _rest] -> value |> String.split(";") |> hd() |> String.trim()
      [] -> "image/jpeg"
    end
  end

  defp client(config) do
    options = [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      auth: {:bearer, api_key!(config)},
      receive_timeout: 120_000
    ]

    options =
      case Keyword.fetch(config, :plug) do
        {:ok, plug} -> Keyword.put(options, :plug, plug)
        :error -> options
      end

    Req.new(options)
  end

  defp config, do: Application.get_env(:agentic_stories, __MODULE__, [])

  defp api_key!(config) do
    Keyword.get(config, :api_key) ||
      raise "VENICE_API_KEY is not set; export it before starting the app " <>
              "(or configure :api_key for #{inspect(__MODULE__)})"
  end
end
