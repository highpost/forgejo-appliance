# Forgejo Appliance

Forgejo is a powerful and lightweight GitHub clone written in Go. This project is an opinionated blueprint for deploying Forgejo in an OrbStack VM with Ubuntu, PostgreSQL and the `tsbridge` reverse proxy. The goal is to provide a distributed private workgroup server rather than a public website. You can host the appliance on a home/office Mac, and then colleagues can access it from anywhere in the world through Tailscale.

While this blueprint is tailored for Forgejo, it can also serve as a pattern for hosting other server applications like Nextcloud, Wiki.js, BookStack or Jellyfin. Most of the work would be in modifying `forgejo-appliance.yml`.

---

## Deployment Guide

### Enable Tailscale MagicDNS

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

To make this appliance permanent and maintenance-free, we use an OAuth Client Secret.
* Run the secret storage script on your macOS host:
  ```
  ./store-ts-oauth-client-secret.sh
  ```
* Paste the OAuth Client Secret from the system clipboard to stdin for the secret storage script.

### Enable HTTPS

* Tailscale Admin Console
* Settings → HTTPS (or Certificates)
* enable HTTPS

### Modify the Configuration Files

* `config.env`:
  * `TS_OAUTH_CLIENT_ID="YOUR_TAILNET_OAUTH_ID"`
  * `TS_HOSTNAME="YOUR_FORGEJO_HOSTNAME"`
  * `TS_TAILNET="YOUR_TAILNET_DOMAIN"`
* `forgejo-appliance.yml`:
  * `[[services]]`
    * `name        = "YOUR_FORGEJO_HOSTNAME"`
    * `hostname    = "YOUR_FORGEJO_HOSTNAME"`
  * `[server]`
    * `DOMAIN      = YOUR_FORGEJO_HOSTNAME.YOUR_TAILNET_DOMAIN`
    * `ROOT_URL    = https://YOUR_FORGEJO_HOSTNAME.YOUR_TAILNET_DOMAIN/`
  * `[mailer]`
    * `USER        = YOUR_GOOGLE_WORKSPACE_ACCOUNT`
    * `PASSWD      = YOUR_GOOGLE_SMTP_PASSWORD`

#### Notes

* Due to constraints imposed by Apple's Security Framework, both `teardown-appliance.sh` and `store-ts-oauth-client-secret.sh` must be run directly from a Mac-based terminal on the host and not remotely through SSH.
* `tsbridge` supports both Auth Keys and OAuth clients for authentication. The primary reasons for this project choosing OAuth over Auth Keys are:
  * `tsbridge` has shifted their recommended best practice toward OAuth.
  * Standard Auth Keys expire (after a maximum of 90 days) and require manual replacement, whereas OAuth provides a permanent hands-off solution. The only notable downside to choosing OAuth is that it causes an incompatibility with Headscale, the open-source Tailscale control server, which currently only supports Auth Keys.
* The Tailscale OAuth Client Secret will not appear in the Apple Passwords app. Use Keychain Access instead.

### Build the Infrastructure

Provision the Ubuntu virtual machine and apply the `cloud-init` configurations to install packages and configure the Forgejo and PostgreSQL server applications.

Inject secrets, restore the TLS certificate, initialize UNIX sockets and then start the `tsbridge` reverse proxy.

```
./bootstrap-appliance.sh
```

### Tear down infrastructure

Store the TLS certificate and the Forgejo data. Stop the `tsbridge` reverse proxy.

```
./teardown-appliance.sh
```

### Verify the Deployment

Run the automated stress-test to tear down and rebuild the VM multiple times. This validates the Let's Encrypt cache persistence, WireGuard tunnel negotiation and HTTPS certificate routing.

```
./test-appliance.sh
```

### Post-Provisioning Operations

Once the appliance is running, you can interact with the Forgejo CLI directly through OrbStack to finalize your setup.

#### Create the Initial Administrator Account

```
orb exec -m forgejo-appliance sudo -u forgejo-admin  \
  /home/forgejo-admin/bin/forgejo admin user create  \
  --config /etc/forgejo/app.ini                      \
  --username player1                                 \
  --password "PickATemporaryPassword123"             \
  --email player1@example.com                        \
  --admin
```

#### Send a Test Email

```
orb exec -m forgejo-appliance sudo -u forgejo-admin  \
  /home/forgejo-admin/bin/forgejo admin sendmail     \
  --config /etc/forgejo/app.ini                      \
  --title "Infrastructure Test Alert"                \
  --content "Forgejo notifications are successfully reaching your primary routing pool."
```

### Google SMTP Server Setup

Forgejo supports several notification mechanisms including different mail transfer agents. We choose Google SMTP Server because it's bundled with Google Workspace subscription plans.

The following procedure uses Google SMTP Server for reliable system notification emails without any unnecessary "on behalf of" or "via" headers.

#### Create an Email Alias

In Google Admin (Directory → Users), select your primary admin account and add an alternate email address (e.g., `forgejo-noreply@example.com`).

#### Generate an App Password

In your Google Account Security panel, ensure 2-Step Verification is active, search for "App Passwords", generate an app password named "Forgejo Appliance" and then save the 16-character string.

NB: Google recently changed their security policy to no longer support the reuse of account passwords for third-party apps or devices. This procedure avoids this new restriction by using unique and secure app passwords, the current recommended best practice.

#### Configure `app.ini`

The `cloud-init` blueprint (`forgejo-appliance.yml`) handles this injection automatically. Just ensure the `PASSWD` variable in the [`mailer`] block is updated with your new App Password.

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

```
# link your local repository to the Forgejo remote
git remote add origin https://*YOUR_FORGEJO_HOSTNAME*.*YOUR_TAILNET_DOMAIN*/*YOUR_FORGEJO_USERNAME*/*YOUR_REPO*.git

# push your code and set the upstream tracking branch
git push --set-upstream origin main
```

When prompted for credentials by your git client, use your Forgejo username and password or generate a dedicated application token in your Forgejo user settings.

---

## Testing Guide

### Connecting to an OrbStack VM

VM development requires rapid testing and debugging cycles. OrbStack lets you connect directly from a macOS host to a VM without needing SSH. Because `[mirrored-user]` is the default account for OrbStack integration, the `orb` command can be used from your Mac without needing to specify a user flag. Conversely, OrbStack's `mac` interoperability command allows you to execute commands on the macOS host from inside the VM. These commands run natively as the macOS host user running the OrbStack app and their standard output is also mapped to the Ubuntu shell.

```
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

```
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

### Stacked Tailscale Nodes

It's possible to get Tailscale into a state where it creates multiple nodes with similar names: `mynode`, `mynode-1`, `mynode-2`, ...visible on `login.tailscale.com/machines`. This leads to incorrect IP address errors.

The solution is to flush the system completely:

- delete all of the related Tailscale nodes
- stop and restart the Tailscale daemon on the Mac host
- `teardown-appliance.sh --purge`

---

## Maintenance Guide

### Software Updates

The Forgejo appliance treats its OrbStack VM as immutable infrastructure. Think of the VM as a strictly defined, purpose-built appliance. It's not meant to be manually administered or patched over time. To prevent configuration drift and ensure stability, we don't perform in-place configuration or upgrades. When it's time to update Forgejo, PostgreSQL or `tsbridge`, you update the source definitions in `forgejo-appliance.yml`, destroy the old environment, deploy a new one and then inject your persisted state (database and Tailscale cache) back into the new environment. These tasks are performed by the `teardown-appliance.sh` and `bootstrap-appliance.sh` scripts.

Software updates follow a simple three-step procedure:

- Update the version numbers/URLs in `forgejo-appliance.yml`.
- Run `teardown-appliance.sh` to store the Forgejo appliance's persistent state and then completely remove the VM.
- Run `bootstrap-appliance.sh` to build a new VM and restore your persistent data (`forgejo-backup.tar.gz` and `forgejo-db.sql`).

### Backup Strategy

Because this appliance treats the OrbStack VM as ephemeral, standard VM snapshots won't work. We reuse the backup mechanism built into `teardown-appliance.sh` to extract the persistent data into two files `forgejo-backup.tar.gz` and `forgejo-db.sql`) on the macOS host. We then use [BorgBackup](https://borgbackup.readthedocs.io/) to remotely backup these files on [rsync.net](https://www.rsync.net/).

Borg provides client-side encryption and block-level deduplication. This is efficient for our daily database dumps and repository tarballs, since Borg will only upload the exact bytes that change during the day.

#### Install [BorgBackup](https://borgbackup.readthedocs.io/)

Install the BorgBackup app on your macOS host:
```
brew install borgbackup
```

#### Register your repo with your rsync.net account

Initialize your encrypted repository on rsync.net (you only need to do this once). Save your passphrase in Apple Keychain.

```
borg init -e repokey RSYNC-USER@RSYNC-URL.rsync.net:forgejo-backup
```

#### Daily Backup Workflow

To back up the Forgejo appliance, you must extract the state, push it to [rsync.net](https://rsync.net), and then rebuild the VM. You can automate this by putting the following commands into a script (e.g., `backup.sh`) and scheduling it to run nightly via macOS `launchd`:

```
#!/bin/zsh

export BORG_PASSPHRASE="your_super_secret_passphrase"
export BORG_REPO="RSYNC-USER@RSYNC-URL.rsync.net:forgejo-backup"

# safely halt the appliance and extract the data to the Mac host
./teardown-appliance.sh

# create an encrypted, deduplicated snapshot tagged with the current date
borg create ::{now:%Y-%m-%d} ./forgejo-backup.tar.gz ./forgejo-db.sql

# clean up old backups (keep 7 daily, 4 weekly, and 6 monthly archives)
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=6

# rebuild the appliance and inject the state
./bootstrap-appliance.sh
```

#### Automating with macOS `launchd`

To automatically run the `backup.sh` script every night, we use macOS's native `launchd` system.

1. Ensure your backup script is executable:

```
chmod +x /absolute/path/to/backup.sh
```
2. Create a Launch Agent property list (.plist) file. Open your terminal and create a file at ~/Library/LaunchAgents/com.forgejo-appliance.backup.plist.
3. Paste the following XML into the file. Important: You must replace `/Users/YOUR_MAC_USERNAME/path/to/backup.sh` with the absolute path to your script, as `launchd` does not resolve relative paths (like `./` or `~/`).
```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "[http://www.apple.com/DTDs/PropertyList-1.0.dtd](http://www.apple.com/DTDs/PropertyList-1.0.dtd)">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.forgejo-appliance.backup</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_MAC_USERNAME/path/to/backup.sh</string>
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
4. Load the Launch Agent into macOS:
```
launchctl load ~/Library/LaunchAgents/com.forgejo-appliance.backup.plist
```


By combining a scheduled run of `teardown-appliance.sh` with a local Borg `launchd` job, you can achieve a fully automated, encrypted and heavily deduplicated offsite backup pipeline.

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
| **PostgreSQL** | A relational database server configured with local UNIX socket trust authentication. While Forgejo includes SQLite in its binary, PostgreSQL can gracefully handle concurrent writes, making it a safer and more performant choice for a small to medium-sized workgroup server at the footprint cost of about ~150 MB storage and ~100 MB RAM. |
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
| `store-ts-oauth-client-secret.sh` | Prompts for and securely stores the Tailscale OAuth Client Secret into the macOS host's Apple Keychain. |
| `teardown-appliance.sh` | Gracefully halts services, extracts the database and Let's Encrypt certificates to the macOS host and destroys the VM instance. Includes a `--purge` flag for Tailscale node eviction. |
| `test-appliance.sh` | Automates a multi-cycle lifecycle stress test to validate infrastructure resilience, network convergence and database persistence. |
| `forgejo-backup.tar.gz` | The filesystem state. Contains the raw git repository data, user avatars, release attachments, git LFS (Large File Storage) objects and the Forgejo `app.ini` configuration file. |
| `forgejo-db.sql` | The relational state. Contains user accounts, repository metadata, issues, pull requests, comments, webhooks, SSH public keys and application tokens. |

### Secrets Management with Apple Keychain

Due to macOS sandbox restrictions, a guest VM cannot directly query its host for secrets. Our general approach is to store secrets in Apple Keychain and then inject them from the macOS host with `orb exec` during the provisioning phase.

We rely on Apple Keychain to store:
* `tsbridge-oauth-secret` (see `store-ts-oauth-client-secret.sh`)
* `tsbridge-cert-cache` (see [Apple Keychain and Let's Encrypt Workaround](apple-keychain-and-lets-encrypt-workaround) below)

### Let's Encrypt Certificate Caching

While Tailscale encrypts traffic over WireGuard, Forgejo still requires a Let's Encrypt domain validation certificate for browser HTTPS compliance. We want to minimize the number of Let's Encrypt certificate requests we make for a given URL to avoid their strict rate limit (5 duplicate certs per week). Developing server applications on VMs is an iterative process, and you will quickly discover that repeatedly spinning up new VM instances using the same URL can do exactly that.

To preserve strict VM isolation while avoiding Let's Encrypt rate limits, we use an automated workaround:
* `teardown-appliance.sh`: Compresses the TLS state in `/var/lib/tsbridge` into a base64 string and then stores it in Apple Keychain.
* `bootstrap-appliance.sh`: Injects the base64 string back into a new VM's local storage, ensuring a seamless authenticated boot.

*Note: If you suspect you've hit the rate limit for Let's Encrypt, search for your Tailnet node on [crt.sh](https://crt.sh).*

### MagicDNS Collision Mitigation

When tearing down a VM, Tailscale's global MagicDNS table holds an active lease on the hostname for a few minutes. Spinning up a new VM too quickly causes a collision, resulting in a `-1` suffix appended to the hostname (e.g., `forgejo-appliance-1`). `teardown-appliance.sh` has a `--purge` command-line option which adds the necessary 3-minute delay to guarantee a clean slate.

### Why PostgreSQL instead of SQLite?

While SQLite is incredibly fast and compiled directly into the Forgejo binary (requiring zero setup), it relies on file-level locking for database writes. If two users push code concurrently, or a user pushes code while a background worker is updating an issue tracker, SQLite can throw database is locked errors.

PostgreSQL uses Multi-Version Concurrency Control (MVCC) and row-level locking. For a workgroup server expected to handle concurrent git operations and CI/CD API polling, PostgreSQL provides guaranteed transactional stability without sacrificing data integrity. The extra footprint (~100 MB RAM) is a reasonable price to pay for the added reliability.

### Why use a VM instead of a container?

#### Service Orchestration

The Forgejo appliance requires three distinct layers to work together:

- Forgejo (application)
- PostgreSQL (database)
- `tsbridge` (network proxy)

Containers prefer a "one process per container" rule. While we can coordinate these services within containers with a minimal init system like `tini`, OrbStack VMs allow us to run a standard Ubuntu environment and leverage `systemd` natively.

#### UNIX Sockets

Once you've collected your layers into a single VM, you need to connect them. TCP/IP network sockets may seem like a logical choice, but they quickly run into headaches:

- PostgreSQL assumes that a network port requires authentication.
- DNS resolution … is hard.
- Strict isolation. Our Forgejo appliance should be a black box where only the `tsbridge` reverse proxy is exposed to the network. TCP/IP local networking lends itself to accidental port exposure; UNIX sockets are physically bound to the filesystem, making accidental network exposure impossible.

Instead, the appliance's performance and security rely on tightly coupled UNIX sockets:

- `/run/forgejo/forgejo.sock` is used by `tsbridge` to map Tailnet traffic directly to Forgejo.
- `/var/run/postgresql/.s.PGSQL.5432` is used by Forgejo to connect with PostgreSQL.

While you can share UNIX sockets between containers using shared volumes, doing so on a Mac via Docker Desktop or OrbStack's container engine often introduces nightmarish UID/GID permission mapping issues across the host-to-guest boundary. With a single Ubuntu VM, you can use UNIX sockets to avoid the shortcomings of TCP/IP local networking.

#### Apple Keychain and Let's Encrypt Workaround

The Let's Encrypt caching hack relies on the host Mac dynamically reading and writing state to the guest environment.

Doing this with standard containers requires clunky volume mounts or complex environment variable injections at runtime. With OrbStack's VM model, you can use `orb exec` to effortlessly pipe a base64-encoded tarball from your Mac's Apple Keychain directly into the root filesystem of the running VM. The VM acts as a highly isolated, yet easily programmable, black box.

#### Data Persistence and Ephemerality

Containers are fundamentally ephemeral. If you accidentally type docker `compose down -v`, your entire database and git repository data are vaporized. While a VM can be deleted, it acts much more like a permanent server for your workgroup. Your data lives safely in `/var/lib/forgejo` without requiring complex persistent volume claim management.

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
