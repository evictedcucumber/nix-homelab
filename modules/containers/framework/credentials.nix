# Secrets a container gets as system credentials, because its dynamic UID range hides
# who owns a file on the host. A new value restarts the container to load it.
{ config, lib, ... }:
let
  host = config;
in
{
  options.containers = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options.credentials = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "example-password" ];
            description = "Names of sops secrets to load into the container, under the same names.";
          };

          config = {
            extraFlags = map (id: "--load-credential=${id}:${host.sops.secrets.${id}.path}") config.credentials;
            config.container = { inherit (config) credentials; };
          };
        }
      )
    );
  };

  config.sops.secrets = lib.mkMerge (
    lib.mapAttrsToList (
      name: c:
      lib.genAttrs c.credentials (_: {
        restartUnits = [ "container@${name}.service" ];
      })
    ) config.containers
  );
}
