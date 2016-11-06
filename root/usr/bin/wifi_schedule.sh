#!/bin/sh

# Copyright (c) 2016, prpl Foundation
#
# Permission to use, copy, modify, and/or distribute this software for any purpose with or without
# fee is hereby granted, provided that the above copyright notice and this permission notice appear
# in all copies.
# 
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
# INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
# FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# Author: Nils Koenig <mail_openwrt@newk.it>

SCRIPT=$0
LOCKFILE=/tmp/wifi_schedule.lock
LOGFILE=/tmp/log/wifi_schedule.log
LOGGING=0 #default is off
PACKAGE=wifi_schedule

_log()
{
    if [ ${LOGGING} -eq 1 ]; then
        local ts=$(date)
        echo "$ts $@" >> ${LOGFILE}
    fi
}

_cron_restart()
{
    /etc/init.d/cron restart > /dev/null
}

_add_cron_script()
{
    (crontab -l ; echo "$1") | sort | uniq | crontab -
    _cron_restart
}

_rm_cron_script()
{
    crontab -l | grep -v "$1" |  sort | uniq | crontab -
    _cron_restart
}

_get_uci_value_raw()
{
    local value
    value=$(uci get $1 2> /dev/null)
    local rc=$?
    echo ${value}
    return ${rc}
}

_get_uci_value()
{
    local value
    value=$(_get_uci_value_raw $1)
    local rc=$?
    if [ ${rc} -ne 0 ]; then
        _log "Could not determine UCI value $1"
        _exit ${rc}
    fi
    echo ${value}
}

_format_dow_list()
{
    local dow=$1
    local flist=""
    for day in ${dow}
    do
        if [ ! -z ${flist} ]; then
            flist="${flist},"
        fi
        flist="${flist}${day:0:3}"
    done
    echo ${flist}
}


_enable_wifi_schedule()
{
    local entry=$1
    local starttime=$(_get_uci_value ${PACKAGE}.${entry}.starttime)
    local stoptime=$(_get_uci_value ${PACKAGE}.${entry}.stoptime)

    local dow
    dow=$(_get_uci_value_raw ${PACKAGE}.${entry}.daysofweek)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local fdow=$(_format_dow_list "$dow")

    local forcewifidown=$(_get_uci_value ${PACKAGE}.${entry}.forcewifidown)

    local stopmode="stop"
    if [ $forcewifidown -eq 1 ]; then
        stopmode="forcestop"
    fi


    local stop_cron_entry="$(echo ${stoptime} | awk -F':' '{print $2, $1}') * * ${fdow} ${SCRIPT} ${stopmode}" # ${entry}"
    _add_cron_script "${stop_cron_entry}"

    if [[ $starttime != $stoptime ]]                             
    then                                                         
        local start_cron_entry="$(echo ${starttime} | awk -F':' '{print $2, $1}') * * ${fdow} ${SCRIPT} start" # ${entry}"
        _add_cron_script "${start_cron_entry}"
#    else
#        _log "Wifi start time equals wifi stop time, this will deactivate wifi."
    fi

    return 0
}

_exit()
{
    local rc=$1
    lock -u ${LOCKFILE}
    exit ${rc}
}

_create_cron_entries()
{
    local entries=$(uci show ${PACKAGE} 2> /dev/null | awk -F'.' '{print $2}' | grep -v '=' | grep -v '@global\[0\]' | uniq | sort)
    for entry in ${entries}
    do 
        local status=$(_get_uci_value ${PACKAGE}.${entry}.enabled)
        if [ ${status} -eq 1 ]
        then
            _enable_wifi_schedule ${entry}
        fi
    done
}

check_cron_status()
{
    local global_enabled=$(_get_uci_value ${PACKAGE}.@global[0].enabled)
    _rm_cron_script "${SCRIPT}"
    if [ ${global_enabled} -eq 1 ]; then
        _create_cron_entries
    fi
}

disable_wifi()
{
    _rm_cron_script "${SCRIPT} recheck"
    /sbin/wifi down
}

soft_disable_wifi()
{
    local _disable_wifi=1
    local iwinfo=/usr/bin/iwinfo
    if [ ! -e ${iwinfo} ]; then
        echo "${iwinfo} not available, skipping"
        _exit 1
    fi

    local n=$(cat /proc/net/wireless | wc -l)
    interfaces=$(cat /proc/net/wireless | tail -n $(($n - 2))|awk -F':' '{print $1}')

    # check if no stations are associated
    for _if in $interfaces
    do
        output=$(${iwinfo} ${_if} assoclist)
        if [[ "$output" != "No station connected" ]]
        then
            _disable_wifi=0
            local stations=$(echo ${output}| grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | tr '\n' ' ')
            _log "Station(s) ${stations} associated on ${_if}"
        fi
    done

    if [ ${_disable_wifi} -eq 1 ]; then
        _log "No stations associated, disable wifi."
        disable_wifi
    else
        _log "Could not disable wifi due to associated stations, retrying..."
        local recheck_interval=$(_get_uci_value ${PACKAGE}.@global[0].recheck_interval)
        _add_cron_script "*/${recheck_interval} * * * * ${SCRIPT} recheck"
    fi
}

enable_wifi()
{
    _rm_cron_script "${SCRIPT} recheck"
    /sbin/wifi
}

usage()
{
    echo ""
    echo "$0 cron|start|stop|forcestop|recheck|help"
    echo ""
    echo "    cron: Create cronjob entries."
    echo "    start: Start wifi."
    echo "    stop: Stop wifi gracefully, i.e. check if there are stations associated and if so keep retrying."
    echo "    forcestop: Stop wifi immediately."
    echo "    recheck: Recheck if wifi can be disabled now."
    echo "    help: This description."
    echo ""
}

###############################################################################
# MAIN
###############################################################################
LOGGING=$(_get_uci_value ${PACKAGE}.@global[0].logging)
_log ${SCRIPT} $1 $2
lock ${LOCKFILE}

case "$1" in
    cron) check_cron_status ;;
    start) enable_wifi ;;
    forcestop) disable_wifi ;;
    stop) soft_disable_wifi ;;
    recheck) soft_disable_wifi ;;
    help|--help|-h) usage ;;
esac

_exit 0
