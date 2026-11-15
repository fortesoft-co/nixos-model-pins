# Option surface for cfg.model-pins — everything a consumer can set, in
# one place. Implementation (manifest composition, unit generation,
# assertions) lives in ./model-pins.nix, which imports this file.
#
# Layout:
#   cfg.model-pins.instances.<name>                 one pin root + pipeline
#     dataDir user group unitPrefix                identity + placement
#     tokenFiles                                   per-source tokens
#     downloads.<id>                               the pin set (see below)
#     enforce verifySchedule requiresMounts        policy + scheduling
#     consumedBy workflowsDir jobs                 wiring + tuning
#   cfg.model-pins.instances.<name>.downloads.<id>  built by sources.nix
#     sha256 dest tokenFile                        the pin, link, secret
#     transport urls provenance                    set by the constructor
#     unzipInto inPlace kind name                  non-store handling
#
# Source-specific fields (Hugging Face repo/rev, Civitai versionId, …)
# are constructor arguments in ./sources.nix, not options here.
#   cfg.model-pins.pinManifestFiles                 set by the module
#   cfg.model-pins.civitaiCli                       set by the flake (internal)
{ lib, ... }:
{
  options = {
    cfg.model-pins.pinManifestFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Set by this module — do not assign. The resolved pin manifest per
        instance (nix store path of <unitPrefix>-pins.json): the read-only
        provenance surface for consumers (reporting, update checks), so
        they never duplicate manifest composition.
      '';
    };

    cfg.model-pins.civitaiCli = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      internal = true;
      description = ''
        The civitai CLI used for token-authenticated Civitai downloads.
        Set automatically by this flake's nixosModules.model-pins (from
        its civitai-cli input); null, e.g. when importing
        modules/model-pins.nix directly, means Civitai entries always
        download over curl.
      '';
    };

    cfg.model-pins.instances = lib.mkOption {
      description = ''
        Independent pin stores. Each instance is one pin root plus one
        fetch/install/verify pipeline with its own identity, policy, schedule
        and consumer binding; instances share nothing but the runtime
        binary. Consumers read stores through the links with no
        permission coordination. See AGENTS.md for the full contract.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              dataDir = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The pin root: blobs at <dataDir>/store, work area at
                  <dataDir>/.pinwork, links at each entry's dataDir-relative
                  dest. One root per instance — two instances sharing a
                  dataDir is an eval-time error, not a use case.
                '';
              };
              user = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Who runs the fetch/verify passes; owns the work area and
                  the link trees. Reading the store never requires being
                  this user (or in its group).
                '';
              };
              group = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Group for the work area and link trees — write
                  collaboration by foreign tools arranging the tree.
                  Defaults to the instance user. Consumers reading through
                  the links need neither: blobs are world-readable 0444.
                '';
              };
              unitPrefix = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = ''
                  Unit name prefix: <unitPrefix>-models-fetch /
                  -models-install / -models-verify. Defaults to the instance
                  name; distinct per instance (unit names must not collide).
                '';
              };
              tokenFiles = lib.mkOption {
                type = lib.types.submodule {
                  options = lib.genAttrs [ "huggingface" "civitai" ] (
                    source:
                    lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Token file for ${source} entries without their own tokenFile.";
                    }
                  );
                };
                default = { };
                description = ''
                  Per-source token files, read at fetch time (never stored
                  in the nix closure): hfFetch entries use huggingface,
                  civitaiFetch entries use civitai, unless the entry sets
                  its own tokenFile. urlFetch entries have no default.
                '';
              };
              downloads = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options = {
                      urls = lib.mkOption {
                        type = lib.types.nonEmptyListOf lib.types.str;
                        description = ''
                          Curl URLs, tried in order until one yields bytes
                          matching sha256: the primary route for "url"
                          entries, the fallback for the others. Filled in
                          by the constructors in modules/sources.nix
                          (hfFetch, civitaiFetch, urlFetch): build entries
                          with those rather than setting this.
                        '';
                      };
                      transport = lib.mkOption {
                        type = lib.types.submodule {
                          freeformType = lib.types.attrsOf (lib.types.either lib.types.str lib.types.int);
                          options.type = lib.mkOption {
                            type = lib.types.enum [
                              "url"
                              "huggingface"
                              "civitai"
                            ];
                            default = "url";
                            description = "Which downloader the fetch pass uses.";
                          };
                        };
                        default = { };
                        description = ''
                          How the fetch pass downloads this entry: "huggingface"
                          uses `hf download`, "civitai" uses the civitai CLI
                          (when a token is set), "url" uses curl. The other
                          attributes are the tool's arguments (repo/rev/file,
                          versionId, …). urls is the curl fallback. Filled in by
                          the constructors — you don't set this yourself.
                        '';
                      };
                      provenance = lib.mkOption {
                        type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.int);
                        default = { };
                        description = ''
                          Where the file came from (source, repo/rev, versionId,
                          …), recorded in the manifest and the blob's sidecar for
                          reporting and update checks. Filled in by the
                          constructors; never used for placement.
                        '';
                      };
                      sha256 = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                          The pin gate: expected sha256 of the fetched bytes
                          (64 hex). Placement names blobs by it; nothing
                          lands unverified.
                        '';
                      };
                      dest = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                          dataDir-relative link destination — a plain path,
                          no leading or trailing /, no .. segments. The
                          store places the blob and links it here.
                        '';
                      };
                      tokenFile = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                          File whose contents are read at fetch time (never
                          stored in the nix closure) and sent as a bearer
                          token — only to the source's own hosts, never to
                          mirrors. null: the instance's tokenFiles default
                          for this entry's source.
                        '';
                      };
                      unzipInto = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                          Legacy extraction: the fetched file is treated as
                          a ZIP and extracted into this dataDir-relative
                          directory (plain-file entries stay unverified
                          between passes; the archive stays on disk).
                          Implies inPlace.
                        '';
                      };
                      inPlace = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = ''
                          Keep a real file at dest instead of a link into
                          the store: fetched and verified straight to the
                          dest, never deduplicated. Implied by unzipInto.
                        '';
                      };
                      kind = lib.mkOption {
                        type = lib.types.nullOr (lib.types.enum [ "workflow" ]);
                        default = null;
                        description = ''
                          "workflow": install into the instance's
                          workflowsDir read-only namespace instead of the
                          store — dest must sit under it. Files land 0444,
                          dirs re-locked 0555 every pass, dropped pins'
                          content is removed.
                        '';
                      };
                      name = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                          For kind = "workflow" single-file pins: the
                          placed file name (default: the URL's last path
                          segment, else the entry key).
                        '';
                      };
                    };
                  }
                );
                default = { };
                description = ''
                  The pin set: entries keyed by id, each a sha-gated
                  resumable download and a link destination inside
                  dataDir. Build entries with the constructors in
                  modules/sources.nix, e.g.
                  downloads.main = model-pins.lib.hfFetch { … };
                '';
              };
              enforce = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Reconcile pinned destinations: wrong or missing links to
                  existing store blobs are relinked; a drifted real file is
                  quarantined only after its verified replacement lands.
                  False: existing files/links at pinned paths are reported
                  and left exactly as found.
                '';
              };
              verifySchedule = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  systemd OnCalendar for <unitPrefix>-models-verify — the
                  fetch pass plus a full store sweep (every blob re-measured
                  against the digest in its name; orphans and
                  unrecognized files listed, never deleted). null disables
                  the unit and its timer.
                '';
              };
              requiresMounts = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Mount units the passes require (e.g. the ZFS mount a
                  store lives on) — passes wait for them and stop with
                  them.
                '';
              };
              consumedBy = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Consumer units: each requires the fetch/install passes and
                  starts after them (its pinned files are guaranteed
                  placed). Empty: the passes activate at boot on their
                  own.
                '';
              };
              workflowsDir = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Optional dataDir-relative read-only directory for
                  pinned workflows: kind = "workflow" entries install
                  into it. It is re-locked 0555 between passes; content no
                  longer claimed by a pin is removed (bytes stay in the
                  consumer's git history). null: no namespace — workflow
                  entries then fail at eval.
                '';
              };
              jobs = lib.mkOption {
                type = lib.types.int;
                default = 8;
                description = ''Parallel hash workers for the fetch/verify passes.'';
              };
            };
          }
        )
      );
      default = { };
    };
  };
}
