defmodule NauticNet.Compute.ExprTest do
  use ExUnit.Case, async: true

  alias NauticNet.Compute.Expr

  # A signal-lookup function that resolves names against a static map. Returns
  # {:ok, value} for present signals and :error for absent ones (so the evaluator
  # can mark the whole expression INVALID on a missing signal).
  defp lookup(map) do
    fn name ->
      case Map.fetch(map, name) do
        {:ok, v} -> {:ok, v}
        :error -> :error
      end
    end
  end

  describe "constants and signals" do
    test "a lone constant pushes and returns" do
      assert {:ok, 2.0} = Expr.eval([%{"const" => 2.0}], lookup(%{}))
    end

    test "a signal token resolves the current signal value" do
      assert {:ok, 7.5} = Expr.eval([%{"signal" => "apparent_wind_speed"}], lookup(%{"apparent_wind_speed" => 7.5}))
    end

    test "a missing signal makes the whole evaluation invalid" do
      assert :invalid = Expr.eval([%{"signal" => "boat_speed"}], lookup(%{}))
    end

    test "the worked example: apparent_wind_speed * 2" do
      rpn = [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}]
      assert {:ok, 15.0} = Expr.eval(rpn, lookup(%{"apparent_wind_speed" => 7.5}))
    end
  end

  describe "binary operators with correct operand order (a op b, a pushed first)" do
    test "subtraction is a - b" do
      rpn = [%{"const" => 10.0}, %{"const" => 3.0}, %{"op" => "-"}]
      assert {:ok, 7.0} = Expr.eval(rpn, lookup(%{}))
    end

    test "division is a / b" do
      rpn = [%{"const" => 10.0}, %{"const" => 4.0}, %{"op" => "/"}]
      assert {:ok, 2.5} = Expr.eval(rpn, lookup(%{}))
    end

    test "addition" do
      assert {:ok, 5.0} = Expr.eval([%{"const" => 2.0}, %{"const" => 3.0}, %{"op" => "+"}], lookup(%{}))
    end

    test "multiplication" do
      assert {:ok, 6.0} = Expr.eval([%{"const" => 2.0}, %{"const" => 3.0}, %{"op" => "*"}], lookup(%{}))
    end

    test "exponentiation uses :math.pow (a ^ b)" do
      assert {:ok, 8.0} = Expr.eval([%{"const" => 2.0}, %{"const" => 3.0}, %{"op" => "^"}], lookup(%{}))
    end

    test "division by zero is invalid" do
      assert :invalid = Expr.eval([%{"const" => 1.0}, %{"const" => 0.0}, %{"op" => "/"}], lookup(%{}))
    end
  end

  describe "unary neg" do
    test "neg pops one and negates" do
      assert {:ok, -4.0} = Expr.eval([%{"const" => 4.0}, %{"op" => "neg"}], lookup(%{}))
    end
  end

  describe "whitelisted functions" do
    test "abs arity 1" do
      assert {:ok, 3.0} = Expr.eval([%{"const" => -3.0}, %{"fn" => "abs", "arity" => 1}], lookup(%{}))
    end

    test "sqrt arity 1" do
      assert {:ok, 3.0} = Expr.eval([%{"const" => 9.0}, %{"fn" => "sqrt", "arity" => 1}], lookup(%{}))
    end

    test "sqrt of a negative number is a domain error -> invalid" do
      assert :invalid = Expr.eval([%{"const" => -1.0}, %{"fn" => "sqrt", "arity" => 1}], lookup(%{}))
    end

    test "deg2rad and rad2deg round-trip" do
      assert {:ok, rad} = Expr.eval([%{"const" => 180.0}, %{"fn" => "deg2rad", "arity" => 1}], lookup(%{}))
      assert_in_delta rad, :math.pi(), 1.0e-9

      assert {:ok, deg} = Expr.eval([%{"const" => :math.pi()}, %{"fn" => "rad2deg", "arity" => 1}], lookup(%{}))
      assert_in_delta deg, 180.0, 1.0e-9
    end

    test "sin operates in radians" do
      rpn = [%{"const" => :math.pi() / 2}, %{"fn" => "sin", "arity" => 1}]
      assert {:ok, v} = Expr.eval(rpn, lookup(%{}))
      assert_in_delta v, 1.0, 1.0e-9
    end

    test "asin domain error is invalid" do
      assert :invalid = Expr.eval([%{"const" => 2.0}, %{"fn" => "asin", "arity" => 1}], lookup(%{}))
    end

    test "acos domain error is invalid" do
      assert :invalid = Expr.eval([%{"const" => 2.0}, %{"fn" => "acos", "arity" => 1}], lookup(%{}))
    end

    test "tan near pi/2 (non-finite) is invalid" do
      assert :invalid = Expr.eval([%{"const" => :math.pi() / 2}, %{"fn" => "tan", "arity" => 1}], lookup(%{}))
    end

    test "min/max arity 2" do
      assert {:ok, 2.0} = Expr.eval([%{"const" => 2.0}, %{"const" => 5.0}, %{"fn" => "min", "arity" => 2}], lookup(%{}))
      assert {:ok, 5.0} = Expr.eval([%{"const" => 2.0}, %{"const" => 5.0}, %{"fn" => "max", "arity" => 2}], lookup(%{}))
    end

    test "atan2 arity 2 (y, x)" do
      rpn = [%{"const" => 1.0}, %{"const" => 1.0}, %{"fn" => "atan2", "arity" => 2}]
      assert {:ok, v} = Expr.eval(rpn, lookup(%{}))
      assert_in_delta v, :math.pi() / 4, 1.0e-9
    end

    test "hypot arity 2" do
      assert {:ok, 5.0} =
               Expr.eval([%{"const" => 3.0}, %{"const" => 4.0}, %{"fn" => "hypot", "arity" => 2}], lookup(%{}))
    end

    test "clamp arity 3 (value, lo, hi)" do
      rpn = [%{"const" => 12.0}, %{"const" => 0.0}, %{"const" => 10.0}, %{"fn" => "clamp", "arity" => 3}]
      assert {:ok, 10.0} = Expr.eval(rpn, lookup(%{}))

      rpn2 = [%{"const" => -5.0}, %{"const" => 0.0}, %{"const" => 10.0}, %{"fn" => "clamp", "arity" => 3}]
      assert {:ok, v} = Expr.eval(rpn2, lookup(%{}))
      assert_in_delta v, 0.0, 1.0e-9

      rpn3 = [%{"const" => 5.0}, %{"const" => 0.0}, %{"const" => 10.0}, %{"fn" => "clamp", "arity" => 3}]
      assert {:ok, 5.0} = Expr.eval(rpn3, lookup(%{}))
    end
  end

  describe "defensive against malformed token lists (should not happen from a valid compile)" do
    test "stack underflow is invalid" do
      assert :invalid = Expr.eval([%{"op" => "+"}], lookup(%{}))
    end

    test "leftover operands (overflow) is invalid" do
      assert :invalid = Expr.eval([%{"const" => 1.0}, %{"const" => 2.0}], lookup(%{}))
    end

    test "an empty token list is invalid" do
      assert :invalid = Expr.eval([], lookup(%{}))
    end

    test "an unknown op is invalid (never evaluated dynamically)" do
      assert :invalid = Expr.eval([%{"const" => 1.0}, %{"const" => 2.0}, %{"op" => "%"}], lookup(%{}))
    end

    test "an unknown fn is invalid" do
      assert :invalid = Expr.eval([%{"const" => 1.0}, %{"fn" => "system", "arity" => 1}], lookup(%{}))
    end

    test "a non-finite result (e.g. overflow via pow) is invalid" do
      rpn = [%{"const" => 1.0e308}, %{"const" => 10.0}, %{"op" => "^"}]
      assert :invalid = Expr.eval(rpn, lookup(%{}))
    end
  end
end
