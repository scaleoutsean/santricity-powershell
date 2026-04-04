# SANmox - SANtricity - Proxmox VE 9 TUI 

## What is SANmox

Proxmox VE 9 has a poor storage plug-in approach inspired by my SolidFire TUI, [Firemox](https://github.com/scaleoutsean/firemox). See [this post](https://scaleoutsean.github.io/2026/03/31/proxmox-plugin-netapp-eseries-santricity.html) for more on SANmox and SANtricity LVM plug-in for PVE 9.

This TUI has the following advantages:

- Does not require storage credentials on PVE nodes
- API access to PVE - more robust for minor PVE upgrades and patches
- API access to SANtricity and easy to extend as underlying SANtricity PowerShell cmdlets are many
- It can be extended to use SANtricity LVM, my [SANtricity-aware LVM plugin for shared storage](https://scaleoutsean.github.io/2026/03/31/proxmox-plugin-netapp-eseries-santricity.html), without weaker security inherent to full-featured Proxmox VE storage plug-ins

## Installation and configuration

SANmox is **not** meant to be installed on PVE nodes. It is meant to be installed on a management workstation that can reach PVE hosts and SANtricity management IP.

- Assuming your workstation is Debian Trixie, you should be able to use [PowerShell 7.6 LTS](https://github.com/PowerShell/PowerShell/releases/download/v7.6.0/powershell-lts_7.6.0-1.deb_amd64.deb). If you're on other OS, get a recent PowerShell 7.6 or 7.5
- Install PowerShell module [Spectre Console](https://spectreconsole.net/): `Install-Module PwshSpectreConsole -Scope CurrentUser`
- Clone this entire repo, change directory to `./sanmox`. Copy `sanconfig.json.example` to `sanconfig.json`:
  - `SanApiUri`: SANtricity API endpoint
  - `SanUser`: SANtricity `admin` or `storage` (I haven't tried, but might work fine) account
  - `SanPoolName`: SANtricity storage pool name to use for PVE; it is strongly recommended to use DDP
  - `SanHostGroupName`: SANtricity host group (or standalone host) with all PVE hosts' IQNs/NQNs added to it
  - `PveApiUri`: PVE API IP/FQDN
  - `PveUser`: PVE user + API key name. Example: if the PVE user is `root@pam` and API Token name `wtf`, that means `root@pam!wtf` should be provided here. This is same as API token name when you issue it in PVE datacenter API Token issuing workflow. **Important:** uncheck Privilege Separation when creating the token, or your token will have limited privilege - for example, it will be unable to create datastores. You don't need to use `root@pam` account, but your token must have sufficient privileges. Check the PVE documentation for more.
- Run `./sanmox.ps1`
  - Optional: pass a specific config file with `-Config /full/path/to/sanconfig.cluster-a.json`
  - If `-Config` is not provided, SANmox keeps the existing default behavior and loads `./sanconfig.json` from the same directory as `sanmox.ps1`

Your (encrypted) credentials will be securely prompted for on first launch and optionally stored in:

- Linux/macOS: `~/.sanmox_cred.xml` and `~/.sanmox_pve_cred.xml`
- Windows: `$HOME/.sanmox_cred.xml` and `$HOME/.sanmox_pve_cred.xml` (typically `C:\Users\<username>\`)

Do not leave your passwords inside `sanconfig.json`.

```powershell
PowerShell 7.6.0
PS /home/sean/code/santricity-powershell> ./sanmox/sanmox.ps1                                        
Please enter password for SANtricity user 'admin' (input hidden): ********
Do you want to save this password securely for future sessions? (Y/n): 

Please enter password/secret for PVE user 'root@pam' (input hidden): ********
Do you want to save this PVE password securely for future sessions? (Y/n): 

# Alternate profile/config example
PS /home/sean/code/santricity-powershell> ./sanmox/sanmox.ps1 -Config /home/sean/configs/sanconfig.cluster-b.json
```

## SANmox features

- **SANtricity** LUN provisioning lifecycle for SANtricity with PVE 9
  - Create
  - Extend/resize
  - Delete
  - Change major properties (caching, media scan)
- **SANtricity** configuration review
  - Pool details
  - LUN paths
- **PVE** lifecycle for shared storage LVM
  - Create (requires ready-to-use VG on SANtricity volume)
  - Delete
  - Report/list LVM/VG/LUNs

## Possible additional features

In terms of non-trivial changes, these seem appealing to me:

- Any SANtricity PowerShell cmdlet you see in this repo can be added
- Possible integration with SANtricity LVM plug-in for tighter integration with Proxmox datacenters/clusters (see the blog post at the top)

