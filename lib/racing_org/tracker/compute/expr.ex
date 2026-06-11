defmodule RacingOrg.Tracker.Compute.Expr do
  @moduledoc """
  A SAFE, sandboxed RPN (reverse-Polish / postfix) stack machine that evaluates the
  free-form computed-value expressions the backend has already validated + compiled.

  This module does NO parsing: it receives the postfix token list the server compiled
  (see `RacingOrg.Tracker.Compute.Engine` / the wire contract) and folds it over a value
  stack. It NEVER touches `Code.eval`, `apply`, or anything reflective — every
  operator and function name is pattern-matched against a FIXED whitelist, so a token
  list (even a malicious one) can only ever do arithmetic on the stack.

  ## Tokens (string keys, as decoded from JSON)

    * `%{"const" => float}` — push the constant.
    * `%{"signal" => name}` — push the current value of that raw signal, resolved via
      the injected `lookup` function (the signal value is in CATALOG UNITS: speeds in
      m/s, angles in DEGREES). If the signal is unavailable/stale, the lookup returns
      `:error` and the WHOLE evaluation is `:invalid`.
    * `%{"op" => op}` — `"neg"` pops 1; `"+","-","*","/","^"` pop 2 (`a op b` with
      `a` pushed first). `^` is `:math.pow/2`.
    * `%{"fn" => name, "arity" => n}` — pop `n`, apply, push. Whitelist:
      - arity 1: `abs sqrt sin cos tan asin acos atan deg2rad rad2deg`
      - arity 2: `min max atan2 hypot`
      - arity 3: `clamp`

  ## Result

  `{:ok, value}` (a finite float) or `:invalid`. `:invalid` is returned for: a missing
  signal; stack underflow/overflow (a malformed list — should never happen from a
  valid compile, but we are defensive); division by zero; domain errors
  (`sqrt`/`asin`/`acos` out of range, `tan` near the asymptote); and any non-finite
  result (`±Inf`/`NaN`).

  The trig functions operate in RADIANS (standard `:math`). Since angle signals are in
  DEGREES, expression authors insert `deg2rad` — that is intentional and matches the
  backend validator/catalog.
  """

  @typedoc "A signal resolver: name -> {:ok, value_in_catalog_units} | :error."
  @type lookup :: (String.t() -> {:ok, number()} | :error)

  @typedoc "A single postfix token (string keys, as decoded from JSON)."
  @type token :: map()

  @arity %{
    "abs" => 1,
    "sqrt" => 1,
    "sin" => 1,
    "cos" => 1,
    "tan" => 1,
    "asin" => 1,
    "acos" => 1,
    "atan" => 1,
    "deg2rad" => 1,
    "rad2deg" => 1,
    "min" => 2,
    "max" => 2,
    "atan2" => 2,
    "hypot" => 2,
    "clamp" => 3
  }

  @doc """
  Evaluate the postfix `tokens` against the `lookup` signal resolver. Returns
  `{:ok, finite_float}` or `:invalid`.
  """
  @spec eval([token()], lookup()) :: {:ok, number()} | :invalid
  def eval(tokens, lookup) when is_list(tokens) and is_function(lookup, 1) do
    case run(tokens, [], lookup) do
      {:ok, [result]} -> finite(result)
      # underflow leaving nothing, or overflow leaving >1 operand: malformed.
      {:ok, _stack} -> :invalid
      :invalid -> :invalid
    end
  catch
    # Any arithmetic error (`:badarith`, `ArithmeticError` from /0 or pow overflow,
    # domain errors from :math) collapses to :invalid rather than crashing the engine.
    _kind, _reason -> :invalid
  end

  def eval(_tokens, _lookup), do: :invalid

  # --- fold the token list over the value stack ---

  defp run([], stack, _lookup), do: {:ok, stack}

  defp run([token | rest], stack, lookup) do
    case step(token, stack, lookup) do
      {:ok, stack} -> run(rest, stack, lookup)
      :invalid -> :invalid
    end
  end

  # const -> push
  defp step(%{"const" => c}, stack, _lookup) when is_number(c), do: {:ok, [c / 1 | stack]}

  # signal -> resolve + push (missing/stale signal => whole eval invalid)
  defp step(%{"signal" => name}, stack, lookup) when is_binary(name) do
    case lookup.(name) do
      {:ok, value} when is_number(value) -> {:ok, [value / 1 | stack]}
      _ -> :invalid
    end
  end

  # unary negate
  defp step(%{"op" => "neg"}, [a | stack], _lookup), do: {:ok, [-a | stack]}

  # binary operators: a op b, with a pushed first => a is DEEPER on the stack.
  defp step(%{"op" => op}, [b, a | stack], _lookup) when op in ["+", "-", "*", "/", "^"] do
    {:ok, [apply_op(op, a, b) | stack]}
  end

  # whitelisted functions, dispatched by name + declared arity (which must match).
  defp step(%{"fn" => name, "arity" => arity}, stack, _lookup)
       when is_binary(name) and is_integer(arity) do
    case Map.get(@arity, name) do
      ^arity -> apply_fn(name, arity, stack)
      _ -> :invalid
    end
  end

  # Anything else (unknown op, bad arity, missing operands -> underflow) is invalid.
  defp step(_token, _stack, _lookup), do: :invalid

  # --- operators (a op b) ---

  defp apply_op("+", a, b), do: a + b
  defp apply_op("-", a, b), do: a - b
  defp apply_op("*", a, b), do: a * b
  defp apply_op("/", a, b), do: a / b
  defp apply_op("^", a, b), do: :math.pow(a, b)

  # --- whitelisted functions (pop `arity`, apply, push) ---

  defp apply_fn("abs", 1, [a | s]), do: {:ok, [abs(a) | s]}
  defp apply_fn("sqrt", 1, [a | s]), do: {:ok, [:math.sqrt(a) | s]}
  defp apply_fn("sin", 1, [a | s]), do: {:ok, [:math.sin(a) | s]}
  defp apply_fn("cos", 1, [a | s]), do: {:ok, [:math.cos(a) | s]}
  defp apply_fn("tan", 1, [a | s]), do: {:ok, [safe_tan(a) | s]}
  defp apply_fn("asin", 1, [a | s]), do: {:ok, [:math.asin(a) | s]}
  defp apply_fn("acos", 1, [a | s]), do: {:ok, [:math.acos(a) | s]}
  defp apply_fn("atan", 1, [a | s]), do: {:ok, [:math.atan(a) | s]}
  defp apply_fn("deg2rad", 1, [a | s]), do: {:ok, [a * :math.pi() / 180.0 | s]}
  defp apply_fn("rad2deg", 1, [a | s]), do: {:ok, [a * 180.0 / :math.pi() | s]}
  defp apply_fn("min", 2, [b, a | s]), do: {:ok, [min(a, b) | s]}
  defp apply_fn("max", 2, [b, a | s]), do: {:ok, [max(a, b) | s]}
  defp apply_fn("atan2", 2, [x, y | s]), do: {:ok, [:math.atan2(y, x) | s]}
  defp apply_fn("hypot", 2, [b, a | s]), do: {:ok, [:math.sqrt(a * a + b * b) | s]}

  # clamp(value, lo, hi): pushed value, lo, hi -> hi on top.
  defp apply_fn("clamp", 3, [hi, lo, value | s]), do: {:ok, [clamp(value, lo, hi) | s]}

  # Underflow (not enough operands for the function) -> invalid.
  defp apply_fn(_name, _arity, _stack), do: :invalid

  # tan blows up near the ±π/2 asymptote; because the argument is rarely EXACTLY at
  # the asymptote it yields a huge-but-finite number rather than an arithmetic error.
  # Treat a near-zero cosine (within a tight epsilon) as a domain error => invalid.
  defp safe_tan(a) do
    c = :math.cos(a)

    if abs(c) < 1.0e-12 do
      # force the eval to :invalid via the finiteness/catch path
      :math.sin(a) / 0.0
    else
      :math.sin(a) / c
    end
  end

  defp clamp(value, lo, hi) when lo <= hi do
    value |> max(lo) |> min(hi)
  end

  # A reversed [lo, hi] is treated permissively (clamp into the implied interval).
  defp clamp(value, lo, hi), do: clamp(value, hi, lo)

  # --- finiteness guard ---

  # On BEAM a float never becomes ±Inf — overflow (`pow`) and division by zero RAISE
  # `ArithmeticError`/`:badarith` (caught in eval/2 → :invalid). The only non-finite
  # float that can survive is NaN, which fails `x == x`.
  defp finite(x) when is_float(x) do
    if x == x, do: {:ok, x}, else: :invalid
  end

  defp finite(x) when is_integer(x), do: {:ok, x / 1}
  defp finite(_), do: :invalid
end
