# SANmox - SANtricity - Proxmox VE 9 TUI 

## What is SANmox

Proxmox VE 9's storage plugin approach isn't very attractive. See [this post](https://scaleoutsean.github.io/2026/03/31/proxmox-plugin-netapp-eseries-santricity.html) for more. As a result, I chose to implement a very basic SANtricity LVM plug-in for PVE 9 *and* implement all functionality in a PowerShell TUI (SANmox).

This TUI has the following advantages:

- Does not require storage credentials on PVE nodes
- Uses API to access PVE - more robust for minor PVE upgrades and patches
- Uses API access to SANtricity and easy to extend as underlying SANtricity PowerShell cmdlets are many
- Leverages SANtricity LVM without any risk or complexity

Although the TUI could work with generic PVE LVMPlugin (and the initial release did), going forward it will work with SANtricity LVM Plugin (`santricity_lvm` downloadable from [here](https://github.com/scaleoutsean/santricity-go/tree/master/tools/proxmox_plugin)).

**Requirements:**

- PowerShell 7.6+ on client (any OS that runs PowerShell) with SANmox module
- PVE 9.1 with `santricity_lvm` plugin on PVE nodes
- SANtricity 11.9+ with iSCSI (automated) or NVMe/RoCE (semi-automated due to missing NVMe support in PVE 9.1) storage interfaces

## Installation and configuration

SANmox is **not** meant to be installed on PVE nodes. It is meant to be installed on a management workstation that can reach PVE hosts and SANtricity management IP.

- Assuming your workstation is running Debian Trixie, you should be able to use [PowerShell 7.6 LTS](https://github.com/PowerShell/PowerShell/releases/download/v7.6.0/powershell-lts_7.6.0-1.deb_amd64.deb). If you're on other OS, get a recent PowerShell 7.6 or 7.5
- Install PowerShell module [Spectre Console](https://pwshspectreconsole.com/guides/get-started/): `Install-Module PwshSpectreConsole -Scope CurrentUser`
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

**Do not leave your password inside `sanconfig.json`!**

If `PveSecret` is present in the config, SANmox will warn at startup and use it only as a fallback when no encrypted PVE credential has been saved yet. Treat this as a temporary migration aid, not the normal operating mode.

```powershell
PowerShell 7.6.1
PS /home/sean/code/santricity-powershell> Install-Module -Name PwshSpectreConsole
PS /home/sean/code/santricity-powershell> ./sanmox/sanmox.ps1                                        
Please enter password for SANtricity user 'admin' (input hidden): ********
Do you want to save this password securely for future sessions? (Y/n): 

Please enter password/secret for PVE user 'root@pam' (input hidden): ********
Do you want to save this PVE password securely for future sessions? (Y/n): 

# Alternate profile/config example
PS /home/sean/code/santricity-powershell> ./sanmox/sanmox.ps1 -Config /home/sean/configs/sanconfig.cluster-b.json
```

## Use

Remember to check relevant columns before making changes. Generally:

- `Usage: LVM` shows a volume is in use (although it may not have anything on it, you should at least remove LVM and VG before deleting this volume from SANtricity).
- `GPT: Yes` may not mean anything, and I generally don't even use that, but maybe someone else is using this disk.
- `Usage: No` and `GPT: No` is the safest situation. Although this is view from one host. Another PVE host may have a different view, so as always when working with shared storage, make sure before you act.

![Host view of storage](./images/step_00_pve_storage_view.png)

Create a SANtricity host group for PVE datacenter (cluster) from the UI or other (PowerShell, Python, etc):

![Create SANtricity host group for PVE datacenter (cluster)](./images/step_01_create_santricity_host_group.png)

Create a SANtricity volume (example: `sanmox`) in **SANtricity Volumes**:

![Create volume in SANtricity Volume menu (example: `sanmox`)](./images/step_02_create_santricity_volume.png)

iSCSI may be able to discover the new target if previous volumes exists (i.e. target portal is known) with `pvesm scan iscsi <HOST[:PORT]>`. But PVE 9.1 can't scan NVMe/RoCE, so this step is left to PVE CLI rather than partially implemented.

Either way, rescan storage from the CLI  using `iscsiadm` or `nvme` (client) and add a VG on the new volume. Use `lsblk` to show devices. For easier management, just prefix the SANtricity volume name with `vg_`, so that `vg_sanmox` gets created on a volume `sanmox`, for example. Do **not** select "Add Storage" as you're not adding a local LVM. Also, remember that `lvs` and similar host-level commands do not show PVE cluster-level LVM information that you get from `pvesm status`. CLI commands on the host: `pvcreate <dev-path>`, `vgcreate <vg_name> <dev-path>`.

![Create VG (`vg_sanmox`)](./images/step_03_create_vg.png)

Verify the VG has been created:

![vg_sanmox has been created](./images/step_04_return_to_sanmox.png)

In **SANtricity-Proxmox Toolbox** (top level menu), create new PVE datastore on `vg_sanmox`:

![Create LVM datastore on VG](./images/step_05_create_shared_lvm_datastore.png)

That will setup shared storage LVM and enable other features that you can expect with `cat /etc/pve/storage.cfg`.

To remove shared storage LVM, remove all VMs/CTs, and use the TUI in reverse. The VG step has to be done manually as well. You may also disconnect from iSCSI or NVMe if you wish.

There are some other menu items made to make it possible to avoid using Web browser, such as high-level capacity and performance reports.

![Other features](./images/step_06_other_features.png)

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


