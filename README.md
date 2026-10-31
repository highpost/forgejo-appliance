# Forgejo Git Appliance for macOS

Forgejo is a powerful and lightweight GitHub clone written in Go. This project is an opinionated blueprint for deploying Forgejo in an OrbStack VM on a Mac using Ubuntu Server, PostgreSQL and the `tsbridge` reverse proxy. The goal is to provide something like a distributed private workgroup server rather than a public website. You can host the appliance on a home/office Mac, and then colleagues can access it from anywhere in the world through Tailscale.

While this blueprint is tailored for Forgejo, it can also serve as a pattern for hosting other server applications like Nextcloud, Wiki.js, BookStack or Jellyfin. Most of the work would be in modifying `forgejo-appliance.yml`.

---

## Deployment Guide

Deploying the appliance involves configuring Tailscale prerequisites (MagicDNS, an OAuth client secret and HTTPS), setting some parameters in `config.env` and `forgejo-appliance.yml` and then running `./bootstrap-appliance.sh`. That script automates provisioning Ubuntu Server in an OrbStack VM, setting up PostgreSQL and Forgejo over UNIX sockets, and launching `tsbridge` to securely expose the instance over Tailscale HTTPS.

### `tsbridge` Configuration

#### Enable Tailscale MagicDNS

MagicDNS automatically maps human-readable hostnames to Tailscale IP addresses across your tailnet (e.g., `YOUR_MACHINE_NAME.YOUR_TAILNET.ts.net`). It allows devices to reach the appliance by name and is required for provisioning Tailscale HTTPS certificates.

1. Tailscale Admin Console
2. Navigate to DNS → Enable MagicDNS

#### Generate a Tailscale OAuth Client Secret

1. Generate an OAuth Client Secret in your Tailscale Admin settings:
  a. Tailscale Admin Console
  b. Settings → Trust Credentials
  c. \+ Credential
     * Description: Forgejo git server
     * Devices>Core
       * Read + Write
       * tag:myservers
     * Keys>Auth Keys
       * Read + Write
2. Copy the Client ID into `config.env`.
3. Copy the OAuth Client Secret to the system clipboard for the next step.

#### Store the Tailscale OAuth Client Secret

`store-ts-oauth-client-secret.sh` securely stores a Tailscale OAuth Client Secret in the macOS Keychain:

1. Run the secret storage script on your macOS host:
   ```bash
   ./store-ts-oauth-client-secret.sh
   ```
2. Paste the OAuth Client Secret from the system clipboard to stdin for the secret storage script.

#### Enable HTTPS

The Forgejo appliance relies on `tsbridge` to terminate TLS traffic and proxy requests directly to Forgejo's local UNIX socket (`/run/forgejo/forgejo.sock`). Enabling HTTPS in your Tailscale account is required so that `tsbridge` can acquire valid TLS certificates on demand without exposing ports 80 or 443 to the public internet or requiring complex ACME DNS challenges. All web traffic and git operations over HTTPS depend on this feature.

In the [Tailscale Admin Console](https://login.tailscale.com/admin):
1. Navigate to **DNS** and locate the **HTTPS Certificates** section (or **Settings** → **Certificates** / **HTTPS**).
2. Click **Enable HTTPS Certificates**.

### Modify the Configuration Files

* `config.env`:
  * **Required:**
    * `TS_OAUTH_CLIENT_ID="YOUR_TAILNET_OAUTH_ID"`
    * `TS_MACHINE_NAME="YOUR_TAILSCALE_MACHINE_NAME"`
    * `TS_TAILNET="YOUR_TAILNET_DOMAIN"`
    * `FORGEJO_ADMIN_EMAIL="YOUR_ADMIN_EMAIL"`
  * **Optional (for remote backups):**
    * `BORG_REPO="zh1234@zh1234.rsync.net:forgejo-backup"` (see [Optional Backup Guide](#optional-backup-guide))
* `forgejo-appliance.yml`:
  * `tsbridge.toml` section:
    * `[[services]]`
      * `name        = "YOUR_TAILSCALE_MACHINE_NAME"`
      * `hostname    = "YOUR_TAILSCALE_MACHINE_NAME"`
  * `app.ini` section:
    * `[server]`
      * `DOMAIN      = YOUR_TAILSCALE_MACHINE_NAME.YOUR_TAILNET_DOMAIN`
      * `ROOT_URL    = https://YOUR_TAILSCALE_MACHINE_NAME.YOUR_TAILNET_DOMAIN/`
    * `[mailer]`
      * `USER        = YOUR_GOOGLE_WORKSPACE_ACCOUNT`
      * `PASSWD      = YOUR_GOOGLE_SMTP_PASSWORD`

### Forgejo Configuration

#### Store the Initial Forgejo Administrator Password

`store-forgejo-admin-password.sh` securely stores the initial password for the `forgejo-admin` user in the macOS Keychain so `bootstrap-appliance.sh` can automatically provision the administrator account on first boot:

```bash
./store-forgejo-admin-password.sh
```

#### Google SMTP Server Setup

Forgejo supports several notification mechanisms including different mail transfer agents. We choose Google SMTP Server because it's bundled with standard Google Workspace subscription plans.

The following procedure uses Google SMTP Server for reliable system notification emails without any unnecessary "on behalf of" or "via" headers, which can get caught in spam filters:

##### Create an Email Alias

In Google Admin (Directory → Users), select your primary admin account and add an alternate email address (e.g., `forgejo-noreply@example.com`).

##### Generate an App Password

In your Google Account Security panel, ensure that 2-Step Verification is active. Then search for "App Passwords", generate an app password named "Forgejo Appliance" and save the 16-character value.

### Caveats & Best Practices

* Due to constraints imposed by Apple's Security Framework, both `teardown-appliance.sh` and `store-ts-oauth-client-secret.sh` must be run directly from a Mac-based terminal on the host and not remotely through SSH.
* Due to constraints imposed by Apple's Security Framework, `teardown-appliance.sh`, `store-ts-oauth-client-secret.sh`, `store-forgejo-admin-password.sh` and `store-borg-passphrase.sh` must be run directly from a Mac-based terminal on the host and not remotely through SSH.
* `tsbridge` supports both Auth Keys and OAuth clients for authentication. The primary reasons for this project choosing OAuth over Auth Keys are:
  * `tsbridge` has shifted their recommended best practice to OAuth.
  * An OAuth Client Secret is more secure and convenient than a standard Auth Key, which expires after a maximum of 90 days and requires manual rotation, whereas OAuth provides a permanent hands-off solution.
* The Tailscale OAuth Client Secret will not appear in the Apple Passwords app. Use Keychain Access instead.
* Tailscale MagicDNS must be enabled before you can activate HTTPS certificates. Once enabled, `bootstrap-appliance.sh` and `teardown-appliance.sh` can automatically manage and preserve the acquired TLS certificates and WireGuard keys in Apple Keychain.
* Google recently changed their security policy to no longer support the reuse of account passwords for third-party apps or devices. Generating a Google App Password avoids this restriction by using unique and secure app passwords, the current recommended best practice.
* SSH is disabled on the Forgejo appliance, so you normally connect to the OrbStack VM using `orb -m forgejo-appliance`. To remotely connect to the appliance, first use SSH to connect to the host Mac and then connect to the Forgejo appliance with `orb -m forgejo-appliance`.
* Let's Encrypt enforces a **limit of 5 certificates per hostname over a rolling 7-day period**. `teardown-appliance.sh` preserves the existing TLS certificate in Keychain to avoid burning through this quota. However, if you repeatedly teardown with `--purge` and re-bootstrap in rapid succession, `tsbridge` requests a brand new certificate each time and can trigger this limit. If you suspect you have hit this threshold:
  1. Search your node's fully qualified MagicDNS domain (e.g., `*YOUR_MACHINE_NAME*.*YOUR_TAILNET*.ts.net`) on [crt.sh](https://crt.sh) to inspect the public Certificate Transparency logs and view recent issuance timestamps.
  2. If you have exceeded the 5-certificate limit, either wait for the oldest certificate in the rolling 7-day window to age out, or temporarily rename `TS_MACHINE_NAME` in `config.env` and `forgejo-appliance.yml` to request a certificate under a fresh hostname.
* Due to macOS sandbox restrictions, a guest VM cannot directly query its host for credentials.

### Build the Appliance

`bootstrap-appliance.sh` automates the end-to-end setup of the appliance. At a high level, it creates an Ubuntu Server VM in OrbStack and applies the `cloud-init` configuration in `forgejo-appliance.yml` to install dependencies and configure Forgejo and PostgreSQL.

At the systems level, the script orchestrates host-to-VM integration: it retrieves OAuth credentials and cached WireGuard/TLS state from the macOS Keychain, configures UNIX sockets for local inter-process communication, restores existing application data and logical database backups (SQL stream), and starts the `tsbridge` reverse proxy to serve Forgejo over Tailscale HTTPS.
At the systems level, the script orchestrates host-to-VM integration: it retrieves OAuth credentials, the initial `forgejo-admin` password and cached WireGuard/TLS state from the macOS Keychain, configures UNIX sockets for local inter-process communication, restores existing application data and logical database backups (SQL stream), starts the `tsbridge` reverse proxy to serve Forgejo over Tailscale HTTPS, and ensures the `forgejo-admin` administrator account exists.

```bash
./bootstrap-appliance.sh
```

### Verify the Deployment

`test-appliance.sh` runs an automated stress-test to tear down and rebuilds the VM multiple times. This validates the Let's Encrypt cache persistence, WireGuard tunnel negotiation and HTTPS certificate routing.

```bash
./test-appliance.sh
```

### Tear Down the Appliance

`teardown-appliance.sh` first archives Forgejo git repository data, metadata and credentials, and then stops the `tsbridge` reverse proxy.

```bash
./teardown-appliance.sh
```

### Post-Provisioning Operations

Once the appliance is running, you can interact with the Forgejo CLI directly through OrbStack to verify your setup.

#### Send a Test Email to Verify the SMTP Configuration

```bash
orb exec -m forgejo-appliance sudo -u forgejo  \
  /home/forgejo/bin/forgejo admin sendmail     \
  --config /etc/forgejo/app.ini                \
  --title "Infrastructure Test Alert"          \
  --content "Forgejo notifications are reaching your primary routing pool."
```

---

## Git Example

Once the appliance is deployed and you have created a user account, you can interact with Forgejo exactly as you would with GitHub while using your Tailscale network for secure access. 

Because this appliance explicitly routes traffic over HTTPS via `tsbridge` (and bypasses SSH multiplexing), you must use HTTPS for all git operations. 

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

OrbStack lets you connect directly from a macOS host to a guest VM without needing SSH. Because `[mirrored-user]` is the default account for OrbStack integration, the `orb` command can be used from your Mac without needing to specify a user flag. Conversely, OrbStack's `mac` interoperability command allows you to execute commands on the macOS host from inside the VM. These commands run natively as the macOS host user running the OrbStack app and their standard output is also mapped to the Ubuntu shell.

```bash
# connect with an interactive shell as [mirrored-user] (default)
orb -m forgejo-appliance

# connect with an interactive shell as forgejo
orb -m forgejo-appliance -u forgejo

# check the health of a specific systemd service
orb exec -m forgejo-appliance systemctl status tsbridge

# inspect recent service logs using passwordless sudo
orb exec -m forgejo-appliance sudo journalctl -u tsbridge.service -n 50 --no-pager
```

### DNS workaround

While iteratively developing and testing a VM image, it's possible to lose connection with the image even though you can ping its IP address, the node appears in `login.tailscale.com/machines` and `orb exec -m forgejo-appliance systemctl status tsbridge` looks good. The problem is often  with the macOS host's MagicDNS service. The workaround is to toggle the Tailscale service on the macOS menu bar on and off.

On the macOS side, you can flush the DNS cache:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

### Stacked Tailscale Nodes

It's possible to get Tailscale into a state where it creates multiple nodes with similar names: `mynode`, `mynode-1`, `mynode-2`, ...visible on `login.tailscale.com/machines`. This leads to incorrect IP address errors.

The solution is to flush the system completely:

1. delete all of the related Tailscale nodes
2. stop and restart the Tailscale daemon on the macOS host
3. `teardown-appliance.sh --purge`

---

## Backup Guide (optional)

### Logical Backups vs. Remote Borg Backups

This appliance separates local lifecycle persistence from offsite disaster recovery:

* **Local Backups (`teardown-appliance.sh` and `bootstrap-appliance.sh`):**
  Because the OrbStack VM is treated as immutable infrastructure—destroyed and rebuilt from scratch rather than patched in place—we do not snapshot the entire VM disk. Instead, `teardown-appliance.sh` extracts the server's state into two complementary files on your macOS host, which `bootstrap-appliance.sh` restores into the fresh VM:
  - **User Accounts and Metadata (`forgejo-db.sql`):** The relational database stores user accounts, authentication credentials, organization memberships, repository ownership and permissions, issues, pull requests, comments, reviews, webhooks, and SSH keys. Without this database, Forgejo has no user accounts, permissions, or project management data.
  - **Git Repositories (`forgejo-backup.tar.gz`):** The filesystem archive stores the actual Git repositories (bare `.git` directories containing commits, branches, and trees), along with user avatars, release attachments and the Forgejo `app.ini` configuration.
  - **Tailscale Identity & TLS Certs:** Encrypted and cached in Apple Keychain to preserve the node's WireGuard keys and Let's Encrypt certificates across rebuilds.

  Together, `forgejo-db.sql` (who has access, plus discussions) and `forgejo-backup.tar.gz` (git repositories) form the complete state of the server. Because these are logical exports (SQL statements and a tar archive) rather than raw disk blocks, they restore cleanly even across OS updates and PostgreSQL version upgrades.

* **Optional Remote Borg Backups (`borg-backup.sh` and `borg-restore.sh`):**
  For automated, encrypted remote disaster recovery, we provide an **optional** [BorgBackup](https://borgbackup.readthedocs.io/) strategy targeting [rsync.net](https://www.rsync.net/). The `borg-backup.sh` and `borg-restore.sh` scripts take the local logical backup bundle produced by `teardown-appliance.sh`, create client-side encrypted, block-deduplicated Borg snapshots in a remote repository and restore from them when needed.

  Borg provides client-side encryption and block-level deduplication. This is efficient for daily database dumps and repository tarballs, since Borg will only upload the exact bytes that change during the day.

### Install [BorgBackup](https://borgbackup.readthedocs.io/)

Install the BorgBackup app on your macOS host:
```bash
brew install borgbackup
```

### Register your repo with your rsync.net account

[rsync.net](https://www.rsync.net/) provides remote cloud storage with native BorgBackup support over SSH. When you sign up, you receive an account identifier (for example, `zh1234`) and a host domain (`zh1234.rsync.net` or a regional hostname).

1. **Configure `BORG_REPO` in `config.env`:**
   Set `BORG_REPO` to point to your rsync.net destination:
   ```bash
   BORG_REPO="zh1234@zh1234.rsync.net:forgejo-backup"
   ```

2. **Configure SSH Key Access:**
   Ensure your macOS host can authenticate to rsync.net via SSH without an interactive password:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub zh1234@zh1234.rsync.net
   ```
   Verify the connection:
   ```bash
   ssh zh1234@zh1234.rsync.net
   ```

3. **Store Passphrase in Apple Keychain:**
   Save your Borg encryption passphrase securely in Apple Keychain using the helper script:
   ```bash
   ./store-borg-passphrase.sh
   ```

4. **Initialize the Remote Borg Backup Repo:**
   Initialize your encrypted repository on rsync.net (you only need to do this once). Replace `zh1234` with your actual rsync.net account username:
   ```bash
   # example for rsync.net account zh1234:
   borg init -e repokey zh1234@zh1234.rsync.net:forgejo-backup
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

### Backup Workflow

Backups can be performed manually by running `borg-backup.sh` or automatically using a macOS Launch Agent.

#### Manual Backups

To send the current copies of `forgejo-backup.tar.gz` and `forgejo-db.sql` to [rsync.net](https://rsync.net), run `borg-backup.sh` either manually or automatically using a `launchd` agent:

```bash
./borg-backup.sh
```

Under the hood, `borg-backup.sh` executes the following sequence:

1. Creates an encrypted, deduplicated snapshot of the host's local backup files in Borg (`borg create ::{now:%Y-%m-%d} ./forgejo-backup.tar.gz ./forgejo-db.sql`).
2. Cleans up old backups based on the retention policy configured in `config.env` (`borg prune`).

#### Automatic Backups

To run `borg-backup.sh` automatically every night (e.g., at 02:00), configure a macOS Launch Agent:

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
           <string>/Users/*YOUR_MAC_USERNAME*/*PATH_TO_REPO*/borg-backup.sh</string>
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

By combining `borg-backup.sh` with a macOS `launchd` job, you get a fully automated, encrypted and heavily deduplicated remote backup pipeline.

### Using Borg Backups

#### Listing

You can inspect all available snapshots stored in your remote Borg backup repo:

```bash
./list-borg-backups.sh
```

#### Restoring

To restore the backup files (`forgejo-backup.tar.gz` and `forgejo-db.sql`) from a Borg snapshot onto your macOS host, run `borg-restore.sh` with an archive name taken from the output of `list-borg-backups.sh`:

```bash
./borg-restore.sh <archive_name>
```

For example:
```bash
./borg-restore.sh 2026-09-02
```

`borg-restore.sh` handles extracting the remote snapshot:
1. Validates that the archive exists on the remote repository.
2. Extracts and verifies the backup files (`forgejo-backup.tar.gz` and `forgejo-db.sql`) in an isolated temporary staging directory.
3. Preserves any existing host backup files as `.bak` and copies the restored files into the working directory, placing them where they need to be for the next run of `bootstrap-appliance.sh`.

### Verify Backups

To validate the Borg backup, listing, divergence rollback and restoration pipeline end-to-end:

```bash
./test-borg-backup.sh
```

This test is self-contained and non-destructive: it stashes any existing host backup files, generates a synthetic `forgejo-backup.tar.gz` and `forgejo-db.sql` backup bundle, pushes an encrypted snapshot to your Borg repository, modifies the local files, restores from the remote snapshot, verifies SHA-256 checksums bit-for-bit and cleans up the remote test snapshot.

---

## Maintenance Guide

The Forgejo appliance treats its OrbStack VM as immutable infrastructure. Think of the VM as a strictly defined, purpose-built appliance. It's not meant to be manually administered or patched over time. To prevent configuration drift and ensure stability, we don't perform in-place configuration or upgrades. When it's time to update Forgejo, PostgreSQL or `tsbridge`, you extract a logical backup, update the source definitions in `forgejo-appliance.yml`, destroy the old environment, deploy a new one and then inject your persisted state (logical SQL stream, repository archive and Tailscale cache) back into the new environment. These tasks are performed by the `teardown-appliance.sh` and `bootstrap-appliance.sh` scripts.

Software updates follow a simple three-step procedure:

- Run `teardown-appliance.sh` to extract the Forgejo appliance's persistent state as a logical backup and then completely remove the VM.
- Update the version numbers/URLs in `forgejo-appliance.yml`.
- Run `bootstrap-appliance.sh` to build a new VM and replay your logical backup (`forgejo-backup.tar.gz` and the `forgejo-db.sql` stream).

---

## Implementation Notes

### Tech Stack

This blueprint relies on a specific set of deployment options chosen for lightweight performance, deep macOS integration and hands-off maintenance:

| Component | Description |
| :--- | :--- |
| **Forgejo** | A lightweight, self-hosted Git service written in Go. Runs over a local UNIX socket (`/run/forgejo/forgejo.sock`) without exposing TCP ports. |
| **OrbStack** | A lightweight VM/container runtime with native macOS networking and filesystem integration. |
| **Ubuntu Server** | Provides a complete Linux system environment. |
| **`cloud-init`** | Declaratively provisions packages, system users, configuration files (`app.ini`, `tsbridge.toml`) and `systemd` service units. |
| **`systemd`** | Orchestrates service lifecycles and UNIX socket dependencies between Forgejo, PostgreSQL and `tsbridge`. |
| **UNIX Domain Sockets** | Provides zero-network-exposure inter-process communication inside the VM (`/run/forgejo/forgejo.sock` and `/var/run/postgresql/.s.PGSQL.5432`). |
| **PostgreSQL** | A relational database server configured with local UNIX socket trust authentication. While Forgejo includes SQLite in its binary, PostgreSQL can handle concurrent writes, making it a safer and more performant choice for a small to medium-sized server at the footprint cost of about ~150 MB storage and ~100 MB RAM. |
| **Tailscale** | An open source mesh VPN based on WireGuard. |
| **`tsbridge`** | A Tailscale-aware reverse proxy. Maps the Tailnet HTTPS ingress layer directly to Forgejo's local UNIX socket. |
| **Let's Encrypt** | Automatically provisions publicly trusted ACME TLS certificates for the internal Tailscale MagicDNS domain via `tsbridge` without exposing ports 80 or 443. |
| **Apple Keychain** | Native macOS secrets management. |
| **`zsh`** | Powers the host-side lifecycle, provisioning, testing and backup orchestration scripts on macOS. |
| **`launchd`** | Native macOS service manager used to schedule automated nightly runs of `borg-backup.sh`. |
| **Google SMTP** | Maps a Google Workspace email alias to Forgejo for reliable, authenticated outbound system notifications. |
| **BorgBackup / rsync.net** | Provides optional client-side encrypted, block-deduplicated offsite backups of the logical database dump and repository archive over SSH. |

### Files

| File | Description |
| :--- | :--- |
| `README.md` | This file. |
| `LICENSE` | [2-clause BSD license.](https://opensource.org/license/bsd-2-clause) |
| `config.env` | Configuration variables. |
| `forgejo-appliance.yml` | `cloud-init` YAML file. |
| `bootstrap-appliance.sh` | Provisions the VM, injects Tailscale/TLS credentials from Keychain, restores logical database backups (SQL stream) and starts system services. |
| `teardown-appliance.sh` | Halts services, extracts a logical backup (plain-text SQL stream and repository tarball) and Let's Encrypt certificates to the macOS host, and then destroys the VM instance. Includes a `--purge` flag for Tailscale node eviction. |
| `store-ts-oauth-client-secret.sh` | Prompts for and securely stores the Tailscale OAuth Client Secret into the macOS host's Apple Keychain. |
| `store-forgejo-admin-password.sh` | Prompts for and securely stores the initial `forgejo-admin` administrator password into the macOS host's Apple Keychain. |
| `test-appliance.sh` | Automates a multi-cycle lifecycle stress test to validate infrastructure resilience, network convergence and database persistence. |
| `store-borg-passphrase.sh` | Prompts for and securely stores the Borg backup repo passphrase into the macOS host's Apple Keychain. |
| `borg-backup.sh` | Sends the current copies of `forgejo-backup.tar.gz` and `forgejo-db.sql` to the Borg repository and prunes old archives. |
| `borg-restore.sh` | Extracts `forgejo-backup.tar.gz` and `forgejo-db.sql` from a specified Borg archive onto the macOS host. |
| `list-borg-backups.sh` | Lists available snapshot archives in the remote Borg backup repo. |
| `test-borg-backup.sh` | Automates end-to-end verification of the Borg backup, listing and restoration pipeline using a checksum-verified test bundle. |
| `forgejo-backup.tar.gz` | The filesystem state (logical archive). Contains the raw git repository data, user avatars, release attachments, git LFS (Large File Storage) objects and the Forgejo `app.ini` configuration file. |
| `forgejo-db.sql` | The relational state (logical backup). Plain-text SQL stream containing DDL and INSERT/COPY statements for user accounts, repository metadata, issues, pull requests, comments, webhooks, SSH public keys and application tokens. |

### Secrets Management with Apple Keychain

The appliance stores its sensitive credentials in the macOS Apple Keychain. `bootstrap-appliance.sh` then injects these credentials into the VM during provisioning. This enables the VM to automatically join your Tailnet, obtain a TLS certificate from Let's Encrypt, and provision the initial `forgejo-admin` administrator account without requiring manual intervention. These same files are used by `teardown-appliance.sh` to cleanly remove the VM from Tailscale and remove the Let's Encrypt certificate.

We maintain four Keychain items:

| Item | Variable | Type | Size | Description |
| :--- | :--- | :--- | :--- | :--- |
| `tsbridge-oauth-secret` | `$TS_OAUTH_SECRET_KEY` | Operator-Managed | ~50–70 bytes | Tailscale OAuth client secret used by `tsbridge` to automatically authenticate the appliance to your tailnet (stored via `store-ts-oauth-client-secret.sh`). |
| `forgejo-admin-password` | `$FORGEJO_ADMIN_PASSWORD_KEY` | Operator-Managed | ~12–64 bytes | Initial administrator password used by `bootstrap-appliance.sh` to create the `forgejo-admin` user on first boot (stored via `store-forgejo-admin-password.sh`). |
| `borg-passphrase` | `$BORG_PASSPHRASE_KEY` | Operator-Managed | ~20–64 bytes | Passphrase used by Borg to encrypt and decrypt offsite backup snapshots on rsync.net (stored via `store-borg-passphrase.sh`). |
| `tsbridge-state-cache` | `$TS_STATE_CACHE` | Appliance-Managed | ~90 bytes | Runtime cryptographic state from `/var/lib/tsbridge`: bundles the **WireGuard node private key** (prevents MagicDNS collisions) and the **ACME TLS certificate & key** (avoids Let's Encrypt rate limits). Managed automatically by `bootstrap-appliance.sh` and `teardown-appliance.sh`. |

#### Why Store Runtime Cryptography in Keychain?

* **Zero Filesystem Exposure:** Because `/var/lib/tsbridge` contains unencrypted private keys, writing them to the host filesystem as loose files would risk accidental commits to Git. Storing them encrypted at rest in Apple Keychain keeps private keys off the host disk entirely.
* **Efficiency:** `teardown-appliance.sh` tar-compresses and base64-encodes the entire cryptographic state into a tiny ~90-byte payload. `bootstrap-appliance.sh` then decodes it back into the fresh VM in milliseconds.
* **Lifecycle Purge:** When you want a clean slate, running `./teardown-appliance.sh --purge` evicts the machine from Tailscale and deletes `tsbridge-state-cache` automatically (while preserving your operator-managed secrets).

### Accounts and Privilege Separation

The appliance isolates privileges across three distinct layers—**Linux**, **PostgreSQL** and **Forgejo**:

| Account | Layer | Description |
| :--- | :--- | :--- |
| `root` | Linux | The privileged top-level Linux administrative account. It runs the `tsbridge` service and is required for system-level backup and restore operations. |
| `*[mirrored-user]*` | Linux | The privileged OrbStack hypervisor management account. OrbStack automatically provisions a Linux account matching the host macOS username and grants it passwordless `sudo` to facilitate host-to-guest automation. It acts as the default context for all `orb` commands. |
| `forgejo` | Linux, PostgreSQL | The unprivileged application service account and database owner. In Linux, it runs the Forgejo daemon (`/home/forgejo/bin/forgejo`) and owns `/var/lib/forgejo`. In PostgreSQL, it is the role that owns the `forgejo` database and authenticates over the local UNIX socket. |
| `postgres` | Linux, PostgreSQL | The unprivileged database service account and superuser role. In Linux, it runs the PostgreSQL server processes without root privileges. In PostgreSQL, it acts as the administrative superuser role used during logical dump and restore operations. |
| `forgejo-admin` | Forgejo | The initial application administrator account inside the Forgejo web server (stored in PostgreSQL). Provisioned automatically on first boot by `bootstrap-appliance.sh` using the password stored in Apple Keychain (`$FORGEJO_ADMIN_PASSWORD_KEY`). |

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
