{
  description = "Declaratively pinned AI model files for NixOS: sha256-verified Hugging Face / Civitai / URL downloads at boot, stored once outside the nix store, read-only, and symlinked where your services expect them.";

  # The official civitai CLI: the transport for token-authenticated
  # Civitai downloads. Wired in by nixosModules.model-pins below, so
  # consumers never configure it.
  inputs.civitai-cli.url = "github:civitai/cli";

  outputs =
    { self, civitai-cli }:
    {
      lib = import ./modules/sources.nix;
      nixosModules = {
        # The key makes the module system import this once, however many
        # consumers (nixos-comfyui, nixos-llm, …) bring it into one system.
        # Have them all follow one nixos-model-pins input.
        model-pins = {
          key = "nixos-model-pins";
          imports = [
            ./modules/model-pins.nix
            (
              { lib, pkgs, ... }:
              {
                cfg.model-pins.civitaiCli = lib.mkDefault (
                  civitai-cli.packages.${pkgs.stdenv.hostPlatform.system}.default or null
                );
              }
            )
          ];
        };
        default = self.nixosModules.model-pins;
      };
    };
}
