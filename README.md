# Clustershutdown

[![License](https://img.shields.io/github/license/EnterpriseVE/eve4pve-barc.svg)](https://www.gnu.org/licenses/gpl-3.0.en.html)

Safe Shutdown Script for Proxmox VE for use with UPS Software

Why? Sure, on Proxmox you can just issue a `poweroff` command, and Proxmox will shutdown all VMs for you. But if you use Ceph you might be screwed, because not all VMs might be shutdown when some nodes have already gone offline. So I put together this script, that shuts down all VMs first and wait for each shutdown to complete (optionally in a specific order) before shutting down the Hardware.

Some Notes:

You want to install `locales-all` to get rid of the locales error.

Check your shutdown times - test everything. Make sure your VMs don't hang on shutdown.
Check that the QEMU-Guest-Agent is running properly.

```text

Clustershutdown v0.2


Usage:
    proxmox_shutdown <COMMAND> [ARGS] [OPTIONS]
    proxmox_shutdown help
    proxmox_shutdown version
 
    proxmox_shutdown [--dry]
Commands:
    version              Show version program
    help                 Show help program
    shutdown             Perform the Shutdown

Switches:
    --dry                Dryrun: actually don't shutdownanything
    --debug              Show Debug Output

Report bugs to <mephisto@mephis.to>
```

Clustershutdown is a script that is supposed to shutdown a complete cluster in a clean fashion.

Install it on one Node that has the UPS Agent, and integrate it accordingly.

You can define so called shutdown-groups that help you shutting down vms in the correct order. To Configure this, add a tags to the VMs called shutodown0, shutdown1 and so on.

The script will first shutdown all vms in shutdown groups, first shutdown0, then shutdown1 and so on. After that all VMs which are not part of a shutdowngroup are being shutdown. After that all Hosts which are not the issueing one are shut down and finally the Host running the script.

How does this partically look like?

```
root@pve-frr1:~/clustershutdown# ./proxmox_shutdown.sh shutdown 
First shutdown VMs in a shutdown group...
Shutdown VM: 100 on pve-frr3 [running]
Shutdown VM: 101 on pve-frr1 [running]
Shutdown remaining VMs now...
Shutdown VM: 102 on pve-frr3 [running]
Now shutdown all nodes but mysqlf pve-frr1
Shutdown Node: pve-frr2
Shutdown Node: pve-frr3
Now shutdown myself pve-frr1, bye bye... 
root@pve-frr1:~/clustershutdown# Connection to pve-frr1 closed by remote host.
Connection to pve-frr1 closed.
```

Keep in mind that this is a loaded gun. Issuing "proxmox_shutdown shutdown" will just kill all your workload and shutdown everything. If you hadn't planned this, you might have a bad day.

