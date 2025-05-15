#!/bin/bash


LC_ALL="en_US.UTF-8"
source rainbow.sh

name=$(basename "$0")

# readonly
declare -r NAME=$name
declare -r VERSION=0.2
declare -r PROGNAME=${NAME%.*}
declare -r PVE_DIR="/etc/pve"
declare -r PVE_NODES="$PVE_DIR/nodes"
declare -r QEMU='qemu-server'
declare -r QEMU_CONF_CLUSTER="$PVE_NODES/*/$QEMU"
declare -r EXT_CONF='.conf'
declare -r ME=$(uname -n)
logfile=$(mktemp)
declare -r LOG_FILE=$logfile

# commandline params
declare -i opt_dry_run=0
declare -i opt_debug=0
declare -i opt_syslog=0

# associative global arrays 
declare -A -g pvnode
declare -A -g tags

declare -r restripansicolor='s/\x1b\[[0-9;]*m//g'

function usage(){
   shift

    if [ "$1" != "--no-logo" ]; then
        cat << EOF

Clustershutdown v$VERSION

EOF
    fi

    cat << EOF

Usage:
    $PROGNAME <COMMAND> [ARGS] [OPTIONS]
    $PROGNAME help
    $PROGNAME version
 
    $PROGNAME [--dry]
Commands:
    version              Show version program
    help                 Show help program
    shutdown             Do the Shutdown

Switches:
    --dry                Dryrun: actually don't shutdownanything
    --debug              Show Debug Output

Report bugs to <mephisto@mephis.to>

EOF
}

function parse_opts(){
    shift

    local args
    args=$(getopt \
           --options '' \
           --longoptions=sshcipher:,dry,debug \
           --name "$PROGNAME" \
           -- "$@") \
           || end_process 128

    eval set -- "$args"

    while true; do    
      case "$1" in
        --sshcipher) opt_sshcipher=$2; shift 2;;
        --dry) opt_dry_run=1; shift 2;;
        --test) opt_test=$2; shift 2;;
        --debug) opt_debug=1; shift;;
        --syslog) opt_syslog=1; shift;;
        --) shift; break;;
        *) break;;
      esac
    done

    if [ $opt_debug -eq 1 ]; then
        log info "============================================"
        log info "Clustershutdown: $VERSION";
        log info "pid: $(cat /var/run/"$PROGNAME".pid)"
        log info "============================================"
        log info "Proxmox VE Version:"

        echowhite "$(pveversion)"

        log info "============================================"
    fi


    if [ "$opt_vm_ids" = "all" ]; then
        local all=''
        local data=''
        local cnt=''
        local ids=''

        all=$(get_vm_ids "$QEMU_CONF_CLUSTER/*$EXT_CONF" "$LXC_CONF_CLUSTER/*$EXT_CONF")
        log debug "all: $all"
        all=$(echo "$all" | tr ',' "\n")
        opt_exclude_vmids=$(echo "$opt_exclude_vmids" | tr ',' "\n")
        for id in $all; do
            cnt=$(echo $opt_exclude_vmids | grep -o $id|wc -w)
            if [ $cnt == 0 ]; then
                vm_ids=$(echo "$vm_ids$id:$opt_prefix_id$id,")
            fi
        done
        vm_ids=$(echo "$vm_ids" | tr ',' "\n")
    else
        if [ ! -z $opt_prefix_id ]; then
            ids=$(echo "$opt_vm_ids" | tr ',' "\n")
            for id in $ids; do
                vm_ids=$(echo "$vm_ids$id:$opt_prefix_id$id,")
            done
            vm_ids=$(echo "$vm_ids" | tr ',' "\n")
        else
            vm_ids=$(echo "$opt_vm_ids" | tr ',' "\n")
        fi
    fi
    
}

function get_vm_ids(){
    local data=''
    local conf=''

    while [ $# -gt 0 ]; do
        for conf in $1; do
            [ ! -e "$conf" ] && break
            if [ -n "$opt_tag" ]  && ! grep -qE "^tags:\s.*$opt_tag(;|$)" $conf; then
                continue
            fi
            conf=$(basename "$conf")
            [ "$data" != '' ] && data="$data,"
            data="$data${conf%.*}"
        done
        shift
    done

    echo "$data"
}

function map_vmids_to_host() {
    for node in $(/usr/bin/pvecm nodes | tail +5 | tr -s ' ' | cut -d' ' -f 4)
    do
        for vm in $(find /etc/pve/nodes/$node/qemu-server/ -name *.conf -printf "%f\n" | cut -d '.' -f 1)
        do
            pvnode[$vm]=$node
        done
    done
}

function get_registered_tags() {
    tags=$(cat /etc/pve/datacenter.cfg |grep -E '^registered-tags.*' | cut -d ' ' -f 2 | tr ";" "\n" | grep -E '^shutdown.*$')
}

function do_run(){
    local cmd=$*;
    local -i rc=0;
    if [ $opt_dry_run -eq 1 ]; then
        echo "DRY RUN, would issue: $cmd"
        rc=$?
    else
        log debug "$cmd"
        eval "$cmd"
        rc=$?
        [ $rc != 0 ] && log error "$cmd"
        log debug "return $rc ps ${PIPESTATUS[@]}"
    fi
    return $rc
}

function do_shutdown() {

    #create pid file
    local pid_file="/var/run/$PROGNAME.pid"
    if [[ -e "$pid_file" ]]; then
        local pid; pid=$(cat "${pid_file}")
        if ps -p "$pid" > /dev/null 2>&1; then
          log error "Process already running with pid ${pid}"
          end_process 1
        fi
    fi
    if ! echo $$ > "$pid_file"; then
        log error "Could not create PID file $pid_file"
        end_process 1
    fi

    map_vmids_to_host
    get_registered_tags
    sorted_tags=($(printf "%s\n" "${tags[@]}" | sort))
    log info "First shutdown VMs in a shutdown group..."
    for item in "${sorted_tags[@]}"; do
        for vm in $(grep -r -P "^.*tags:\s.*$" /etc/pve/nodes/*/qemu-server/*|grep $item|grep -oP '/qemu-server/\K[0-9]+(?=\.conf)')
        do
            vmstatus=$(ssh root@"${pvnode[$vm]}" qm status "$vm"|cut -d' ' -f 2)
            if [ $vmstatus == "running" ]; then
                echo "Shutdown VM: $vm on ${pvnode[$vm]} [$vmstatus]"
                do_run "ssh root@${pvnode[$vm]} qm shutdown $vm >/dev/null"
            else
                echo "No need to shutdown $vm, it's not running."
            fi
        done
    done
    echo "Shutdown remaining VMs now..."
    for vm in $(grep -r -P "^.*tags:\s.*$" /etc/pve/nodes/*/qemu-server/*|grep -v "shutdown" |grep -oP '/qemu-server/\K[0-9]+(?=\.conf)')
    do
        vmstatus=$(ssh root@"${pvnode[$vm]}" qm status "$vm"|cut -d' ' -f 2)
        if [ $vmstatus == "running" ]; then
            echo "Shutdown VM: $vm on ${pvnode[$vm]} [$vmstatus]"
            do_run "ssh root@${pvnode[$vm]} qm shutdown $vm >/dev/null"
        else
            echo "No need to shutdown $vm, it's not running."
        fi
    done
    # Shutdown gracefully
    echo "Now shutdown all nodes but mysqlf $ME"
    for node in $(/usr/bin/pvecm nodes | tail +5 | tr -s ' ' | cut -d' ' -f 4 | grep -v $ME)
    do
        echo "Shutdown Node: $node"
        do_run "ssh root@$node poweroff"
    done
    echo "Now shutdown myself $ME, bye bye... "
    do_run "poweroff"
}


function end_process(){
    local -i rc=$1;

    #remove log
    rm "$LOG_FILE"
    exit "$rc";
}


function log(){
    local level=$1
    shift 1
    local message=$*
    local syslog_msg=''

    case $level in
        debug) 
            if [ $opt_debug -eq 1 ]; then
                echo -e "$(date "+%F %T") DEBUG: $message";
                echo -e "$(date "+%F %T") DEBUG: $message" >> "$LOG_FILE";
            fi    
            ;;

        info) 
            echo -e "$message"; 
            echo -e "$message" | sed -e 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE";
            syslog_msg=$(echo -e "$message" | sed -e ${restripansicolor})
            [ $opt_syslog -eq 1 ] && logger -t "$PROGNAME" "$syslog_msg"
            ;;

        warn)
            echo -n "$(echoyellow 'WARNING: ')"
            echowhite "$message" 1>&2
            echo -e "$message" | sed -e ${restripansicolor} >> "$LOG_FILE";            
            syslog_msg=$(echo -e "$message" | sed -e ${restripansicolor})
            [ $opt_syslog -eq 1 ] && logger -t "$PROGNAME" -p daemon.warn "$syslog_msg"
            ;;
        
        error)
            echo -n "$(echored 'ERROR: ')"
            echowhite "$message" 1>&2
            echo -e "$message" | sed -e ${restripansicolor} >> "$LOG_FILE";            
            syslog_msg=$(echo -e "$message" | sed -e ${restripansicolor})
            [ $opt_syslog -eq 1 ] && logger -t "$PROGNAME" -p daemon.err "$syslog_msg"
            ;;

        *)  
            echo "$message" 1>&2
            echo -e "$message" | sed -e ${restripansicolor} >> "$LOG_FILE";            
            syslog_msg=$(echo -e "$message" | sed -e ${restripansicolor})
            [ $opt_syslog -eq 1 ] && logger -t "$PROGNAME" "$syslog_msg"
            ;;
    esac
}

function main(){    
    [ $# = 0 ] && usage;

    parse_opts "$@"

    #command
    case "$1" in
        version) echo "$VERSION";;
        help) usage "$@";;
        shutdown) do_shutdown "$@";; 
        *) usage;;
    esac

    exit 0;
}

main "$@"

