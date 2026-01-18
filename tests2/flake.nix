{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # bad
    # home-manager.url = "github:nix-community/home-manager/de448dcb577570f2a11f243299b6536537e05bbe";
    home-manager.url = "github:nix-community/home-manager";
    # good
    # home-manager.url = "github:nix-community/home-manager/reenable-gcroot-maintenance";
    # home-manager.url = "github:nix-community/home-manager/e4bf85da687027cfc4a8853ca11b6b86ce41d732";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, home-manager, ... }: let
      system = "x86_64-linux";
    in {
      checks."${system}" = let
        pkgs = import nixpkgs { inherit system; };
      in {
        foo = pkgs.testers.runNixOSTest ({ ... }: {
          name = "foo";
          testScript = { nodes, ... }: ''
            machine.wait_for_unit("default.target")
            machine.wait_for_unit("default.target", user="alice")

            machine.succeed("stat /home/alice/.config")
            machine.succeed("stat /home/alice/.config/foo")

            machine.succeed("${nodes.machine.system.build.toplevel}/specialisation/bar/bin/switch-to-configuration switch")

            machine.succeed("stat /home/alice/.config/bar")
            machine.fail("stat /home/alice/.config/foo")
          '';

          nodes.machine = { lib, ... }: {
            imports = [
              home-manager.nixosModules.home-manager
            ];

            users.users.alice = {
              group = "alice";
              isNormalUser = true;
              linger = true;
            };
            users.groups.alice = {};

            home-manager.users.alice = lib.mkDefault ({ config, ... }: {
              home.stateVersion = config.home.version.release;
              xdg.configFile.foo.text = "content of foo";
            });

            specialisation.bar = {
              configuration = {
                home-manager.users.alice = ({ config, ... }: {
                  home.stateVersion = config.home.version.release;
                  xdg.configFile.bar.text = "content of bar";
                });
              };
            };
          };
        });
      };
    };
}
