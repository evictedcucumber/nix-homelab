# A self-signed certificate for a service that needs one to start and doesn't make its own.
# It names the container, and its address on the host and on the LAN if it has one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.container.tls;
  inherit (config.container) address lanAddress;
  openssl = lib.getExe pkgs.openssl;
  checkAddress = if lanAddress != null then lanAddress else address;
in
{
  options.container.tls = {
    service = lib.mkOption {
      type = lib.types.str;
      example = "ntfy-sh";
      description = "The systemd service that gets the certificate before it starts.";
    };
    directory = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/ntfy-sh";
      description = "Where the certificate is kept, as tls.crt and tls.key.";
    };
    certFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${cfg.directory}/tls.crt";
    };
    keyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${cfg.directory}/tls.key";
    };
  };

  config.systemd.services.${cfg.service}.preStart = ''
    umask 077

    # Made again when it's about to expire, or the host's address changes.
    certificate_valid() {
      [ -s ${cfg.keyFile} ] &&
        ${openssl} x509 -in ${cfg.certFile} -noout -checkend 2592000 > /dev/null &&
        ${openssl} x509 -in ${cfg.certFile} -noout -checkip ${checkAddress} > /dev/null
    }
    if ! certificate_valid; then
      ${openssl} req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj /CN=${config.networking.hostName} -keyout ${cfg.keyFile} -out ${cfg.certFile} \
        -addext basicConstraints=critical,CA:FALSE -addext keyUsage=digitalSignature \
        -addext extendedKeyUsage=serverAuth \
        -addext "subjectAltName=DNS:${config.networking.hostName},DNS:localhost,IP:127.0.0.1,IP:${address}${
          lib.optionalString (lanAddress != null) ",IP:${lanAddress}"
        }"
    fi
  '';
}
