#!/bin/bash
# vim: syn=sh:expandtab:ts=4:sw=4:

# =========================================================================== CLEANUP

if [ "$1" = "clean" ]
then
  killall vault
  rm -fr etc var #bin
  rm -f nohup.out *.token *.keys *.hcl
  exit
fi

killall vault 2>/dev/null
rm -fr var/vault/

mkdir -p etc/ssl/{certs,keys} etc/vault/plugins var/vault bin

# =========================================================================== INIT/UNSEAL/AUTH

# --------------------------------------------------------------------------- vault binary

if [ ! -f "bin/vault" ]
then
  ver="0.9.0"
  zip="vault_${ver}_linux_amd64.zip"
  url="https://releases.hashicorp.com/vault/$ver/$zip"
  curl -SL "$url" -o "$zip"
  unzip "$zip" -d "bin/"
  rm -f $zip
fi

# --------------------------------------------------------------------------- vault-secrets-gen plugins

if [ ! -f "etc/vault/plugins/vault-secrets-gen" ]
then
  repo="sethvargo/vault-secrets-gen"
  url="https://api.github.com/repos/$repo/releases/latest"
  curl -sSL $url | jq -r '.assets[] | select ( .name | test("linux_amd64.tgz") ) | .browser_download_url' | xargs curl -SL | tar xz -C etc/vault/plugins/
fi

# --------------------------------------------------------------------------- self-signed HTTPS Certificates

key="etc/ssl/keys/vault.key"
crt="etc/ssl/certs/vault.crt"
if [ ! -f "$key" ] || [ ! -f "$crt" ]
then
  openssl x509 \
    -in <(
        openssl req \
            -days 3650 \
            -newkey rsa:4096 \
            -nodes \
            -keyout "$key" \
            -subj "/C=FR/L=Paris/O=frntn/OU=DevOps/CN=vault.local"
        ) \
    -req \
    -signkey "$key" \
    -sha256 \
    -days 3650 \
    -out "$crt" \
    -extfile <(echo -e "basicConstraints=critical,CA:true,pathlen:0\nsubjectAltName=DNS:vault.rocks,IP:127.0.1.1")
fi

export VAULT_SKIP_VERIFY=true

# --------------------------------------------------------------------------- vault server: configuration


cat <<EOF > etc/vault/config.hcl

storage "file" {
  path = "var/vault"
}

listener "tcp" {
  address = "127.0.0.1:8200"
 
  tls_disable = 0
  tls_cert_file = "$crt"
  tls_key_file = "$key"  
}

plugin_directory = "etc/vault/plugins"

disable_mlock = true

api_addr = "https://127.0.0.1:8200"

EOF

# --------------------------------------------------------------------------- vault server: init, unseal, auth

sleep 2
nohup ./bin/vault server -config=etc/vault/config.hcl &
sleep 5

vault init -key-shares=1 -key-threshold=1                  \
    | tee                                                  \
    >(awk '/^Initial Root Token:/{print $4}' > root.token) \
    >(awk '/^Unseal Key/{print $4}' > unseal.keys)

vault unseal $(cat unseal.keys)

vault auth $(cat root.token)

# =========================================================================== PLUGIN SETUP

export SHA256=$(shasum -a 256 "etc/vault/plugins/vault-secrets-gen" | cut -d' ' -f1)

vault write sys/plugins/catalog/secrets-gen sha_256="${SHA256}" command="vault-secrets-gen"

vault mount -path="gen" -plugin-name="secrets-gen" plugin

# =========================================================================== PLUGIN USAGE

vault write -format=json gen/passphrase words=7 | jq -r '.data.value'

echo "
===========================================================================

Usage :

$ export VAULT_SKIP_VERIFY=true

$ ./bin/vault write gen/passphrase separator=' ' words=5

$ ./bin/vault write gen/password length=20 symbols=0

===========================================================================

See https://github.com/sethvargo/vault-secrets-gen
"
