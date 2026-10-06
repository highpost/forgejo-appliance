# Forgejo Appliance for macOS

Forgejo is a powerful and lightweight GitHub clone written in Go. This project is an opinionated blueprint for deploying Forgejo in an OrbStack VM on a Mac using Ubuntu Server, PostgreSQL and the `tsbridge` reverse proxy. The goal is to provide something like a distributed private workgroup server rather than a public website. You can host the appliance on a home/office Mac, and then colleagues can access it from anywhere in the world through Tailscale.

While this blueprint is tailored for Forgejo, it can also serve as a pattern for hosting other server applications like Nextcloud, Wiki.js, BookStack or Jellyfin. Most of the work would be in modifying `forgejo-appliance.yml`.

---

## Deployment Guide

Deploying the appliance involves configuring Tailscale prerequisites (MagicDNS, an OAuth client secret and HTTPS), setting your parameters in `config.env` and `forgejo-appliance.yml` and running `./bootstrap-appliance.sh`. The script automates provisioning the Ubuntu Server VM in OrbStack, setting up PostgreSQL and Forgejo over UNIX sockets, and launching `tsbridge` to securely expose the instance over Tailscale HTTPS.

### Enable Tailscale MagicDNS

MagicDNS automatically maps human-readable hostnames to Tailscale IP addresses across your tailnet (e.g., `YOUR_MACHINE_NAME.YOUR_TAILNET.ts.net`). It allows devices to reach the appliance by name and is required for provisioning Tailscale HTTPS certificates.

* Tailscale Admin Console
* DNS → Enable MagicDNS

### Generate a Tailscale OAuth Client Secret

* Generate an OAuth Client Secret in your Tailscale Admin settings:
  * Tailscale Admin Console
  * Settings → Trust Credentials
  * \+ Credential
    * Description: Forgejo git server
    * Devices>Core
      * Read + Write
      * tag:myservers
    * Keys>Auth Keys
      * Read + Write
* Copy the Client ID into `config.env`.
* Copy the OAuth Client Secret to the system clipboard for the next step.

### Store the Tailscale OAuth Client Secret

An OAuth Client Secret is more secure and convenient than an Auth Key, and it removes the need to rotate an Auth Key, which expires every 90 days.

* Run the secret storage script on your macOS host:
  ```bash
  ./store-ts-oauth-client-secret.sh
  ```
* Paste the OAuth Client Secret from the system clipboard to stdin for the secret storage script.

The secret will be securely stored in the macOS Keychain.

### Enable HTTPS

* Tailscale Admin Console
* Settings → HTTPS (or Certificates)
* enable HTTPS

### Google SMTP Server Setup

Forgejo supports several notification mechanisms including different mail transfer agents. We choose Google SMTP Server because it's bundled with standard Google Workspace subscription plans.

The following procedure uses Google SMTP Server for reliable system notification emails without any unnecessary "on behalf of" or "via" headers:

#### Create an Email Alias

In Google Admin (Directory → Users), select your primary admin account and add an alternate email address (e.g., `forgejo-noreply@example.com`).

#### Generate an App Password

In your Google Account Security panel, ensure 2-Step Verification is active, search for "App Passwords", generate an app password named "Forgejo Appliance" and then save the 16-character value.

NB: Google recently changed their security policy to no longer support the reuse of account passwords for third-party apps or devices. This procedure avoids this new restriction by using unique and secure app passwords, the current recommended best practice.

### Modify the Configuration Files

* `config.env`:
  * **Required:**
    * `TS_OAUTH_CLIENT_ID="YOUR_TAILNET_OAUTH_ID"`
    * `TS_MACHINE_NAME="YOUR_TAILSCALE_MACHINE_NAME"`
    * `TS_TAILNET="YOUR_TAILNET_DOMAIN"`
  * **Optional (for remote backups):**
    * `BORG_REPO="zh1234@zh1234.rsync.net:forgejo-backup"` (see [Optional Backup Guide](#optional-backup-guide))
* `forgejo-appliance.yml`:
  * `[[services]]`
    * `name        = "YOUR_TAILSCALE_MACHINE_NAME"`
    * `hostname    = "YOUR_TAILSCALE_MACHINE_NAME"`
  * `[server]`
    * `DOMAIN      = YOUR_TAILSCALE_MACHINE_NAME.YOUR_TAILNET_DOMAIN`
    * `ROOT_URL    = https://YOUR_TAILSCALE_MACHINE_NAME.YOUR_TAILNET_DOMAIN/`
  * `[mailer]`
    * `USER        = YOUR_GOOGLE_WORKSPACE_ACCOUNT`
    * `PASSWD      = YOUR_GOOGLE_SMTP_PASSWORD`

#### Notes

* Due to constraints imposed by Apple's Security Framework, both `teardown-appliance.sh` and `store-ts-oauth-client-secret.sh` must be run directly from a Mac-based terminal on the host and not remotely through SSH.
* `tsbridge` supports both Auth Keys and OAuth clients for authentication. The primary reasons for this project choosing OAuth over Auth Keys are:
  * `tsbridge` has shifted their recommended best practice toward OAuth.
  * Standard Auth Keys expire (after a maximum of 90 days) and require manual replacement, whereas OAuth provides a permanent hands-off solution. The only notable downside to choosing OAuth is that it causes an incompatibility with Headscale, the open-source Tailscale management server, which currently only supports Auth Keys.
* The Tailscale OAuth Client Secret will not appear in the Apple Passwords app. Use Keychain Access instead.

### Build the Infrastructure

The `bootstrap-appliance.sh` script automates the end-to-end setup of the appliance. At a high level, it creates an Ubuntu Server virtual machine in OrbStack and applies the `cloud-init` configuration in `forgejo-appliance.yml` to install dependencies and configure Forgejo and PostgreSQL.

At the systems level, the script orchestrates host-to-VM integration: it retrieves OAuth credentials and cached WireGuard/TLS state from the macOS Keychain, configures UNIX sockets for local inter-process communication, restores existing application data and database backups, and starts the `tsbridge` reverse proxy to serve Forgejo over Tailscale HTTPS.

```bash
./bootstrap-appliance.sh
```

### Verify the Deployment

Run the automated stress-test to tear down and rebuild the VM multiple times. This validates the Let's Encrypt cache persistence, WireGuard tunnel negotiation and HTTPS certificate routing.

```bash
./test-appliance.sh
```

### Tear down infrastructure

Store the TLS certificate and the Forgejo data. Stop the `tsbridge` reverse proxy.

```bash
./teardown-appliance.sh
```

### Post-Provisioning Operations

Once the appliance is running, you can interact with the Forgejo CLI directly through OrbStack to finalize your setup.

#### Create the Initial Administrator Account

```bash
orb exec -m forgejo-appliance sudo -u forgejo-admin  \
  /home/forgejo-admin/bin/forgejo admin user create  \
  --config /etc/forgejo/app.ini                      \
  --username player1                                 \
  --password "PickATemporaryPassword123"             \
  --email player1@example.com                        \
  --admin
```

#### Send a Test Email

```bash
orb exec -m forgejo-appliance sudo -u forgejo-admin  \
  /home/forgejo-admin/bin/forgejo admin sendmail     \
  --config /etc/forgejo/app.ini                      \
  --title "Infrastructure Test Alert"                \
  --content "Forgejo notifications are successfully reaching your primary routing pool."
```

### Users

| User | Description |
| :--- | :--- |
| `forgejo-admin` | The unprivileged application service account. It runs the internal Forgejo processes and owns the isolated `/var/lib/forgejo` data directories. |
| `*[mirrored-user]*` | The privileged OrbStack hypervisor management account. OrbStack automatically provisions an account with a username that matches the host macOS user running the OrbStack app and then grants it passwordless `sudo` to facilitate host-to-guest automation. It acts as the default context for all `orb` commands. |
| `postgres` | The unprivileged PostgreSQL service account. It runs the database server's background processes, so they can run without full root privileges. It also mirrors the default database superuser account. |
| `root` | The privileged top-level Linux administrative account. It runs the `tsbridge` service and is also necessary for complete system access during Borg backup and restore operations. |

---

## Git Example

Once the appliance is deployed and you have created an account, you can interact with Forgejo exactly as you would with GitHub, use your Tailscale network for secure access. 

Because this appliance explicitly routes traffic over HTTPS via `tsbridge` (and bypasses SSH multiplexing), you will use HTTPS for all git operations. 

To push an existing local repository to your new Forgejo appliance:

```bash
# link your local repository to the Forgejo remote
git remote add origin https://*YOUR_TAILSCALE_MACHINE_NAME*.*YOUR_TAILNET_DOMAIN*/*YOUR_FORGEJO_USERNAME*/*YOUR_REPO*.git

# push your code and set the upstream tracking branch
git push --set-upstream origin main
```

When prompted for credentials by your git client, use your Forgejo username and password or generate a dedicated application token in your Forgejo user settings.

---

## Testing Guide

### Connecting to an OrbStack VM

VM development requires rapid testing and debugging cycles. OrbStack lets you connect directly from a macOS host to a VM without needing SSH. Because `[mirrored-user]` is the default account for OrbStack integration, the `orb` command can be used from your Mac without needing to specify a user flag. Conversely, OrbStack's `mac` interoperability command allows you to execute commands on the macOS host from inside the VM. These commands run natively as the macOS host user running the OrbStack app and their standard output is also mapped to the Ubuntu shell.

```bash
# connect with an interactive shell as [mirrored-user] (default)
orb -m forgejo-appliance

# connect with an interactive shell as forgejo-admin
orb -m forgejo-appliance -u forgejo-admin

# check the health of a specific systemd service
orb exec -m forgejo-appliance systemctl status tsbridge

# inspect recent service logs using passwordless sudo
orb exec -m forgejo-appliance sudo journalctl -u tsbridge.service -n 50 --no-pager
```

NB: SSH is disabled on the Forgejo appliance. So you would normally connect to an OrbStack VM as shown above. To remotely connect to the appliance, first use SSH to connect to the host Mac and then connect to the Forgejo appliance with `orb -m forgejo-appliance`.

### DNS workaround

While iteratively developing and testing a VM image, it's possible to lose connection with the image even though you can ping its IP address, the node appears in `login.tailscale.com/machines` and `orb exec -m forgejo-appliance systemctl status tsbridge` looks good. The problem is often  with the macOS host's MagicDNS service. The workaround is to toggle the Tailscale service on the macOS menu bar on and off.

On the macOS side, you can flush the DNS cache:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

### Stacked Tailscale Nodes

It's possible to get Tailscale into a state where it creates multiple nodes with similar names: `mynode`, `mynode-1`, `mynode-2`, ...visible on `login.tailscale.com/machines`. This leads to incorrect IP address errors.

The solution is to flush the system completely:

- delete all of the related Tailscale nodes
- stop and restart the Tailscale daemon on the Mac host
- `teardown-appliance.sh --purge`

---

## Optional Backup Guide

Local data persistence is built directly into the appliance lifecycle: running `teardown-appliance.sh` dumps the database and file repositories to your macOS host, and `bootstrap-appliance.sh` restores them. Standard VM snapshots will not work because the OrbStack VM is treated as ephemeral.

For automated, encrypted remote disaster recovery, we provide an **optional** [BorgBackup](https://borgbackup.readthedocs.io/) strategy targeting [rsync.net](https://www.rsync.net/).

Borg provides client-side encryption and block-level deduplication. This is efficient for daily database dumps and repository tarballs, since Borg will only upload the exact bytes that change during the day.

### Install [BorgBackup](https://borgbackup.readthedocs.io/)

Install the BorgBackup app on your macOS host:
```bash
brew install borgbackup
```

### Register your repo with your rsync.net account

[rsync.net](https://www.rsync.net/) provides remote cloud storage with native BorgBackup support over SSH. When you sign up, you receive an account identifier (for example, `zh1234`) and a host domain (`zh1234.rsync.net` or a regional hostname).

1. **Configure SSH Key Access:**
   Ensure your macOS host can authenticate to rsync.net via SSH without an interactive password:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub zh1234@zh1234.rsync.net
   ```
   Verify the connection:
   ```bash
   ssh zh1234@zh1234.rsync.net
   ```

2. **Store Passphrase in Apple Keychain:**
   Save your Borg encryption passphrase securely in Apple Keychain using the helper script:
   ```bash
   ./store-borg-passphrase.sh
   ```

3. **Initialize the Remote Borg Backup Repo:**
   Initialize your encrypted repository on rsync.net (you only need to do this once). Replace `zh1234` with your actual rsync.net account username:
   ```bash
   # example for rsync.net account zh1234:
   borg init -e repokey zh1234@zh1234.rsync.net:forgejo-backup
   ```

4. **Configure `BORG_REPO` in `config.env`:**
   Set `BORG_REPO` to point to your rsync.net destination:
   ```bash
   BORG_REPO="zh1234@zh1234.rsync.net:forgejo-backup"
   ```

### Configuring the Retention Policy

You can customize how many snapshots to retain by adjusting the retention settings in `config.env`:

```bash
# granular retention policy (defaults: 7 daily, 4 weekly, 6 monthly)
BORG_KEEP_DAILY=7
BORG_KEEP_WEEKLY=4
BORG_KEEP_MONTHLY=6
BORG_KEEP_YEARLY=""

# or specify a raw override to pass custom flags directly to 'borg prune':
# BORG_RETENTION_POLICY="--keep-within=14d --keep-monthly=12"
```

When `BORG_RETENTION_POLICY` is set, it overrides the individual `BORG_KEEP_*` values.

### Daily Backup Workflow

To back up the Forgejo appliance, you extract the state, push it to [rsync.net](https://rsync.net) and then rebuild the VM. The included `backup-appliance.sh` script automates this workflow:

```bash
./backup-appliance.sh
```

Under the hood, `backup-appliance.sh` executes the following sequence:

1. Safely halts the appliance and extracts data to the macOS host (`./teardown-appliance.sh`).
2. Creates an encrypted, deduplicated snapshot in Borg (`borg create ::{now:%Y-%m-%d} ./forgejo-backup.tar.gz ./forgejo-db.sql`).
3. Cleans up old backups based on the retention policy configured in `config.env` (`borg prune`).
4. Rebuilds the appliance and restores the state (`./bootstrap-appliance.sh`).

### Automating with macOS `launchd`

To run `backup-appliance.sh` automatically every night (e.g., at 02:00), configure a macOS Launch Agent:

1. **Create the Launch Agent:**
   Save the following XML to `~/Library/LaunchAgents/com.forgejo-appliance.backup.plist`. Ensure the `<string>` element contains the absolute path to your script:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.forgejo-appliance.backup</string>
       
       <key>ProgramArguments</key>
       <array>
           <!-- Replace with the absolute path on your macOS host: -->
           <string>/Users/*YOUR_MAC_USERNAME*/*PATH_TO_REPO*/backup-appliance.sh</string>
       </array>
       
       <key>StartCalendarInterval</key>
       <dict>
           <key>Hour</key>
           <integer>2</integer>
           <key>Minute</key>
           <integer>0</integer>
       </dict>
       
       <key>StandardOutPath</key>
       <string>/tmp/forgejo-backup.log</string>
       <key>StandardErrorPath</key>
       <string>/tmp/forgejo-backup.err</string>
   </dict>
   </plist>
   ```

2. **Load the Launch Agent:**
   ```bash
   launchctl load ~/Library/LaunchAgents/com.forgejo-appliance.backup.plist
   ```

By combining `backup-appliance.sh` with a macOS `launchd` job, you achieve a fully automated, encrypted and heavily deduplicated remote backup pipeline.

### Listing and Restoring Remote Backups

You can inspect all available snapshots stored in your remote Borg backup repo:

```bash
./list-remote-backups.sh
```

To restore the appliance, run `restore-appliance.sh` with a snapshot name taken from the output from `list-remote-backups.sh`:

```bash
./restore-appliance.sh <archive_name>
```

For example:
```bash
./restore-appliance.sh 2026-09-02
```

This script safely coordinates the restoration:
1. Validates that the archive exists on the remote repository.
2. Extracts and verifies the backup files in an isolated temporary staging directory before altering the active appliance.
3. Halts the active appliance with `./teardown-appliance.sh` and preserves the current host files as `.bak`.
4. Injects the restored snapshot files and brings the appliance back up with `./bootstrap-appliance.sh`.

### Verify Backups and Restoration

To validate the Borg backup, divergence detection and restoration pipeline end-to-end:

```bash
./test-backup.sh
```

This test is self-contained: it seeds a temporary test user and git repository with commits, creates an encrypted backup in your Borg repository, simulates an unbacked-up mutation, restores from the snapshot, verifies database and Git filesystem integrity and cleans up the test snapshot.

---

## Maintenance Guide

### Software Updates

The Forgejo appliance treats its OrbStack VM as immutable infrastructure. Think of the VM as a strictly defined, purpose-built appliance. It's not meant to be manually administered or patched over time. To prevent configuration drift and ensure stability, we don't perform in-place configuration or upgrades. When it's time to update Forgejo, PostgreSQL or `tsbridge`, you perform a backup,update the source definitions in `forgejo-appliance.yml`, destroy the old environment, deploy a new one and then inject your persisted state (database and Tailscale cache) back into the new environment. These tasks are performed by the `teardown-appliance.sh` and `bootstrap-appliance.sh` scripts.

Software updates follow a simple three-step procedure:

- Update the version numbers/URLs in `forgejo-appliance.yml`.
- Run `teardown-appliance.sh` to store the Forgejo appliance's persistent state and then completely remove the VM.
- Run `bootstrap-appliance.sh` to build a new VM and restore your persistent data (`forgejo-backup.tar.gz` and `forgejo-db.sql`).

---

## Implementation Notes

### Tech Stack

This blueprint relies on a specific set of deployment options chosen for lightweight performance, deep macOS integration and hands-off maintenance:

| Component | Description |
| :--- | :--- |
| **OrbStack** | A lightweight VM/container runtime with native macOS networking and filesystem integration. |
| **Tailscale** | An open source mesh VPN based on WireGuard. |
| **Ubuntu Server** | Provides a complete Linux system environment. |
| **`systemd`** | Orchestrates service lifecycles and UNIX socket dependencies between Forgejo, PostgreSQL and the `tsbridge`. |
| **PostgreSQL** | A relational database server configured with local UNIX socket trust authentication. While Forgejo includes SQLite in its binary, PostgreSQL can gracefully handle concurrent writes, making it a safer and more performant choice for a small to medium-sized server at the footprint cost of about ~150 MB storage and ~100 MB RAM. |
| **`tsbridge`** | A Tailscale-aware reverse proxy. Maps the Tailnet HTTPS ingress layer directly to Forgejo's local UNIX socket. |
| **Apple Keychain** | Native macOS secrets management.
| **Google SMTP** | Maps a Google Workspace email alias to Forgejo for reliable, authenticated outbound system notifications. |

### Files

| File | Description |
| :--- | :--- |
| `config.env` | Configuration variables. |
| `forgejo-appliance.yml` | `cloud-init` YAML file. |
| `LICENSE` | [2-clause BSD license.](https://opensource.org/license/bsd-2-clause) |
| `README.md` | This file. |
| `bootstrap-appliance.sh` | Provisions the VM, injects Tailscale/TLS credentials from Keychain, restores database backups and starts system services. |
| `backup-appliance.sh` | Orchestrates the teardown, Borg encrypted snapshot and prune, and fresh bootstrap cycle. |
| `restore-appliance.sh` | Extracts a specific remote snapshot, safely halts the active appliance, and bootstraps with the restored state. |
| `list-remote-backups.sh` | Lists available snapshot archives in the remote Borg backup repo. |
| `store-ts-oauth-client-secret.sh` | Prompts for and securely stores the Tailscale OAuth Client Secret into the macOS host's Apple Keychain. |
| `store-borg-passphrase.sh` | Prompts for and securely stores the Borg backup repo passphrase into the macOS host's Apple Keychain. |
| `teardown-appliance.sh` | Gracefully halts services, extracts the database and Let's Encrypt certificates to the macOS host and destroys the VM instance. Includes a `--purge` flag for Tailscale node eviction. |
| `test-appliance.sh` | Automates a multi-cycle lifecycle stress test to validate infrastructure resilience, network convergence and database persistence. |
| `test-backup.sh` | Automates end-to-end backup, state divergence, and restoration verification with self-seeded test users and Git repositories. |
| `forgejo-backup.tar.gz` | The filesystem state. Contains the raw git repository data, user avatars, release attachments, git LFS (Large File Storage) objects and the Forgejo `app.ini` configuration file. |
| `forgejo-db.sql` | The relational state. Contains user accounts, repository metadata, issues, pull requests, comments, webhooks, SSH public keys and application tokens. |

### Secrets Management with Apple Keychain

The appliance stores its sensitive credentials in the macOS Apple Keychain. `bootstrap-appliance.sh` then injects these credentials into the VM during provisioning. This enables the VM to automatically join your Tailnet and obtain a TLS certificate from Let's Encrypt without requiring manual intervention. These same files are used by `teardown-appliance.sh` to cleanly remove the VM from Tailscale and remove the Let's Encrypt certificate.

We maintain three Keychain items:

| Keychain Item | Variable | Type | Description |
| :--- | :--- | :--- | :--- |
| `tsbridge-oauth-secret` | `$TS_OAUTH_SECRET_KEY` | Operator-Managed | Tailscale OAuth client secret used by `tsbridge` to automatically authenticate the appliance to your tailnet (stored via `store-ts-oauth-client-secret.sh`). |
| `borg-passphrase` | `$BORG_PASSPHRASE_KEY` | Operator-Managed | Passphrase used by Borg to encrypt and decrypt offsite backup snapshots on rsync.net (stored via `store-borg-passphrase.sh`). |
| `tsbridge-state-cache` | `$TS_STATE_CACHE` | Appliance-Managed | Runtime cryptographic state from `/var/lib/tsbridge`: bundles the **WireGuard node private key** (prevents MagicDNS collisions) and the **ACME TLS certificate & key** (avoids Let's Encrypt rate limits). Managed automatically by `bootstrap-appliance.sh` and `teardown-appliance.sh`. |

Due to macOS sandbox restrictions, a guest VM cannot directly query its host for credentials.

#### Why Store Runtime Cryptography in Keychain?

* **Zero Filesystem Exposure:** Because `/var/lib/tsbridge` contains unencrypted private keys, writing them to the host filesystem as loose files would risk accidental commits to Git. Storing them encrypted at rest in Apple Keychain keeps private keys off the host disk entirely.
* **Extreme Efficiency:** `teardown-appliance.sh` tar-compresses and base64-encodes the entire cryptographic state into a tiny ~90-byte payload. On boot, `bootstrap-appliance.sh` decodes it back into the fresh VM in milliseconds.
* **Lifecycle Purge:** When you want a clean slate, running `./teardown-appliance.sh --purge` evicts the machine from Tailscale and deletes this Keychain item automatically.

NB: Let's Encrypt enforces a **Duplicate Certificate limit of 5 certificates per rolling 7 days** for identical hostnames. Standard runs of `teardown-appliance.sh` preserve the existing TLS certificate in Keychain to avoid burning through this quota. However, if you repeatedly teardown with `--purge` and re-bootstrap in rapid succession, `tsbridge` requests a brand new certificate each time and can trigger this limit.

If you suspect you have hit this threshold:
1. Search your node's fully qualified MagicDNS domain (e.g., `*YOUR_MACHINE_NAME*.*YOUR_TAILNET*.ts.net`) on [crt.sh](https://crt.sh) to inspect the public Certificate Transparency logs and view recent issuance timestamps.
2. If you have exceeded the 5-certificate limit, either wait for the oldest certificate in the rolling 7-day window to age out, or temporarily rename `TS_MACHINE_NAME` in `config.env` and `forgejo-appliance.yml` to request a certificate under a fresh hostname.

### MagicDNS Collision Mitigation

When tearing down a VM, Tailscale's global MagicDNS table holds an active lease on the hostname for a few minutes. Spinning up a new VM too quickly causes a collision, resulting in a `-1` suffix appended to the hostname (e.g., `forgejo-appliance-1`). `teardown-appliance.sh` has a `--purge` command-line option which adds the necessary 3-minute delay to guarantee a clean slate.

### Why PostgreSQL instead of SQLite?

While SQLite is incredibly fast and compiled directly into the Forgejo binary (requiring zero setup), it relies on file-level locking for database writes. If two users push code concurrently, or a user pushes code while a background worker is updating an issue tracker, SQLite can throw database is locked errors.

PostgreSQL uses Multi-Version Concurrency Control (MVCC) and row-level locking. For a database server expected to handle concurrent git operations and CI/CD API polling, PostgreSQL provides guaranteed transactional stability without sacrificing data integrity. The extra footprint (~100 MB RAM) is a reasonable price to pay for the added reliability.

---

## Limitations

* **Git Transport Protocols**: Like GitHub, Forgejo supports multiple git transport protocols. This blueprint supports git operations over HTTPS. Git over SSH requires configuration changes that are beyond the scope of this appliance.

---

## See Also

- https://github.com/highpost/tailscale-macos-container
- https://github.com/highpost/tailscale-macos-vm

---

## Future Work
* **CI/CD**: Continuous Integration (Forgejo Actions) requires a separate sidecar VM.
* **Database**: Turso could make a better match for Forgejo than PostgreSQL.
