defmodule Agento.Hub.InstallServiceTest do
  @moduledoc """
  The configuration `scripts/install-service.tcl` writes must be one
  `Agento.Hub.Config` accepts. The script's own behaviour is covered by
  `test/tcl/install_service_test.tcl`.
  """

  use ExUnit.Case, async: true

  alias Agento.Hub.Config

  @tag :tmp_dir
  test "the hub.edn the installer generates loads, with its client and default host", %{
    tmp_dir: prefix
  } do
    tclsh = System.find_executable("tclsh")

    {output, 0} =
      System.cmd(
        tclsh,
        ["scripts/install-service.tcl", "--prefix", prefix, "--default-host", "big.local"],
        env: [{"AGENTO_INSTALL_BUILD_CMD", "true"}],
        stderr_to_stdout: true
      )

    path = Path.join(prefix, ".config/agento/hub.edn")
    assert {:ok, config} = Config.load(path)

    assert [%{name: "claude-code", token: token}] = config.clients
    assert config.default_host == "big.local"
    assert config.data_dir == Path.join(prefix, ".local/share/agento")
    assert output =~ "ANTHROPIC_AUTH_TOKEN=#{token}"
  end
end
