defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test],
      deps: deps()
    ]
  end

  defp deps do
    [
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
