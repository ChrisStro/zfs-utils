#!/bin/bash

export ROOTREPL="rpool/repl"
export ROOTSANDBOX="rpool/SANDBOX"

# proxmox
export PINSTANCEPREFIX=$(date +"9%m%d") # ID-PREFIX Proxmo Sandbox instances

#region static variables
debug_on="${ENABLEDEBUG:-'false'}"
set -euo pipefail
#endregion

#region functions
# logging
log() {
        msg=$(TZ=$TIMEZONE date +'%Y-%m-%d %H:%M:%S')
        msg="[${msg}] $1"
        echo $msg
}
guminfo() {
    gum log -t TimeOnly -s "$1"
}
gumwarn() {
    gum log -t TimeOnly -l "warn" -s "$1"
}
gumerr() {
    gum log -t TimeOnly -l "error" -s "$1"
    exit 1
}
gumdebug() {
    if test "$debug_on" = "true";then gum log -t TimeOnly -l "debug" -s "$1";fi
}
# gum
check_gum() {
    if ! type gum 2>&1 > /dev/null ;then
        install_gum
    fi
}
install_gum() {
    log "Download and install gum for pretty terminal"
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt update && sudo apt install gum
}
# sandbox
create_or_destroy() {
    gumdebug "[Section:create_or_destroy]"
    sel_mode=$(gum choose --header "Sandbox erstellen oder löschen?" "Erstellen" "Löschen")

    test $sel_mode = "Löschen" && {

        ds_list=$(zfs list -d1 -Ho name $ROOTSANDBOX | grep "sandbox")
        test $ds_list && del_ds=$(gum choose --limit 1 --header "Wähle Sandbox zum löschen" $ds_list)
        test $del_ds && {
            test_is_proxmox && cleanup_pve_sandbox $del_ds
        }
        exit 0
    } || true
}
delete_sandbox (){
    gumdebug "[Section:delete_sandbox]"
    zfs delete $ROOTSANDBOX
}
# zfs
select_snapshot() {
    gumdebug "[Section:select_snapshot]"
    snaps=$(zfs list -d 2 -t snapshot -Ho name $ROOTREPL | cut -d "@" -f2| sort -u)
    SELSNAPDATE=$(gum choose $snaps)

    # Setzte benöitge variables für config Dateien
    export INSTANCETAG="sb-$SELSNAPDATE"
    export SANDBOXPARENTDS="$ROOTSANDBOX/sandbox-$SELSNAPDATE"
    export PVECONFFOLDER="/$SANDBOXPARENTDS/pveconf/etc/pve"
    export VMCONFIGFOLDER="$PVECONFFOLDER/qemu-server"
    export LXCCONFIGFOLDER="$PVECONFFOLDER/lxc"
    export PVESTORAGENAME=$(echo "sandbox-$SELSNAPDATE" | sed -e 's/:/-/g' -e 's/_/-/g')
}
check_sandbox_storage() {
    gumdebug "[Section:check_sandbox_storage]"
    ds_exists=$(zfs list -rHo name $ROOTSANDBOX | grep $1)
    test $ds_exists && return 0 || return 1
}
# proxmox
test_is_proxmox() {
    gumdebug "[Section:test_is_proxmox]"
    which pvesm && return 0 || return 1
}
confirm_running_instance() {
    gumdebug "[Section:confirm_running_instance]"
    lxc_running=$(pct list | grep "running" )
    vm_running=$(qm list | grep "running" )
    [[ $lxc_running || $vm_running ]] && gum confirm "Es gibt laufende container/vms auf dem System, lieber abbrechen?" && exit 1 || return 0
}
clone_pveconf() {
    gumdebug "[Section:clone_pveconf]"
    guminfo "Suche und clone 'pveconf' datasets"
    zfs list $ROOTREPL -rHo name | grep "pveconf" |
      gum choose --select-if-one --header "Wähle pveconf dataset für sandbox" |
      xargs -i zfs clone -p {}@$SELSNAPDATE $SANDBOXPARENTDS/pveconf ||
    gumerr "Kein Dataset mit namen 'pveconf' in $ROOTREPL"
}
select_pve_vmconfig() {
    gumdebug "[Section:select_pve_vmconfig]"
    vmconfig_files=$(find "$VMCONFIGFOLDER/" -type f -printf "%f\n")
    test "$vmconfig_files" && vmconfig_files=$(gum choose --no-limit --header "Select IDs of vms to restore" $vmconfig_files);
}
select_pve_lxcconfig() {
    gumdebug "[Section:select_pve_lxcconfig]"
    lxcconfig_files=$(find "$LXCCONFIGFOLDER/" -type f -printf "%f\n")
    test "$lxcconfig_files" && lxcconfig_files=$(gum choose --no-limit --header "Select IDs of lxcs to restore" $lxcconfig_files);
}
select_bridge(){
    gumdebug "[Section:select_bridge]"
    br_list=$(ip -o link show type bridge|awk '{print $2}' | tr -d ':')
    export SELBRIDGE=$(gum choose --header "Select bridge  for primary nic?" $br_list)
}
clone_pve_instance_storage() {
    gumdebug "[Section:clone_pve_instance_storage]"
    # vm
    for i in ${vmconfig_files[@]};do
        vm_id=$(echo $i | cut -d"." -f1)

        source_ds=$(zfs list -rt snapshot -Honame $ROOTREPL |grep $vm_id|grep $SELSNAPDATE)
        for ds in ${source_ds[@]};do
            ds_name=$(echo $ds | sed "s/@$SELSNAPDATE//g" | rev | cut -d"/" -f1 | rev)
            clone_ds="$SANDBOXPARENTDS/$ds_name"

            (check_sandbox_storage $clone_ds) && {
                gumwarn "$clone_ds existiert bereits"
            } || {
              guminfo "Cloning $ds to $clone_ds"
              zfs clone -p $ds $clone_ds
            }
        done
    done
    # lxc
    for i in ${lxcconfig_files[@]};do
        lxc_id=$(echo $i | cut -d"." -f1)

        source_ds=$(zfs list -rt snapshot -Honame $ROOTREPL |grep $lxc_id|grep $SELSNAPDATE)
        for ds in ${source_ds[@]};do
            ds_name=$(echo $ds | sed "s/@$SELSNAPDATE//g" | rev | cut -d"/" -f1 | rev)
            clone_ds="$SANDBOXPARENTDS/$ds_name"

            (check_sandbox_storage $clone_ds) && {
                gumwarn "$clone_ds existiert bereits"
            } || {
              guminfo "Cloning $ds to $clone_ds"
              zfs clone -p $ds $clone_ds
            }
        done
    done
}
check_pve_storage() {
    gumdebug "[Section:check_pve_storage]"
    ds_exists=$(pvesm status | grep $1 | awk '{print $1}')
    test $ds_exists && return 0 || return 1
}
create_pve_storage() {
    gumdebug "[Section:create_pve_storage]"
    (check_pve_storage "$PVESTORAGENAME") && {
        gumwarn "$1 already exists in proxmox"
    } || pvesm add zfspool $PVESTORAGENAME -pool $SANDBOXPARENTDS --sparse true
}
remove_pve_storage() {
    gumdebug "[Section:remove_pve_storage]"
    (check_pve_storage "$1") && {
       pvesm remove "$1"
    } || gumwarn "$1 existiert nicht"
}
get_pve_storage_devices() {
    gumdebug "[Section:get_pve_storage_devices]"
   instance_id=$1
    instance_volumes=$(zfs list -rHo name $ROOTSANDBOX | grep $instance_id | rev | cut -d/ -f1 | rev)
    echo $instance_volumes
}
update_pve_instances() {
    gumdebug "[Section:update_pve_instances]"
    config_file_name=$(echo $1)
    config_file_path=$(find /etc/pve -name $1)
    vm_id=$(echo $1 | cut -d"." -f1)
    vm_id_original=$(echo $vm_id | sed "s/$PINSTANCEPREFIX//g")

    storage_dev_names=$(get_pve_storage_devices $vm_id_original)
    guminfo "$vm_id besitzt folgende storage Geräte $storage_dev_names"
    for disk in ${storage_dev_names[@]};do
        guminfo "Aktualisiere Storage Pfad für $disk von $vm_id"
        sed -i "s/\([a-zA-Z0-9-]*\):$disk/$PVESTORAGENAME:$disk/g" $config_file_path
    done
    # dev need some improvements
    guminfo "Verbinde Netzwerkkarten mit $SELBRIDGE"
    sed -i  "s/bridge=\([a-zA-Z0-9]*\)/bridge=$SELBRIDGE/g" $config_file_path

    guminfo "Setze Netzwerkkarte auf link_down"
    sed -i  "s/bridge=$SELBRIDGE/bridge=$SELBRIDGE,link_down=1/g" $config_file_path

    guminfo "Deaktiviere boot onboot"
    sed -i  "/onboot: 1/d" $config_file_path

    guminfo "Add Tag $INSTANCETAG to $vm_id"
    echo "tags: $INSTANCETAG" >> $config_file_path
}
restore_pve_instances() {
    gumdebug "[Section:restore_pve_instances]"
    test "$vmconfig_files" && {
        for c in ${vmconfig_files[@]};do
            new_file_name="$PINSTANCEPREFIX$c"
            guminfo "Kopiere $c nach /etc/pve/qemu-server/$new_file_name"
            cp -f $VMCONFIGFOLDER/$c /etc/pve/qemu-server/$new_file_name
            update_pve_instances $new_file_name
        done
    } || guminfo "Überspringe vm Konfig-Dateien"
    test "$lxcconfig_files" && {
        for c in ${lxcconfig_files[@]};do
            new_file_name="$PINSTANCEPREFIX$c"
            guminfo "Kopiere $c nach /etc/pve/lxc/$new_file_name"
            cp -f $LXCCONFIGFOLDER/$c /etc/pve/lxc/$new_file_name
            update_pve_instances $new_file_name
        done
    } || guminfo "Überspringe lxc Konfig-Dateien"
}
cleanup_pve_sandbox() {
    gumdebug "[Section:cleanup_pve_sandbox]"
    guminfo "Bereinige Instancen"
    ds_to_delete=$1
    find /etc/pve/ -name *.conf -delete

    # get pvesm name from datasetname, snap not selected
    del_pvesm=$(echo $ds_to_delete | rev | cut -d"/" -f1 | rev | sed -e 's/:/-/g' -e 's/_/-/g')
    confirm_running_instance
    gumwarn "Lösche Proxmox Storage $del_pvesm"
    remove_pve_storage "$del_pvesm"

    gumwarn "Lösche ZFS dataset $ds_to_delete"
    zfs destroy -r $ds_to_delete
}
#endregion


#region main

# precheck
check_gum

# create or destroy
create_or_destroy

# Wähle Sandbox requirement
select_snapshot

# proxmox
clone_pveconf
select_pve_vmconfig
select_pve_lxcconfig
select_bridge
clone_pve_instance_storage
create_pve_storage
restore_pve_instances

# finish
guminfo "Sandbox erfolgreich erstellt"

#endregion