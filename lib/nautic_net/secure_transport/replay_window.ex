defmodule NauticNet.SecureTransport.ReplayWindow do
  @moduledoc """
  Per-(session, epoch) anti-replay window.

  Tracks the highest accepted counter (`hi`) plus a 64-bit sliding bitmap of the
  counters at or below `hi` (bit offset `hi - counter`). The window tolerates benign
  reordering (e.g. on a future UDP transport) while strictly rejecting:

    * replays (a counter already accepted), and
    * counters older than `hi - 64` (outside the window).

  Out-of-epoch enforcement is handled by `Frame`/`Session` (the window itself is
  scoped to a single epoch and is reset on rekey). A frame must only be committed to
  the window AFTER its AEAD tag verifies, so a forged frame cannot poison the window.
  """

  import Bitwise

  @window_bits 64
  @window_mask (1 <<< 64) - 1

  @enforce_keys [:hi, :bitmap]
  defstruct hi: -1, bitmap: 0

  @type t :: %__MODULE__{hi: integer(), bitmap: non_neg_integer()}

  @doc "A fresh, empty replay window (no counters accepted yet)."
  @spec new() :: t()
  def new, do: %__MODULE__{hi: -1, bitmap: 0}

  @doc """
  Check whether `counter` is acceptable WITHOUT mutating the window.

  Returns `:ok` or `{:error, :replayed | :stale_counter}`. Use `check_and_commit/2`
  to atomically check and record.
  """
  @spec check(t(), integer()) :: :ok | {:error, :replayed | :stale_counter}
  def check(%__MODULE__{}, counter) when not is_integer(counter) or counter < 0,
    do: {:error, :stale_counter}

  def check(%__MODULE__{hi: hi}, counter) when counter > hi, do: :ok

  def check(%__MODULE__{hi: hi, bitmap: bitmap}, counter) do
    offset = hi - counter

    cond do
      offset >= @window_bits -> {:error, :stale_counter}
      (bitmap >>> offset &&& 1) == 1 -> {:error, :replayed}
      true -> :ok
    end
  end

  @doc """
  Check `counter` and, if acceptable, return the updated window with it recorded.

  Returns `{:ok, window}` or `{:error, reason}`.
  """
  @spec check_and_commit(t(), integer()) ::
          {:ok, t()} | {:error, :replayed | :stale_counter}
  def check_and_commit(%__MODULE__{} = w, counter) do
    case check(w, counter) do
      :ok -> {:ok, commit(w, counter)}
      {:error, _} = err -> err
    end
  end

  # commit assumes `check/2` already returned :ok for this counter.
  defp commit(%__MODULE__{hi: hi, bitmap: bitmap}, counter) when counter > hi do
    shift = counter - hi

    new_bitmap =
      if shift >= @window_bits do
        # The new counter is far ahead; the old window slides entirely out.
        1
      else
        ((bitmap <<< shift) &&& @window_mask) ||| 1
      end

    %__MODULE__{hi: counter, bitmap: new_bitmap}
  end

  defp commit(%__MODULE__{hi: hi, bitmap: bitmap} = w, counter) do
    offset = hi - counter
    %{w | bitmap: bitmap ||| 1 <<< offset}
  end
end
