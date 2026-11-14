# nixos-model-pins

Declaratively pin AI model files on NixOS. You list the files you want
(from Hugging Face, Civitai, or a plain URL), each pinned to a sha256.
At boot, systemd downloads them and verifies every byte. Each file is
stored once, read-only, and symlinked to wherever your service (ComfyUI,
llama.cpp, ollama, …) expects to find it.

## Why not `fetchurl` / the Nix store?

Model weights are often many gigabytes each. Fetching them into the Nix
store puts them in every closure, and garbage collection treats them like
any other build output. They also don't fit the Nix workflow well: they
may need an API token, a download may need to resume, and the consuming
service wants them at a specific path in its own data directory. This
module keeps them **out of the Nix store**, while staying declarative:

- **The right downloader, automatically:** Hugging Face files come
  down with `hf download` (Xet transfers, revision pinning, resume).
  Civitai files use the official civitai CLI when you give a token, and
  the public download endpoint otherwise. Plain URLs use curl. If a
  platform tool fails, the download falls back to resumable curl. You
  never pick a tool: the module ships them, and only adds them to
  instances that need them.
- **Pinned:** the sha256 is the gate. A download that doesn't match is
  discarded, and a stored file is named by its measured hash.
- **Deduplicated and read-only:** blobs live once in `<dataDir>/store`,
  `0444 root:root`. Any service user can read them through the links,
  with no permissions to coordinate.
- **Conflict-safe:** existing files are never overwritten. A file that
  has changed is moved to quarantine only after a verified replacement
  has landed. Unpinned blobs are listed, never deleted.
- **Secrets stay yours:** tokens are read from a file you provide at
  download time. They never enter the Nix store and never appear on a
  process command line (curl gets them on stdin, `hf` and `civitai`
  through their token environment variables).

## Usage

```nix
inputs.model-pins.url = "github:fortesoft-co/nixos-model-pins";
```

```nix
{ model-pins, ... }:
{
  imports = [ model-pins.nixosModules.model-pins ];

  cfg.model-pins.instances.example = {
    dataDir = "/srv/example-models";   # pin root: store + link trees
    user = "example";                  # runs downloads, owns link dirs
    consumedBy = [ "example.service" ];  # starts after its files are placed
    downloads = {
      main = model-pins.lib.hfFetch {
        repo = "<org>/<repo>";
        rev = "<commit sha>";          # pin the repo revision, not a branch
        file = "<file>.gguf";
        sha256 = "<64-hex>";
        dest = "llm/<file>.gguf";      # relative to dataDir
        # tokenFile = "/run/secrets/<token>";  # gated repos
      };
      # also: model-pins.lib.civitaiFetch { versionId; sha256; dest; ... }
      #       model-pins.lib.urlFetch     { url; sha256; dest; ... }
    };
  };
}
```

To get a `sha256`: Hugging Face shows it on each LFS file's page, and
the Civitai API returns it for each file of a model version. Otherwise,
run `sha256sum` on a copy you trust.

## What you get per instance

Units are named after the instance by default (`unitPrefix` overrides
this):

```
example-models-fetch.service    as the instance user: relink what's
                                already stored, download what's missing
                                (hf / civitai CLI / curl), verify sha256,
                                stage it for install
example-models-install.service  as root, no network: re-verify, place
                                blobs 0444 root:root, write provenance
                                sidecars, create the symlinks
example-models-verify.service   opt-in via verifySchedule (timer): the
                                fetch pass plus a re-hash of every
                                stored blob; orphans listed, never
                                removed
```

With `consumedBy`, each listed unit requires fetch and install and starts
after them. If a pin fails, the pass fails, and so does the consumer's
start, so a service never runs against a missing model. Without
`consumedBy`, the passes run at boot on their own. To run them by hand:
`systemctl start example-models-fetch example-models-install`.

## More

- Full behaviour contract: the module docstring of
  `tools/download_runtime.py`.
- Option reference: `modules/options.nix`.
- Contributing: `AGENTS.md`. Tests are `tests/functional.sh` (hermetic
  runtime cycle) and `tests/eval.sh` (option surface + unit rendering).

## License

[AGPL-3.0-or-later](LICENSE).
