# AGENTS.md

Rules and instructions for agents and humans contributing to this
repository: a NixOS module for declaratively pinned AI model files
(Hugging Face, Civitai, plain URLs). Files are downloaded at boot outside
the nix store, sha256-verified, and kept in a content-addressed pin
store per instance, with consumer-defined link destinations and a
per-instance systemd service set (fetch/install/verify).

## Content rules (hard — apply to every commit)

- **Content-free by policy.** No pins, model names, host paths, users,
  secrets, or any consumer content lives here: everything with a host
  or content assumption belongs to the consumer repo that declares an
  instance. This repo ships machinery only.
- **No NSFW-related content may be authored or committed** — not in
  code, string literals, names, examples, docs, or commit messages.
  When in doubt, use innocuous language.
- The repo's history is part of the repo: every rule above applies to
  commit messages too.

## Scratchpad

`.scratch/` (gitignored) is the local scratchpad: throwaway scripts,
working notes. Local-only — never commit it, never reference it from
tracked files.

## Module map

```
flake.nix              lib (hfFetch/civitaiFetch/urlFetch constructors) +
                       nixosModules.model-pins, which wires in the
                       civitai-cli input (consumers never configure tools)
modules/options.nix    cfg.model-pins.* option surface — every option a
                       consumer can set, with types and docs
modules/model-pins.nix implementation (imports options.nix): manifest
                       composition, assertions, unit generation — one
                       instance = one pin root + one
                       fetch/install/verify pipeline
modules/sources.nix    the download sources, one constructor each
                       (hfFetch/civitaiFetch/urlFetch): owns every
                       source-specific field and resolves it to the core
                       entry (transport + urls + provenance) — the
                       core module never sees repo/rev/versionId. New
                       source = new constructor.
                       tokenFile is an explicit caller argument (secret
                       wiring stays consumer-side)
tools/download_runtime.py  the runtime; its module docstring is the full
                       store-law contract
tests/                 eval.sh (option surface + unit rendering) and
                       functional.sh (hermetic ensure→seal→audit cycle)
```

Consumers (nixos-comfyui's wrapper, a future LLM pin module) declare
instances: what to pin (`downloads`), where links land (each entry's `dest`,
dataDir-relative), who runs the pipeline (user/group), and which
services consume it (consumedBy). Dest conventions, token secret
wiring, and reporting/update-checking are consumer concerns — the
manifest + sidecar provenance surfaces are the util's stable interface
toward a future monitoring surface.

## Store law

`tools/download_runtime.py`'s docstring is the full contract. Summary:

```
blob    = <dataDir>/store/<stem>--<sha256><ext>   (0444, root:root)
sidecar = <blob>.pin.json                          provenance, not load-bearing
link    = absolute symlink at the entry's dataDir-relative dest
```

One instance = one pin root + one fetch/install/verify pipeline; two
instances sharing a dataDir is an eval-time assertion, not a use case.
Reading a store needs no permission coordination — blobs are
world-readable 0444 and links sit in traversable dirs. Instance
ownership answers only "who runs the pipeline, and who may write in
the link trees."

## Golden rules

1. **systemd owns the services.** Units are generated per instance;
   consumers never hand-manage them. `consumedBy` is the only consumer
   coupling.
2. **Install is the only privileged step.** It does placement +
   ownership only, no network I/O; fetch and verify run as the instance
   user.
3. **The flake only sees tracked files.** After creating any file the
   eval must see: `git add` it first, or evaluation fails with "not
   tracked by Git".
4. **Conflict-safe everywhere.** Existing files are never overwritten;
   drift is repaired only after a verified replacement lands; impostors
   are parked in quarantine. Nothing is deleted on spec — verify lists
   orphans, never removes them.
5. **Keep host values in consumers.** Pins, paths, users, secrets,
   schedules: all instance config, all consumer-side.
6. **Store-law compatibility is load-bearing.** Blob naming, the
   manifest entry shape, and the runtime's ensure/seal/audit CLI
   (driven by the fetch/install/verify units) are contracts
   other repos (nixos-comfyui) already depend on — change them
   deliberately, never incidentally.

## Testing

```
tests/functional.sh    hermetic runtime cycle (no network, no nix, no root)
tests/eval.sh          option surface + unit rendering via nixosSystem;
                       NIXPKGS=<flake ref> to pin the eval nixpkgs
```

Both must pass before any consumer integration work.
