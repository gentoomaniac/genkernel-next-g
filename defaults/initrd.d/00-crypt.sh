#!/bin/sh

. /etc/initrd.d/00-common.sh
. /etc/initrd.d/00-devmgr.sh
. /etc/initrd.d/00-splash.sh
. /etc/initrd.d/00-fsdev.sh

CRYPTSETUP_BIN="/sbin/cryptsetup"
KEY_MNT="/mnt/key"

_bootstrap_key() {
    local ltype="${1}"
    local keydevs=$(device_list)

    eval local keyloc='"${CRYPT_'${ltype}'_KEY}"'

    media_find "key" "${keyloc}" "CRYPT_${ltype}_KEYDEV" "${KEY_MNT}" ${keydevs}
}

_crypt_exec() {
    local luks_dev="${1}"
    local cmd="${2}"

    if [ "${CRYPT_SILENT}" = "1" ]; then
        eval ${cmd} >/dev/null 2>/dev/null
    else
        ask_for_password --ply-tries 5 \
            --ply-cmd "${cmd}" \
            --ply-prompt "Encryption password (${luks_dev}): " \
            --tty-tries 5 \
            --tty-cmd "${cmd}" || return 1
        return 0
    fi
}

_open_luks() {
    case ${1} in
        root)
            local ltypes=ROOTS
            local ltype=ROOT
            ;;
        swap)
            local ltypes=SWAPS
            local ltype=SWAP
            ;;
    esac

    eval local luks_devices='"${CRYPT_'${ltypes}'}"'
    eval local luks_key='"${CRYPT_'${ltype}'_KEY}"'
    eval local luks_keydev='"${CRYPT_'${ltype}'_KEYDEV}"'
    eval local luks_trim='"${CRYPT_'${ltype}'_TRIM}"'

    local luks_name="${1}"

    local dev_error=0 key_error=0 keydev_error=0
    local mntkey="${KEY_MNT}/" cryptsetup_opts=""

    local real_dev=
    if [ "${ltype}" = "ROOT" ]; then
        real_dev="${REAL_ROOT}"
    elif [ "${ltype}" = "SWAP" ]; then
        real_dev="${REAL_RESUME}"
    fi

    local exit_st=0 luks_device=
    for luks_device in ${luks_devices}; do

        good_msg "Working on device ${luks_device}..."

        while true; do

            local gpg_cmd=""

            # do not force the link to /dev/mapper/root
            # but rather use the value from root=, which is
            # in ${REAL_ROOT}
            local luks_dev_name=$(basename "${luks_device}")
            local luks_name_prefix=

            if echo "${real_dev}" | grep -q "^/dev/mapper/"; then
                local real_dev_bn=$(basename "${real_dev}")
                # If we use LVM + cryptsetup, we may have collisions between
                # the two inside /dev/mapper. So, make up a way to avoid them.
                luks_dev_name="${luks_name}_${luks_dev_name}-${real_dev_bn}"
            fi

            # if crypt_silent=1 and some error occurs, bail out.
            local any_error=
            [ "${dev_error}" = "1" ] && any_error=1
            [ "${key_error}" = "1" ] && any_error=1
            [ "${keydev_error}" = "1" ] && any_error=1
            if [ "${CRYPT_SILENT}" = "1" ] && [ -n "${any_error}" ]; then
                bad_msg "Failed to setup the LUKS device"
                exit_st=1
                break
            fi

            if [ "${dev_error}" = "1" ]; then
                prompt_user "luks_device" "${luks_dev_name}"
                dev_error=0
                continue
            fi

            if [ "${key_error}" = "1" ]; then
                prompt_user "luks_key" "${luks_dev_name} key"
                key_error=0
                continue
            fi

            if [ "${keydev_error}" = "1" ]; then
                prompt_user "luks_keydev" "${luks_dev_name} key device"
                keydev_error=0
                continue
            fi

            local luks_dev=$(find_real_device "${luks_device}")
            [ -n "${luks_dev}" ] && \
                luks_device="${luks_dev}"  # otherwise hope...

            setup_md_device "${luks_device}"
            cryptsetup isLuks "${luks_device}" || {
                bad_msg "${luks_device} does not contain a LUKS header"
                dev_error=1
                continue;
            }

            # Handle keys
            if [ "${luks_trim}" = "yes" ]; then
                good_msg "Enabling TRIM support for ${luks_dev_name}."
                cryptsetup_opts="${cryptsetup_opts} --allow-discards"
            fi

            if [ -n "${luks_key}" ]; then
                local real_luks_keydev="${luks_keydev}"

                if [ ! -e "${mntkey}${luks_key}" ]; then
                    real_luks_keydev=$(find_real_device "${luks_keydev}")
                    good_msg "Using key device ${real_luks_keydev}."

                    if [ ! -b "${real_luks_keydev}" ]; then
                        bad_msg "Insert device ${luks_keydev} for ${luks_dev_name}"
                        bad_msg "You have 10 seconds..."
                        local count=10
                        while [ ${count} -gt 0 ]; do
                            count=$((count-1))
                            sleep 1

                            real_luks_keydev=$(find_real_device "${luks_keydev}")
                            [ ! -b "${real_luks_keydev}" ] || {
                                good_msg "Device ${real_luks_keydev} detected."
                                break;
                            }
                        done

                        if [ ! -b "${real_luks_keydev}" ]; then
                            eval CRYPT_${ltype}_KEY=${luks_key}
                            _bootstrap_key ${ltype}
                            eval luks_keydev='"${CRYPT_'${ltype}'_KEYDEV}"'

                            real_luks_keydev=$(find_real_device "${luks_keydev}")
                            if [ ! -b "${real_luks_keydev}" ]; then
                                keydev_error=1
                                bad_msg "Device ${luks_keydev} not found."
                                continue
                            fi

                            # continue otherwise will mount keydev which is
                            # mounted by bootstrap
                            continue
                        fi
                    fi

                    # At this point a device was recognized, now let's see
                    # if the key is there
                    mkdir -p "${mntkey}"  # ignore

                    mount -n -o ro "${real_luks_keydev}" \
                        "${mntkey}" || {
                        keydev_error=1
                        bad_msg "Mounting of device ${real_luks_keydev} failed."
                        continue;
                    }

                    good_msg "Removable device ${real_luks_keydev} mounted."

                    if [ ! -e "${mntkey}${luks_key}" ]; then
                        umount -n "${mntkey}"
                        key_error=1
                        keydev_error=1
                        bad_msg "{luks_key} on ${real_luks_keydev} not found."
                        continue
                    fi
                fi

                # At this point a candidate key exists
                # (either mounted before or not)
                good_msg "${luks_key} on device ${real_luks_keydev} found"
                if [ "$(echo ${luks_key} | grep -o '.gpg$')" = ".gpg" ] && \
                    [ -e /usr/bin/gpg ]; then

                    # TODO(lxnay): WTF is this?
                    [ -e /dev/tty ] && mv /dev/tty /dev/tty.org
                    mknod /dev/tty c 5 1

                    cryptsetup_opts="${cryptsetup_opts} -d -"
                    gpg_cmd="/usr/bin/gpg --logger-file /dev/null"
                    gpg_cmd="${gpg_cmd} --quiet --decrypt ${mntkey}${luks_key} | "
                else
                    cryptsetup_opts="${cryptsetup_opts} -d ${mntkey}${luks_key}"
                fi
            fi

            # At this point, keyfile or not, we're ready!
            local cmd="${gpg_cmd}${CRYPTSETUP_BIN}"
            cmd="${cmd} ${cryptsetup_opts} open ${luks_device} ${luks_dev_name}"
            _crypt_exec "${luks_device}" "${cmd}"
            local ret="${?}"

            # TODO(lxnay): WTF is this?
            [ -e /dev/tty.org ] \
                && rm -f /dev/tty \
                && mv /dev/tty.org /dev/tty

            if [ "${ret}" = "0" ]; then
                good_msg "LUKS device ${luks_device} opened"

                # Note 1: This is fine if the crypt device is a physical device
                # like /dev/sdaX, however, if we have cryptsetup inside
                # LVM, we must tweak REAL_ROOT if there is no device node.
                # Note 2: we should not activate md arrays yet, because
                # they could be started in degraded mode and mdadm is so stupid
                # that it may end up creating multiple md devices with the
                # same UUID... Let's postpone this for the end
                (   USE_MDADM=0
                    USE_DMRAID_NORMAL=0
                    start_volumes # this creates /dev/mapper links
                )
                if echo "${real_dev}" | grep -q "^/dev/mapper/"; then
                    if [ ! -e "${real_dev}" ]; then
                        # WARN: while for ltype=SWAP this may not be a problem,
                        # for ltype=ROOT this may render the system unbootable
                        # because lvm can get angry to see a symlink where it's
                        # not supposed to be or we may fail to create the proper
                        # link (due to the if above), however, reordering the
                        # cmdline entries may solve this.
                        good_msg "Creating symlink ${luks_dev_name} -> ${real_dev}"
                        ln -s "${luks_dev_name}" "${real_dev}" || exit_st=1
                    fi
                fi

                break
            fi

            bad_msg "Failed to open LUKS device ${luks_device}"
            dev_error=1
            key_error=1
            keydev_error=1

        done

    done

    umount -l "${mntkey}" 2>/dev/null >/dev/null
    rmdir "${mntkey}" 2>/dev/null >/dev/null

    return ${exit_st}
}

start_luks() {
    if [ ! -e "${CRYPTSETUP_BIN}" ]; then
        bad_msg "${CRYPTSETUP_BIN} not found inside the initramfs"
        return 1
    fi

    local root_or_swap=

    # if key is set but key device isn't, find it
    [ -n "${CRYPT_ROOT_KEY}" ] && [ -z "${CRYPT_ROOT_KEYDEV}" ] \
        && _bootstrap_key "ROOT"

    if [ -n "${CRYPT_ROOTS}" ]; then
        root_or_swap=1
        if _open_luks "root"; then
            # force REAL_ROOT= to some value if not set
            # this is mainly for backward compatibility,
            # because grub2 always sets a valid root=
            # and user must have it as well.
            [ -z "${REAL_ROOT}" ] && REAL_ROOT="/dev/mapper/root"
        fi
    fi

    [ -n "${CRYPT_SWAP_KEY}" ] && [ -z "${CRYPT_SWAP_KEYDEV}" ] \
        && _bootstrap_key "SWAP"

    if [ -n "${CRYPT_SWAPS}" ]; then
        root_or_swap=1
        if _open_luks "swap"; then
            # force REAL_RESUME= to some value if not set
            [ -z "${REAL_RESUME}" ] && REAL_RESUME="/dev/mapper/swap"
        fi
    fi

    if [ -n "${root_or_swap}" ]; then
        # We postponed the initialization of raid devices
        # in order to avoid to assemble possibly degraded
        # arrays.
        start_md_volumes
    fi
}