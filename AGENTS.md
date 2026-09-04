## project stack

* macOS (Apple Silicon host), OrbStack (Ubuntu VM, ARM64), systemd, Forgejo, PostgreSQL, Tailscale (tsbridge) and UNIX sockets

## build, test and lifecycle commands

* **bootstrap:** `./bootstrap-appliance.sh`
* **backup:** `./backup-appliance.sh`
* **restore:** `./restore-appliance.sh <archive_name>`
* **list remote backups:** `./list-remote-backups.sh`
* **test / lifecycle verification:** `./test-appliance.sh`
* **teardown (preserve state):** `./teardown-appliance.sh`
* **teardown (purge TS node and certs):** `./teardown-appliance.sh --purge`
* **store TS secret in Keychain:** `./store-ts-oauth-client-secret.sh`
* **store Borg passphrase in Keychain:** `./store-borg-passphrase.sh`
* **status:** `orb list`

## code style and scripting conventions

* **host scripts:** Write automation in `#!/bin/zsh` with `setopt ERR_EXIT` (and `setopt PIPE_FAIL` where appropriate).
* **configuration:** Centralize configurable properties in `config.env`.
* **logging:** Use helper functions from `utils.sh` (`log_info`, `log_err`).
* **service orchestration:** Use `systemd` for in-VM service orchestration and lifecycle management.
* **VM provisioning:** Use declarative `cloud-init` (`forgejo-appliance.yml`) for initial environment, users and package setup.
* **socket IPC:** Prefer UNIX sockets over TCP/IP ports for all inter-process communication.
* **idempotency:** Keep all scripts idempotent; assume the VM is ephemeral and built from scratch.

## architecture and state management

* **black box model:** No SSH access to the appliance. Interact only via Tailscale/`tsbridge` HTTPS or `orb exec` for orchestration.
* **target architecture:** `linux/arm64` binaries (Forgejo, `tsbridge`) for Apple Silicon host.
* **socket IPC paths:** Localize UNIX sockets in the VM filesystem (`/run/forgejo/forgejo.sock` and `/var/run/postgresql`).
* **ephemeral appliance state:** The VM is immutable. Persistent state is restored/dumped across lifecycles:
  * **Tailscale state and TLS certs:** Cached in Apple Keychain (`$TS_CERT_CACHE`).
  * **app data and repositories:** Archived in `forgejo-backup.tar.gz`.
  * **database:** Dumped in `forgejo-db.sql`.
* **Tailscale DNS leases:** Allow sufficient convergence time (~3 min on `--purge`) when deleting nodes via API to prevent MagicDNS hostname collision suffixes.

## boundaries and security

* **secrets management:** Never hardcode secrets in scripts or `.env` files. Read from Apple Keychain on the macOS host and inject into the VM via `orb exec`.
* **networking:** Never expose TCP/IP ports externally. Use `tsbridge` for all ingress traffic over Tailscale HTTPS.
* **identity:** Use Tailscale OAuth clients rather than static auth keys for appliance network identity.

## git workflow

* **GitHub Flow:** Use `main` as the production branch. Create feature branches for all new work.
* **branch naming:** Use `type/short-description` (e.g., `feat/infra-hardening`).
* **commit messages:** Use conventional commits (`feat:`, `fix:`, `chore:`, `docs:`).
* **PRs:** Open a PR to `main` for every feature branch.
* **merging:** Squash merge only.
