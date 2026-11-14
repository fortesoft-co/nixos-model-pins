#!/usr/bin/env sh
# Eval harness: renders a dummy instance through a real nixosSystem eval
# and prints the generated units, tmpfiles rules, manifest path and
# assertions — the option surface and unit wiring in one shot. Override
# the nixpkgs with NIXPKGS (a flake ref; must be resolvable locally for
# offline runs).
set -eu

NIXPKGS="${NIXPKGS:-github:NixOS/nixpkgs/nixpkgs-unstable}"
here=$(cd "$(dirname "$0")" && pwd)

nix eval --impure --json --expr "
let
  np = builtins.getFlake \"$NIXPKGS\";
  sys = np.lib.nixosSystem {
    system = \"x86_64-linux\";
    modules = [
      (import $here/../modules/model-pins.nix)
      {
        cfg.model-pins.instances.demo = {
          dataDir = \"/tmp/model-pins-eval\";
          user = \"nobody\";
          downloads.fixture = (import $here/../modules/sources.nix).hfFetch {
            repo = \"example/fixture\";
            rev = \"0000000000000000000000000000000000000000\";
            file = \"fixture.gguf\";
            sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\";
            dest = \"llm/fixture.gguf\";
          };
        };
      }
    ];
  };
in {
  fetch = sys.config.systemd.services.demo-models-fetch.serviceConfig.ExecStart;
  install = sys.config.systemd.services.demo-models-install.serviceConfig.ExecStart;
  fetchWantedBy = sys.config.systemd.services.demo-models-fetch.wantedBy;
  verifyUnitExists = builtins.hasAttr \"demo-models-verify\" sys.config.systemd.services;
  manifest = sys.config.cfg.model-pins.pinManifestFiles.demo;
  tmpfiles = sys.config.systemd.tmpfiles.rules;
  # length only: forcing every assertion *message* breaks on base
  # modules whose messages reference undefined attrs in minimal evals
  assertionCount = builtins.length sys.config.assertions;
  ctor = (import $here/../modules/sources.nix).urlFetch {
    url = \"https://example.com/fixture.gguf\";
    sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\";
    dest = \"llm/fixture.gguf\";
  };
}"
echo
echo "EVAL TEST PASSED"
