defmodule Deft.OM.Tokens do
  @moduledoc """
  Token estimation utilities for Observational Memory.

  Uses a character-based heuristic to estimate token counts without requiring
  a tokenizer dependency. The calibration factor is updated over time using
  actual token counts from provider usage reports.
  """

  @doc """
  Estimates the token count for the given text using a configurable calibration factor.

  The default calibration factor is 4.0, meaning approximately 4 characters per token.
  This is a well-known approximation for English text with modern tokenizers.

  ## Examples

      iex> Deft.OM.Tokens.estimate("hello world", 4.0)
      2

      iex> Deft.OM.Tokens.estimate("hello world", 5.0)
      2
  """
  @spec estimate(String.t(), float()) :: integer()
  def estimate(text, calibration_factor \\ 4.0) do
    div(byte_size(text), trunc(calibration_factor))
  end

  @doc """
  Updates the calibration factor using exponential moving average.

  Given the current calibration factor and a new observation (actual characters
  and actual tokens from a provider usage report), computes an updated calibration
  factor using EMA with alpha=0.1.

  ## Examples

      iex> Deft.OM.Tokens.calibrate(4.0, 100, 25)
      4.0

      iex> Deft.OM.Tokens.calibrate(4.0, 100, 20)
      4.2
  """
  @spec calibrate(float(), integer(), integer()) :: float()
  def calibrate(current_factor, actual_chars, actual_tokens) when actual_tokens > 0 do
    observed_factor = actual_chars / actual_tokens
    alpha = 0.1
    current_factor * (1 - alpha) + observed_factor * alpha
  end

  def calibrate(current_factor, _actual_chars, _actual_tokens) do
    # If actual_tokens is 0, return current factor unchanged
    current_factor
  end
end
