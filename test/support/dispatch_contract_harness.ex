defmodule Kazi.Test.DispatchContractHarness do
  @moduledoc false

  def write!(root) do
    path = Path.join(root, "worker.sh")

    File.write!(path, """
    #!/bin/sh
    set -eu
    root=$(CDPATH= cd "$(dirname "$0")" && pwd)
    n=$(cat "$root/count" 2>/dev/null || echo 0)
    n=$((n+1))
    echo "$n" > "$root/count"
    printf '%s' "$2" > "$root/prompt.$n"
    touch "$root/first"
    if test "$n" -ge 2; then touch "$root/done"; fi
    printf '{"result":"fixture repair"}\\n'
    """)

    File.chmod!(path, 0o755)
    path
  end
end
