defmodule Kazi.ReadModel.SchemaSkewTest do
  @moduledoc "T52.2 (ADR-0068 decision 3): the client-side schema-skew classification."
  use ExUnit.Case, async: true

  alias Kazi.ReadModel.SchemaSkew

  test "client_newer when the client's binary_version exceeds the daemon's schema_vsn" do
    assert SchemaSkew.classify(20_260_710_000_000, 20_260_709_210_000) == :client_newer
  end

  test "client_older when the client's binary_version is below the daemon's schema_vsn" do
    assert SchemaSkew.classify(20_260_709_210_000, 20_260_710_000_000) == :client_older
  end

  test "equal when they match" do
    assert SchemaSkew.classify(20_260_709_210_000, 20_260_709_210_000) == :equal
  end
end
