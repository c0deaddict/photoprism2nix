{ photoprismModule }:
{ ... }:
let photoprismPort = 8080;
in
{
  nodes.machine = { config, pkgs, ... }:
  {
    imports = [ photoprismModule ];
    services.photoprism = {
      enable = true;
      port = photoprismPort;
    };
  };

  testScript = ''
    machine.wait_for_open_port(${toString photoprismPort})
    machine.succeed("curl -f http://localhost:${toString photoprismPort}")
  '';
}
