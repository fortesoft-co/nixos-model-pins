# model-pins — declaratively pinned AI model files (Hugging Face, Civitai,
# plain URLs) for NixOS services. Downloads happen at boot, outside the
# nix store; every file is sha256-gated, stored once, read-only, and
# symlinked where the consuming service expects it. Any number of
# independent instances, each with its own pin root, pipeline identity,
# service set and consumer binding.
#
# This file is the implementation; the option surface lives in
# ./options.nix.
#
# One instance = one pin root + one pipeline:
#
#   <unitPrefix>-models-fetch    service user, oneshot   relink / download /
#                                                         verify / stage
#   <unitPrefix>-models-install  root, oneshot, offline   measure, place 0444,
#                                                         link
#   <unitPrefix>-models-verify   service user, timer      fetch + full store
#                                                         re-hash; runs before
#                                                         install, which places
#                                                         what it staged
#
# Store law (tools/download_runtime.py's docstring is the full contract):
#   blob    = <dataDir>/store/<stem>--<sha256><ext>   (0444, root:root)
#   sidecar = <blob>.pin.json                         provenance, not load-bearing
#   link    = absolute symlink at the entry's dataDir-relative dest
#
# Consumers declare what they want pinned (downloads) and where the links
# land (dest, inside the instance's pin root) — the module does the rest.
# Reading a store needs no permission coordination: blobs are 0444
# root:root and links sit in traversable dirs, so any service user can
# consume any store. Instance ownership answers only "who runs the
# pipeline, and who may write in the link trees."
#
# Structural note (discharge-cycle rule): the outer config is a STATIC
# attrset whose values map over cfg.model-pins.instances; the instances
# attrset is never read in the config *spine* (mkMerge list position,
# list concatenations). Discharge forces a config's spine when walking
# option paths — a spine-level read of the instances option would
# re-enter the very merge it is asking for. Reads inside values are
# forced when the receiving option merges, which is cycle-free: this
# module defines nothing under cfg.model-pins.instances.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  runtime = pkgs.writers.writePython3Bin "download-runtime" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./../tools/download_runtime.py);
  storeBin = "${runtime}/bin/download-runtime";

  # Download tools reach the units through the systemd `path` option —
  # pinned nix store dirs, never the ambient host PATH. curl is always
  # there (url entries + every fallback); a platform tool joins only when
  # an instance has entries of its transport, so curl-only instances
  # don't pay for it. Hashing is in-process.
  hfEnv = pkgs.python3.withPackages (ps: [
    ps.huggingface-hub
    ps.hf-xet
  ]);
  civitaiCli = config.cfg.model-pins.civitaiCli;
  usesTransport = icfg: t: lib.any (dl: dl.transport.type == t) (lib.attrValues icfg.downloads);
  toolPathFor =
    icfg:
    [ pkgs.curl ]
    ++ lib.optional (usesTransport icfg "huggingface") hfEnv
    ++ lib.optional (usesTransport icfg "civitai" && civitaiCli != null) civitaiCli;

  # dataDir-relative path sanity: plain, no absolute paths or traversal.
  relOk =
    s:
    s != ""
    && !lib.hasPrefix "/" s
    && !lib.hasSuffix "/" s
    && !lib.any (seg: seg == "..") (lib.filter (seg: seg != "") (lib.splitString "/" s));

  # ── manifest composition ──
  # Source-agnostic: the constructors in ./sources.nix already resolved
  # each entry to urls + provenance; this only shapes the manifest row.
  entryOf = key: dl: {
    id = key;
    inherit (dl)
      kind
      dest
      sha256
      tokenFile
      unzipInto
      name
      provenance
      ;
    urls = lib.unique (lib.filter (u: u != "") dl.urls);
    # manifest compat (rule 6): the mirrors after the source's own URL
    fallbackUrls = lib.drop 1 dl.urls;
    # inPlace: fetched straight to the dest, no store placement. The
    # manifest key stays "legacy" (store-law compat, rule 6).
    legacy = dl.inPlace || dl.unzipInto != null;
    transport = dl.transport;
  };

  # ── per-instance generation, applied as static config values ──────────
  # (see the structural note in the header: reads of the instances
  # attrset live inside these values, never in the config spine)
  mkInstance =
    name: icfg:
    let
      prefix = icfg.unitPrefix;
      group = if icfg.group != null then icfg.group else icfg.user;
      toolPath = toolPathFor icfg;
      entries = lib.mapAttrsToList entryOf icfg.downloads;
      pinManifest = pkgs.writeText "${prefix}-pins.json" (builtins.toJSON entries);

      destsList = map (e: e.dest) entries;
      dupDests = lib.filter (d: lib.length (lib.filter (x: x == d) destsList) > 1) (
        lib.unique destsList
      );
      badDests = lib.filter (d: !relOk d) destsList;
      badSha = lib.filter (e: builtins.stringLength e.sha256 != 64) entries;
      wfPins = lib.filter (e: e.kind == "workflow") entries;

      wfpinsArg = lib.optionalString (icfg.workflowsDir != null) " --wfpins ${icfg.workflowsDir}";

      # Stores with consumers are pulled by them (they Require the passes
      # and start after them); consumer-less stores activate at boot.
      activation =
        if icfg.consumedBy != [ ] then
          {
            before = icfg.consumedBy;
            requiredBy = icfg.consumedBy;
          }
        else
          { wantedBy = [ "multi-user.target" ]; };
    in
    {
      inherit name;
      assertions = [
        {
          assertion = dupDests == [ ];
          message = "model-pins instance \"${name}\": duplicate destinations (${lib.concatStringsSep ", " dupDests}) — every entry must resolve to a distinct file";
        }
        {
          assertion = badDests == [ ];
          message = "model-pins instance \"${name}\": dests must be dataDir-relative plain paths — no leading or trailing /, no .. (${lib.concatStringsSep ", " badDests})";
        }
        {
          assertion = badSha == [ ];
          message = "model-pins instance \"${name}\": every entry must pin a 64-hex sha256 (${lib.concatStringsSep ", " (map (e: e.id) badSha)})";
        }
        {
          assertion = icfg.workflowsDir == null || relOk icfg.workflowsDir;
          message = "model-pins instance \"${name}\": workflowsDir must be dataDir-relative — no leading or trailing /, no ..";
        }
        {
          assertion = icfg.workflowsDir != null || wfPins == [ ];
          message = "model-pins instance \"${name}\": kind = \"workflow\" entries need the instance's workflowsDir";
        }
      ];
      tmpfiles = [
        # The .pinwork area belongs to the instance user; tmpfiles owns it
        # at every activation, so a root-owned stray can never wedge the
        # unprivileged boot pass with EACCES.
        "d ${icfg.dataDir}/.pinwork 0755 ${icfg.user} ${group} - -"
        "d ${icfg.dataDir}/.pinwork/staging 0755 ${icfg.user} ${group} - -"
        "d ${icfg.dataDir}/.pinwork/quarantine 0755 ${icfg.user} ${group} - -"
      ];
      services = {
        "${prefix}-models-fetch" = {
          description = "Fetch pinned models (relink, download, verify, stage for install)";
          after = icfg.requiresMounts;
          requires = icfg.requiresMounts;
          path = toolPath;
          serviceConfig = {
            Type = "oneshot";
            User = icfg.user;
            TimeoutStartSec = 0;
            ExecStart = "${storeBin} ensure --manifest ${pinManifest} --dataDir ${icfg.dataDir}${wfpinsArg} --jobs ${toString icfg.jobs}${lib.optionalString (!icfg.enforce) " --no-enforce"}";
          };
        } // activation;
        "${prefix}-models-install" = {
          description = "Install pinned models (root: measure, place read-only, link)";
          after =
            icfg.requiresMounts
            ++ [ "${prefix}-models-fetch.service" ]
            ++ lib.optionals (icfg.verifySchedule != null) [ "${prefix}-models-verify.service" ];
          requires = icfg.requiresMounts;
          path = [ ]; # placement only: no download tools, no network
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            TimeoutStartSec = "15min";
            ExecStart = "${storeBin} seal --manifest ${pinManifest} --dataDir ${icfg.dataDir} --link-owner ${icfg.user}:${group}";
          };
        } // activation;
        "${prefix}-models-verify" = lib.mkIf (icfg.verifySchedule != null) {
          description = "Verify pinned models (fetch + full store re-hash + orphan report)";
          # Verify stages like fetch does, then install (ordered after both)
          # places what it staged — so verify is ordered *before* install,
          # never after it (mutual After= is an ordering cycle). Ordering
          # after fetch, rather than Conflicts=, makes a timer firing
          # mid-boot wait for an in-flight download instead of killing it;
          # the two never write the work area concurrently.
          after = icfg.requiresMounts ++ [ "${prefix}-models-fetch.service" ];
          requires = icfg.requiresMounts;
          path = toolPath;
          wants = [ "${prefix}-models-install.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = icfg.user;
            TimeoutStartSec = 0;
            ExecStart = "${storeBin} audit --manifest ${pinManifest} --dataDir ${icfg.dataDir}${wfpinsArg} --jobs ${toString icfg.jobs}${lib.optionalString (!icfg.enforce) " --no-enforce"}";
          };
        };
      };
      timers = lib.optionalAttrs (icfg.verifySchedule != null) {
        "${prefix}-models-verify" = {
          description = "Scheduled verification of pinned models";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = icfg.verifySchedule;
            Persistent = true;
            Unit = "${prefix}-models-verify.service";
          };
        };
      };
      manifest = pinManifest;
    };
in
{
  imports = [ ./options.nix ];

  config =
    let
      instances = config.cfg.model-pins.instances;
      parts = lib.mapAttrsToList mkInstance instances;
    in
    {
      assertions =
        [
          {
            assertion =
              let
                dataDirs = lib.mapAttrsToList (_: i: i.dataDir) instances;
              in
              lib.filter (d: lib.length (lib.filter (x: x == d) dataDirs) > 1) (lib.unique dataDirs)
              == [ ];
            message =
              let
                dataDirs = lib.mapAttrsToList (_: i: i.dataDir) instances;
                dup = lib.filter (d: lib.length (lib.filter (x: x == d) dataDirs) > 1) (
                  lib.unique dataDirs
                );
              in
              "model-pins: one pipeline per pin root — instances must not share a dataDir (shared: ${lib.concatStringsSep ", " dup})";
          }
          {
            assertion =
              let
                prefixes = lib.mapAttrsToList (_: i: i.unitPrefix) instances;
              in
              lib.filter (t: lib.length (lib.filter (x: x == t) prefixes) > 1) (lib.unique prefixes)
              == [ ];
            message =
              let
                prefixes = lib.mapAttrsToList (_: i: i.unitPrefix) instances;
                dup = lib.filter (t: lib.length (lib.filter (x: x == t) prefixes) > 1) (
                  lib.unique prefixes
                );
              in
              "model-pins: unit names are derived from unitPrefix — instances must not share one (shared: ${lib.concatStringsSep ", " dup})";
          }
        ]
        ++ lib.concatLists (map (p: p.assertions) parts);
      systemd.tmpfiles.rules = lib.concatLists (map (p: p.tmpfiles) parts);
      systemd.services = lib.mergeAttrsList (map (p: p.services) parts);
      systemd.timers = lib.mergeAttrsList (map (p: p.timers) parts);
      cfg.model-pins.pinManifestFiles = lib.listToAttrs (
        map (p: lib.nameValuePair p.name (toString p.manifest)) parts
      );
    };
}
