# Download sources: one constructor per place a model can come from.
# This file owns everything source-specific: each constructor takes its
# source's own fields (repo/rev, versionId, …) and returns the core entry
# shape of cfg.model-pins.instances.<name>.downloads.<id>
# (modules/options.nix):
#   transport   how the fetch pass downloads it — the platform's own tool
#               when there is one (see "Transports" below)
#   urls        the plain-curl route: the source's own URL, then mirrors
#   provenance  what it is, for the manifest and the blob's sidecar
# The core module never reads repo, rev or versionId; the runtime reads
# them from transport only to call the platform tool.
#
# Transports (chosen automatically — consumers never configure them):
#   hfFetch       `hf download` (huggingface_hub + hf-xet: Xet chunked
#                 transfers, revision pinning, resume); curl on the
#                 resolve URL only if hf fails
#   civitaiFetch  the official civitai CLI when a tokenFile is set (its
#                 downloads require auth), pinned with --version; without
#                 a token, or if the CLI fails, curl on the public
#                 download endpoint (the CLI doesn't resume; curl does)
#   urlFetch      curl
# Whatever the route, the bytes must hash to sha256 before placement.
#
# Adding a source = adding a constructor here; nothing in the core
# changes. Missing fields are ordinary Nix errors at the call site
# ("called without required argument 'rev'").
#
# Pure functions, no nixpkgs: the token file path is an explicit caller
# argument, so per-host secret wiring stays in the consumer (AGENTS.md).
#
# Shared arguments (every constructor):
#   sha256        the pin: expected sha256 of the bytes (64 hex)
#   dest          dataDir-relative link destination
#   tokenFile     file holding a bearer token, read at download time
#   fallbackUrls  mirrors tried in order after the source's own URL
#   inPlace, unzipInto, kind, name   non-store placement (see
#                 modules/options.nix)
let
  # drop null-valued attrs (provenance records only what was given)
  compact =
    attrs:
    builtins.listToAttrs (
      builtins.filter (kv: kv.value != null) (
        map (n: {
          name = n;
          value = attrs.${n};
        }) (builtins.attrNames attrs)
      )
    );

  entry =
    {
      url,
      transport,
      provenance,
      sha256,
      dest,
      tokenFile ? null,
      fallbackUrls ? [ ],
      inPlace ? false,
      unzipInto ? null,
      kind ? null,
      name ? null,
    }:
    {
      urls = [ url ] ++ fallbackUrls;
      transport = compact transport;
      provenance = compact provenance;
      inherit
        sha256
        dest
        tokenFile
        inPlace
        unzipInto
        kind
        name
        ;
    };
in
{
  # Hugging Face file pinned to a repo commit (rev). Downloaded with
  # `hf download`; the curl fallback is
  #   https://huggingface.co/<repo>/resolve/<rev>/<file>
  # tokenFile covers gated repos and is harmless on ungated ones.
  hfFetch =
    {
      repo,
      rev,
      file,
      ...
    }@args:
    entry (
      removeAttrs args [
        "repo"
        "rev"
        "file"
      ]
      // {
        url = "https://huggingface.co/${repo}/resolve/${rev}/${file}";
        transport = {
          type = "huggingface";
          inherit repo rev file;
        };
        provenance = {
          source = "huggingface";
          inherit repo rev file;
        };
      }
    );

  # Civitai model version via the download endpoint
  #   https://civitai.com/api/download/models/<versionId>[?fileId=<id>]
  # Always pinned to versionId: the CLI downloads exactly that version
  # (never the model card's current default).
  #   fileId (optional)   a specific member of a multi-file version;
  #                       omitted fetches the primary file
  #   file (optional)     that member's file name: selects it for the CLI
  #                       when fileId is absent (curl can only select by
  #                       fileId, so prefer setting fileId)
  #   modelId (optional)  the model-page id; lets update checkers skip
  #                       their version-id resolution hop
  civitaiFetch =
    {
      versionId,
      fileId ? null,
      file ? null,
      modelId ? null,
      ...
    }@args:
    let
      # int or string accepted — normalized so urls and manifests see str
      version = toString versionId;
    in
    entry (
      removeAttrs args [
        "versionId"
        "fileId"
        "file"
        "modelId"
      ]
      // {
        url =
          "https://civitai.com/api/download/models/${version}"
          + (if fileId != null then "?fileId=${toString fileId}" else "");
        transport = {
          type = "civitai";
          versionId = version;
          inherit fileId file;
        };
        provenance = {
          source = "civitai";
          versionId = version;
          inherit fileId file modelId;
        };
      }
    );

  # Plain pinned URL on any host.
  urlFetch =
    { url, ... }@args:
    entry (
      args
      // {
        transport.type = "url";
        provenance = {
          source = "url";
          inherit url;
        };
      }
    );
}
