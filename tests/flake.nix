# this is a separate flake to so home-manager isn't made a compulsory input.

{
  description = "quadlet-nix tests";

  # inputs path to be set in --override-input
  inputs = {
    nixpkgs.url = "path:/dev/null";

    quadlet-nix.url = "path:..";

    home-manager.url = "path:/dev/null";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    test-config.url = "path:/dev/null";
  };

  outputs =
    { test-config, nixpkgs, home-manager, quadlet-nix, ... }: let
      system = test-config.system;
      makeTestScript = { podmanUser, systemdUser, testScript }: { nodes, ... }: ''
        import json
        from typing import Any, Optional

        podman_user = ${podmanUser}
        systemd_user = ${systemdUser}

        def _run_as_user(command: str, *, user: Optional[str]) -> str:
          if user is not None:
            command = f"sudo -u {user} -- {command}"
          return machine.succeed(command)

        def get_containers(*, user: Optional[str] = podman_user) -> dict[str, dict[str, Any]]:
          containers = json.loads(_run_as_user("podman ps --format=json", user=user))
          return {name: container for container in containers for name in container["Names"]}

        def get_networks(*, user: Optional[str] = podman_user) -> dict[str, dict[str, Any]]:
          networks = json.loads(_run_as_user("podman network ls --format=json", user=user))
          return {network["name"]: network for network in networks}

        def get_pods(*, user: Optional[str] = podman_user) -> dict[str, dict[str, Any]]:
          pods = json.loads(_run_as_user("podman pod ls --format=json", user=user))
          return {pod["Name"]: pod for pod in pods}

        def switch_to_specialisation(specialisation: str) -> str:
          return machine.succeed(f"${nodes.machine.system.build.toplevel}/specialisation/{specialisation}/bin/switch-to-configuration test")

        machine.wait_for_unit("default.target", user=None)
        if systemd_user is not None:
          machine.wait_for_unit("default.target", user=systemd_user)

        ${testScript}
      '';

      runRootfulTest = { name, testConfig, testScript, specialisation, pkgs }: pkgs.testers.runNixOSTest ({ ... }: {
        name = name + "-rootful";
        testScript = makeTestScript {
          systemdUser = "None";
          podmanUser = "None";
          inherit testScript;
        };

        node.specialArgs.testType = "rootful";
        nodes.machine = { pkgs, ... }@attrs: {
          imports = [
            quadlet-nix.nixosModules.quadlet
            testConfig
          ];
          environment.systemPackages = [ pkgs.curl ];
          specialisation = builtins.mapAttrs (name: value: { configuration = value; }) (specialisation attrs);
        };
      });

      runRootlessTest = { name, testConfig, testScript, specialisation, pkgs }: let
        typesToPatch = [
          "builds"
          "containers"
          "images"
          "networks"
          "pods"
          "volumes"
        ];
        patchedTestConfig = pkgs.lib.mirrorFunctionArgs testConfig ({ config, ... }@args: let
          original = testConfig args;
          patchType = builtins.mapAttrs (_: value: value // { rootlessConfig.uid = 1357; });
          patchConfig = cfg: cfg // builtins.listToAttrs (
            map (type: { name = type; value = patchType cfg.${type} or { }; }) typesToPatch);
        in
          pkgs.lib.recursiveUpdate original {
            virtualisation.quadlet = patchConfig original.virtualisation.quadlet;
          }
        );

      in pkgs.testers.runNixOSTest ({ ... }: {
        name = name + "-rootless";
        testScript = makeTestScript {
          systemdUser = "None";
          podmanUser = "\"alice\"";
          inherit testScript;
        };

        node.specialArgs.testType = "rootless";
        nodes.machine = { pkgs, ... }@attrs: {
          imports = [
            quadlet-nix.nixosModules.quadlet
            patchedTestConfig
          ];
          environment.systemPackages = [ pkgs.curl ];
          specialisation = builtins.mapAttrs (name: value: { configuration = value; }) (specialisation attrs);

          users.users.alice = {
            uid = 1357;
            group = "alice";
            linger = true;
            autoSubUidGidRange = true;
            isNormalUser = true;
          };
          users.groups.alice = {
            gid = 2468;
          };
        };
      });

      runHomeManagerTest = { name, testConfig, testScript, specialisation, pkgs }: pkgs.testers.runNixOSTest ({ ... }: {
        name = name + "-home-manager";
        testScript = makeTestScript {
          systemdUser = "\"alice\"";
          podmanUser = "\"alice\"";
          inherit testScript;
        };

        nodes.machine = { lib, pkgs, ... }@attrs: {
          imports = [
            quadlet-nix.nixosModules.quadlet
            home-manager.nixosModules.home-manager
          ];
          virtualisation.quadlet.enable = true;
          environment.systemPackages = [ pkgs.curl ];

          # brings up network-online.target
          systemd.targets.test-network = {
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];
          };

          users.users.alice = {
            group = "alice";
            linger = true;
            autoSubUidGidRange = true;
            isNormalUser = true;
          };
          users.groups.alice = {};

          home-manager.extraSpecialArgs.testType = "home-manager";
          home-manager.users.alice = lib.mkDefault ({ config, ... }: {
            imports = [
              quadlet-nix.homeManagerModules.quadlet
              testConfig
            ];
            home.stateVersion = config.home.version.release;
          });

          specialisation = builtins.mapAttrs (name: value: {
            configuration = {
              home-manager.users.alice = ({ config, ... }: {
                imports = [
                  quadlet-nix.homeManagerModules.quadlet
                  testConfig
                  value
                ];
                home.stateVersion = config.home.version.release;
              });
            };
          }) (specialisation attrs);
        };
      });

      genTest = pkgs: runTest: file: let
        name = pkgs.lib.removeSuffix ".nix" (builtins.baseNameOf file);
        value = ({ testConfig, testScript, specialisation ? _: { } }: runTest {
          inherit name pkgs testConfig testScript specialisation;
        }) (import file);
      in {
        name = value.config.name;
        inherit value;
      };

    in {
      checks = let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        tests = builtins.listToAttrs (map ({ runner, base }: genTest pkgs runner base) (lib.cartesianProduct {
          base = [
            ./basic.nix
            ./build.nix
            ./container.nix
            ./image.nix
            ./network.nix
            ./pod.nix
            ./volume.nix
            ./switch.nix
            ./raw.nix
            ./health.nix
            ./escaping.nix
            ./overriding.nix
          ];
          runner = [
            runRootfulTest
            runRootlessTest
            runHomeManagerTest
          ];
        }));
      in {
        "${system}" = tests;
      };
    };
}
