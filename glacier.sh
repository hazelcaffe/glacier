#!/bin/bash
#
# glacier -- dual-boot groundwork for Chromebooks.
#
#   * resize the ChromeOS stateful partition, non-destructively, to free
#     space on the internal disk
#   * install the Glacier boot environment into the unused KERN-C / ROOT-C
#     partition slots
#
# ROOT-A is never written to and rootfs verification stays on unless you
# explicitly ask for it. Developer mode is the only prerequisite.
#
# Run as root from VT2 (Ctrl+Alt+Right-arrow / F2) in developer mode.
#
# Standing on the shoulders of:
#   chrultrabook/crap        -- the pre-shutdown unmount sequence
#   reynhout/chrx            -- the original setup-storage approach
#   bendavis78's gist        -- the e2fsck/resize2fs/cgpt ordering
#   ethanmad/chromeos-resize -- prior art
#   chromeos-common.sh       -- device naming rules

GLACIER_LIB=${GLACIER_LIB:-$(cd "$(dirname "$(readlink -f "$0")")/../lib" 2>/dev/null && pwd)}
GLACIER_PAYLOAD=${GLACIER_PAYLOAD:-$(cd "$(dirname "$(readlink -f "$0")")/../payload" 2>/dev/null && pwd)}
# --- begin inlined libraries (tools/bundle.sh) ---
#
# Glacier :: lib/ui.sh -- terminal chrome and the interactive size slider.
#
# Everything in here has to work on a bare ChromeOS VT2 (frecon): ANSI escapes
# only, no terminfo, no ncurses, no tput.

: "${GLACIER_ASCII:=0}"
: "${GLACIER_NO_COLOR:=0}"

ui_init() {
	if [ "$GLACIER_NO_COLOR" = 1 ] || [ ! -t 1 ]; then
		C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN=''
	else
		C_RESET=$'\033[0m'
		C_DIM=$'\033[2m'
		C_BOLD=$'\033[1m'
		C_RED=$'\033[1;31m'
		C_GRN=$'\033[1;32m'
		C_YEL=$'\033[1;33m'
		C_BLU=$'\033[1;34m'
		C_CYN=$'\033[1;36m'
	fi

	# frecon handles UTF-8, but serial consoles and `script` captures may not.
	if [ "$GLACIER_ASCII" = 1 ]; then
		G_FULL='#' G_SLACK='=' G_FREE='.'
		G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|' G_TD='+' G_BU='+'
	else
		G_FULL='#' G_SLACK=':' G_FREE='.'
		G_FULL=$'█' G_SLACK=$'▒' G_FREE=$'░'
		G_TL=$'┌' G_TR=$'┐' G_BL=$'└' G_BR=$'┘'
		G_H=$'─' G_V=$'│' G_TD=$'┬' G_BU=$'┴'
	fi
	ui_cols
}

# Terminal width, clamped to something a VT2 can actually render.
ui_cols() {
	local size
	size=$(stty size 2>/dev/null) || size=''
	UI_COLS=${size#* }
	case "$UI_COLS" in '' | *[!0-9]*) UI_COLS=${COLUMNS:-80} ;; esac
	[ "$UI_COLS" -lt 62 ] && UI_COLS=62
	[ "$UI_COLS" -gt 100 ] && UI_COLS=100
}

ui_repeat() { # <string> <count>
	local out='' i=0
	[ "${2:-0}" -le 0 ] && return 0
	while [ "$i" -lt "$2" ]; do
		out="$out$1"
		i=$((i + 1))
	done
	printf '%s' "$out"
}

ui_rule() { ui_repeat "$G_H" "$((UI_COLS - 2))"; }

# Bytes -> "58.2 GiB". Integer-only bash can't do this, so lean on awk.
fmt_size() {
	awk -v b="${1:-0}" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1; v = b + 0
		while (v >= 1024 && i < 5) { v /= 1024; i++ }
		if (i == 1) printf "%d %s", v, u[i]
		else printf "%.1f %s", v, u[i]
	}'
}

say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C_CYN" "$C_RESET" "$*"; }
good() { printf '%s[ok]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
oops() { printf '%s[xx]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

ui_clear() { printf '\033[H\033[2J'; }

ui_title() {
	printf '%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
	printf '%s%s%s\n' "$C_DIM" "$(ui_rule)" "$C_RESET"
}

ui_pause() {
	printf '\n%sPress enter to continue.%s ' "$C_DIM" "$C_RESET"
	read -r _ || :
	printf '\n'
}

ui_confirm() { # <prompt> -> 0 if the user typed exactly y/yes
	local reply
	printf '%s%s%s %s(y/N)%s ' "$C_CYN" "$1" "$C_RESET" "$C_YEL" "$C_RESET"
	read -r reply || return 1
	case "$reply" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# Make the user type a specific word. Used only for destructive paths, where a
# reflexive "y" is exactly the mistake we are trying to prevent.
ui_confirm_phrase() { # <word> <prompt>
	local reply
	printf '%s%s%s\n' "$C_RED" "$2" "$C_RESET"
	printf 'Type %s%s%s to proceed, anything else to abort: ' "$C_BOLD" "$1" "$C_RESET"
	read -r reply || return 1
	[ "$reply" = "$1" ]
}

# Read one keypress, decoding the escape sequences we care about into names.
ui_key() {
	local k rest
	IFS= read -rsn1 k || return 1
	case "$k" in
		'') printf 'enter'; return 0 ;;
		$'\033')
			# Could be a bare ESC or the start of a CSI sequence.
			IFS= read -rsn2 -t 0.05 rest || { printf 'escape'; return 0; }
			case "$rest" in
				'[C') printf 'right' ;;
				'[D') printf 'left' ;;
				'[A') printf 'up' ;;
				'[B') printf 'down' ;;
				'[H') printf 'home' ;;
				'[F') printf 'end' ;;
				'[5') IFS= read -rsn1 -t 0.05 _ || :; printf 'pgup' ;;
				'[6') IFS= read -rsn1 -t 0.05 _ || :; printf 'pgdn' ;;
				*) printf 'escape' ;;
			esac
			;;
		*) printf '%s' "$k" ;;
	esac
}

# Parse a human size against a total. Accepts 20G, 500M, 25%, 25%a.
# $1 = text, $2 = disk total bytes, $3 = available-region bytes.
# Echoes bytes, returns 1 if unparseable.
parse_size() {
	local txt=$1 total=$2 avail=$3 n
	n=${txt//[^0-9]/}
	[ -z "$n" ] && return 1
	case "$txt" in
		*.*) return 1 ;;
		[0-9]*%[aA]) printf '%s' "$((n * avail / 100))" ;;
		[0-9]*%)     printf '%s' "$((n * total / 100))" ;;
		[0-9]*[gG])  printf '%s' "$((n * 1024 * 1024 * 1024))" ;;
		[0-9]*[mM])  printf '%s' "$((n * 1024 * 1024))" ;;
		[0-9]*[tT])  printf '%s' "$((n * 1024 * 1024 * 1024 * 1024))" ;;
		*) return 1 ;;
	esac
}

#
# The slider.
#
# ui_slider <used_bytes> <min_bytes> <max_bytes> <current_bytes>
#
# Draws stateful as a bar that fills the whole region stateful is allowed to
# occupy, split at a movable divider: everything left of the divider stays with
# ChromeOS, everything right of it becomes free space. Sets SLIDER_BYTES and
# returns 0 on accept, 1 on cancel.
#
SLIDER_BYTES=0
ui_slider() {
	local used=$1 min=$2 max=$3 cur=$4
	local w pos used_cells step coarse key drawn=0 typed
	local left_full left_slack

	w=$((UI_COLS - 8))
	[ "$w" -gt 72 ] && w=72

	step=$((512 * 1024 * 1024))         # arrow keys: 512 MiB
	coarse=$((4 * 1024 * 1024 * 1024))  # page keys: 4 GiB

	[ "$cur" -lt "$min" ] && cur=$min
	[ "$cur" -gt "$max" ] && cur=$max

	printf '\033[?25l'  # hide cursor

	while :; do
		# Divider position, kept strictly inside the box so both sides stay visible.
		pos=$((cur * w / max))
		[ "$pos" -lt 1 ] && pos=1
		[ "$pos" -gt $((w - 1)) ] && pos=$((w - 1))

		used_cells=$((used * w / max))
		[ "$used_cells" -gt "$pos" ] && used_cells=$pos
		[ "$used_cells" -lt 1 ] && used_cells=1

		left_full=$(ui_repeat "$G_FULL" "$used_cells")
		left_slack=$(ui_repeat "$G_SLACK" "$((pos - used_cells))")

		[ "$drawn" -eq 1 ] && printf '\033[8A'
		drawn=1

		printf '\033[2K  %sChromeOS stateful%s%*s%sfree for Glacier%s\n' \
			"$C_CYN" "$C_RESET" \
			$((w - 33)) '' "$C_BLU" "$C_RESET"
		printf '\033[2K  %s%s%s%s%s\n' "$G_TL" \
			"$(ui_repeat "$G_H" "$pos")" "$G_TD" "$(ui_repeat "$G_H" "$((w - pos))")" "$G_TR"
		printf '\033[2K  %s%s%s%s%s%s%s%s%s\n' "$G_V" \
			"$C_GRN" "$left_full" "$C_DIM$left_slack$C_RESET" "$G_V" \
			"$C_BLU" "$(ui_repeat "$G_FREE" "$((w - pos))")" "$C_RESET" "$G_V"
		printf '\033[2K  %s%s%s%s%s\n' "$G_BL" \
			"$(ui_repeat "$G_H" "$pos")" "$G_BU" "$(ui_repeat "$G_H" "$((w - pos))")" "$G_BR"

		printf '\033[2K  %s%-22s%s  %s%s%s\n' \
			"$C_GRN" "$(fmt_size "$cur")" "$C_RESET" \
			"$C_BLU" "$(fmt_size "$((max - cur))")" "$C_RESET"
		printf '\033[2K  %s%s in use   %s slack   %s free   (floor %s, ceiling %s)%s\n' \
			"$C_DIM" "$(fmt_size "$used")" "$(fmt_size "$((cur - used))")" \
			"$(fmt_size "$((max - cur))")" "$(fmt_size "$min")" "$(fmt_size "$max")" "$C_RESET"
		printf '\033[2K\n'
		printf '\033[2K  %s<-/->%s 512M  %sPgUp/PgDn%s 4G  %sHome/End%s min/max  %st%s type  %sEnter%s apply  %sq%s cancel\n' \
			"$C_YEL" "$C_RESET" "$C_YEL" "$C_RESET" "$C_YEL" "$C_RESET" \
			"$C_YEL" "$C_RESET" "$C_YEL" "$C_RESET" "$C_YEL" "$C_RESET"

		key=$(ui_key) || { printf '\033[?25h'; return 1; }
		case "$key" in
			left|h)  cur=$((cur - step)) ;;
			right|l) cur=$((cur + step)) ;;
			down|pgdn) cur=$((cur - coarse)) ;;
			up|pgup)   cur=$((cur + coarse)) ;;
			home) cur=$min ;;
			end)  cur=$max ;;
			t|T)
				printf '\033[?25h'
				printf '\n  New stateful size (e.g. 32G, 40%%a): '
				read -r typed || typed=''
				if typed=$(parse_size "$typed" "$max" "$max"); then
					cur=$typed
				else
					warn 'Could not parse that size.'
					sleep 1
				fi
				printf '\033[?25l'
				drawn=0
				ui_clear
				;;
			enter)
				printf '\033[?25h'
				SLIDER_BYTES=$cur
				return 0
				;;
			q|Q|escape)
				printf '\033[?25h'
				return 1
				;;
		esac
		[ "$cur" -lt "$min" ] && cur=$min
		[ "$cur" -gt "$max" ] && cur=$max
	done
}

#
# Glacier :: lib/common.sh -- environment guards and small shared helpers.

GLACIER_VERSION='0.1.0'

# Set GLACIER_DRY_RUN=1 to print every mutating command instead of running it.
: "${GLACIER_DRY_RUN:=0}"
: "${GLACIER_LOG:=/tmp/glacier.log}"

IS_CROS=0
if [ -f /etc/lsb-release ] &&
	grep -qi '\(Chrome OS\|Chromium OS\|CHROMEOS\|neverware\)' /etc/lsb-release; then
	IS_CROS=1
fi

die() {
	oops "$*"
	exit 1
}

log() {
	printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$GLACIER_LOG" 2>/dev/null || :
}

# Every command that writes to the disk goes through run(), so that dry-run
# mode is total rather than best-effort.
run() {
	log "RUN: $*"
	if [ "$GLACIER_DRY_RUN" = 1 ]; then
		printf '%s(dry-run)%s %s\n' "$C_YEL" "$C_RESET" "$*"
		return 0
	fi
	"$@"
}

# Same, but swallow output unless GLACIER_DEBUG=1.
run_quiet() {
	log "RUN: $*"
	if [ "$GLACIER_DRY_RUN" = 1 ]; then
		printf '%s(dry-run)%s %s\n' "$C_YEL" "$C_RESET" "$*"
		return 0
	fi
	if [ "${GLACIER_DEBUG:-0}" = 1 ]; then
		"$@"
	else
		"$@" >>"$GLACIER_LOG" 2>&1
	fi
}

have() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
	local missing='' c
	for c in "$@"; do
		have "$c" || missing="$missing $c"
	done
	[ -n "$missing" ] && die "Missing required commands:$missing"
	return 0
}

# ChromeOS's VT2 shell is the only place this is safe to run. crosh is a
# restricted shell; the resize steps will fail there in confusing ways.
require_root_vt() {
	readlink "/proc/$$/exe" 2>/dev/null | grep -q bash ||
		die 'Please run this with bash.'
	[ -t 0 ] ||
		die 'Do not pipe this into bash -- run it as "bash <(curl ...)" so stdin stays a terminal.'
	[ "$(id -u)" -eq 0 ] ||
		die 'Please run as root (log in as "root" on VT2, not "chronos").'

	local gp
	gp=$(ps -o ppid= "$PPID" 2>/dev/null | tr -d '[:space:]')
	if [ -n "$gp" ] && readlink "/proc/$gp/exe" 2>/dev/null | grep -q crosh; then
		die 'Run this from VT2, not from crosh. Press [Ctrl]+[Alt]+[->] (F2) and log in as root.'
	fi
	return 0
}

# Integer ceiling division; used constantly when converting bytes to sectors.
div_up() { printf '%s' "$((($1 + $2 - 1) / $2))"; }

# If we were started from a file that lives on the stateful partition, bash
# would lose the rest of the script the moment that partition is unmounted --
# it reads scripts incrementally. Re-exec from tmpfs first.
#
# A process substitution (bash <(curl ...)) is already safe: it is a pipe fed
# from the network, not from the disk we are about to take apart.
self_relocate() {
	local src tmp d
	[ "${GLACIER_RELOCATED:-0}" = 1 ] && return 0
	src=$(readlink -f "$0" 2>/dev/null) || return 0
	[ -f "$src" ] || return 0
	case "$src" in
		/mnt/stateful_partition/* | /usr/local/* | /home/* | /var/*) ;;
		*) return 0 ;;
	esac
	for d in /dev/shm /tmp /run; do
		[ -d "$d" ] && [ -w "$d" ] || continue
		tmp="$d/glacier.$$"
		cp -f "$src" "$tmp" 2>/dev/null || continue
		chmod +x "$tmp" 2>/dev/null || :
		info "Running from $tmp so an unmount cannot pull this script away."
		GLACIER_RELOCATED=1 GLACIER_LIB="$GLACIER_LIB" \
			GLACIER_PAYLOAD="${GLACIER_PAYLOAD:-}" exec bash "$tmp" "$@"
	done
	warn 'Could not copy myself to tmpfs; continuing from stateful.'
	return 0
}

#
# Glacier :: lib/disk.sh -- a layout-agnostic view of the ChromeOS GPT.
#
# Nothing here hardcodes a ChromeOS disk layout version. v1 (legacy), v2 (most
# shipping devices) and v3 (MiniOS) differ in which partitions exist, their
# sizes, and crucially their ORDER on disk -- in v3, MINIOS-B is the
# "last_partition" and sits *after* STATE, so STATE is no longer the tail of
# the disk. We therefore read the live GPT and reason about neighbours by start
# sector, which is correct for all three and for whatever comes next.
#
# Likewise nothing assumes /dev/mmcblk0 or a 512-byte sector: eMMC, NVMe, UFS
# and plain SATA all show up here, and 4Kn NVMe is a real possibility.

# --- device naming -----------------------------------------------------------

# /dev/sda + 3 -> /dev/sda3, but /dev/mmcblk0 + 3 -> /dev/mmcblk0p3.
# Same rule as chromeos-common.sh's make_partition_dev().
part_dev() { # <disk> <partnum>
	case "$1" in
		*[0-9]) printf '%sp%s' "$1" "$2" ;;
		*) printf '%s%s' "$1" "$2" ;;
	esac
}

# Reverse: /dev/nvme0n1p3 -> /dev/nvme0n1, /dev/sda3 -> /dev/sda.
disk_of_part() {
	local rest
	rest=$(printf '%s' "$1" | sed -e 's/[0-9]*$//')
	printf '%s' "${rest%p}"
}

# --- disk discovery ----------------------------------------------------------

# Pick the largest fixed (non-removable) block device that actually carries a
# ChromeOS GPT. Works for mmcblk*, nvme*, sd* (SATA and UFS) alike, because we
# identify by partition labels rather than by device name.
find_cros_disk() {
	local best='' best_size=0 sysdev name dev size removable
	for sysdev in /sys/block/*; do
		name=${sysdev##*/}
		case "$name" in
			loop* | ram* | zram* | dm-* | sr* | md* | fd*) continue ;;
		esac
		dev="/dev/$name"
		[ -b "$dev" ] || continue
		size=$(cat "$sysdev/size" 2>/dev/null) || continue
		[ "${size:-0}" -gt 0 ] || continue
		removable=$(cat "$sysdev/removable" 2>/dev/null || echo 0)
		[ "${removable:-0}" -eq 0 ] || continue
		gpt_is_cros_disk "$dev" || continue
		if [ "$size" -gt "$best_size" ]; then
			best=$dev
			best_size=$size
		fi
	done
	[ -n "$best" ] || return 1
	printf '%s' "$best"
}

gpt_is_cros_disk() {
	cgpt show -q -n "$1" >/dev/null 2>&1 || return 1
	# A ChromeOS disk always has these three, in every layout version.
	cgpt find -l STATE "$1" >/dev/null 2>&1 || return 1
	cgpt find -l KERN-A "$1" >/dev/null 2>&1 || return 1
	cgpt find -l ROOT-A "$1" >/dev/null 2>&1 || return 1
	return 0
}

# --- geometry ----------------------------------------------------------------

# Logical sector size. Never assume 512 -- 4Kn NVMe exists.
disk_sector_size() {
	local ss
	ss=$(cat "/sys/block/${1##*/}/queue/logical_block_size" 2>/dev/null)
	case "$ss" in '' | *[!0-9]*)
		ss=$(blockdev --getss "$1" 2>/dev/null)
		;;
	esac
	case "$ss" in '' | *[!0-9]*) ss=512 ;; esac
	printf '%s' "$ss"
}

# Size of the whole device in its own logical sectors. /sys/block/*/size is
# always in 512-byte units regardless of logical block size, so go via bytes.
disk_sectors() {
	local bytes
	bytes=$(blockdev --getsize64 "$1" 2>/dev/null)
	case "$bytes" in '' | *[!0-9]*) return 1 ;; esac
	printf '%s' "$((bytes / $(disk_sector_size "$1")))"
}

# --- partition table ---------------------------------------------------------

gpt_part_numbers() { cgpt show -q -n "$1" 2>/dev/null | awk '{print $3}' | sort -n; }

part_start() { cgpt show -i "$2" -b -q -n "$1" 2>/dev/null; }
part_size()  { cgpt show -i "$2" -s -q -n "$1" 2>/dev/null; }
part_label() { cgpt show -i "$2" -l -q -n "$1" 2>/dev/null; }
part_uuid()  { cgpt show -i "$2" -u -q -n "$1" 2>/dev/null; }
part_type()  { cgpt show -i "$2" -t -q -n "$1" 2>/dev/null; }

# Partition number carrying <label>, e.g. STATE / KERN-C / ROOT-C.
# Resolved by label so that layout differences in numbering cannot bite us.
part_num_by_label() { # <disk> <label>
	local n
	for n in $(gpt_part_numbers "$1"); do
		if [ "$(part_label "$1" "$n")" = "$2" ]; then
			printf '%s' "$n"
			return 0
		fi
	done
	return 1
}

# Start sector of the secondary GPT table -- a hard ceiling for any partition.
gpt_sec_table_start() { # <disk>
	local s
	s=$(cgpt show "$1" 2>/dev/null | awk '/Sec GPT table/ {print $1; exit}')
	case "$s" in '' | *[!0-9]*) disk_sectors "$1" ;; *) printf '%s' "$s" ;; esac
}

# First sector NOT available to a partition starting at <start>: either the
# next partition's start, or the secondary GPT table. This is what bounds how
# far STATE may grow, and it is the piece that makes v3 (MINIOS-B after STATE)
# work with no special-casing at all.
gpt_next_boundary() { # <disk> <start>
	local disk=$1 start=$2 s best='' n
	for n in $(gpt_part_numbers "$disk"); do
		s=$(part_start "$disk" "$n")
		case "$s" in '' | *[!0-9]*) continue ;; esac
		[ "$s" -le "$start" ] && continue
		if [ -z "$best" ] || [ "$s" -lt "$best" ]; then best=$s; fi
	done
	s=$(gpt_sec_table_start "$disk")
	if [ "$s" -gt "$start" ] && { [ -z "$best" ] || [ "$s" -lt "$best" ]; }; then
		best=$s
	fi
	[ -n "$best" ] || return 1
	printf '%s' "$best"
}

# Largest run of unallocated sectors, as "<start> <length>".
gpt_largest_gap() { # <disk>
	local disk=$1 n s sz sec_start gap e
	local best_start=0 best_len=0 prev_end=0 first=1
	local -a edges=()

	for n in $(gpt_part_numbers "$disk"); do
		s=$(part_start "$disk" "$n")
		sz=$(part_size "$disk" "$n")
		case "$s$sz" in '' | *[!0-9]*) continue ;; esac
		edges+=("$s $((s + sz))")
	done
	[ "${#edges[@]}" -gt 0 ] || { printf '0 0'; return 1; }

	sec_start=$(gpt_sec_table_start "$disk")

	while read -r s e; do
		[ -z "$s" ] && continue
		if [ "$first" = 1 ]; then
			prev_end=$e
			first=0
			continue
		fi
		gap=$((s - prev_end))
		if [ "$gap" -gt "$best_len" ]; then
			best_len=$gap
			best_start=$prev_end
		fi
		[ "$e" -gt "$prev_end" ] && prev_end=$e
	done < <(printf '%s\n' "${edges[@]}" | sort -n)

	gap=$((sec_start - prev_end))
	if [ "$gap" -gt "$best_len" ]; then
		best_len=$gap
		best_start=$prev_end
	fi
	printf '%s %s' "$best_start" "$best_len"
}

# Tell the kernel a partition's geometry changed. partx is the least invasive
# way to do this on a disk whose other partitions are still mounted.
reread_part() { # <disk> <partnum>
	if have partx; then
		run_quiet partx -u -n "$2" "$1" || run_quiet partx -u "$1" || :
	elif have blockdev; then
		run_quiet blockdev --rereadpt "$1" || :
	fi
	have udevadm && run_quiet udevadm settle || :
	return 0
}

print_disk_map() { # <disk> <sector_size>
	local disk=$1 ss=$2 n s sz lbl
	printf '  %-3s %-15s %12s %12s\n' 'NR' 'LABEL' 'START' 'SIZE'
	for n in $(gpt_part_numbers "$disk"); do
		s=$(part_start "$disk" "$n")
		sz=$(part_size "$disk" "$n")
		lbl=$(part_label "$disk" "$n")
		printf '  %-3s %-15s %12s %12s\n' "$n" "$lbl" "$s" "$(fmt_size "$((sz * ss))")"
	done
}

#
# Glacier :: lib/stateful.sh -- probing and resizing the ChromeOS stateful
# partition.
#
# Two shapes exist in the wild:
#
#   plain : partition 1 is an ext4 filesystem. Fully supported.
#   lvm   : partition 1 is an LVM2 PV holding a thin pool ("thinpool") with a
#           thin volume ("unencrypted") carrying the ext4. Detected, and then
#           refused.
#
# Why LVM is refused rather than half-supported: ChromeOS sizes the thin pool
# at 98% of the partition (platform2 init/clobber/clobber_lvm.cc), and no tool
# that ships on a Chromebook can shrink a thin pool -- lvreduce rejects it
# outright. Only the sliver of the physical volume that no extent occupies can
# be handed back, which measured 57 MiB on a 5.8 GiB stateful. That is not
# worth the risk of running resize logic near someone's data, so the tool stops
# and says so.
#
# Detection stays regardless of support, and that is the important part: it is
# what stops ext4 logic from ever being pointed at an LVM physical volume.

ST_KIND='unknown'

lvm_ok() { have lvm || have pvs; }

# ChromeOS ships the lvm multi-call binary; some images only expose `lvm pvs`.
lvmx() {
	if have "$1"; then
		"$@"
	else
		lvm "$@"
	fi
}

# --- probing -----------------------------------------------------------------

stateful_probe() { # <disk> <sector_size>
	local disk=$1 ss=$2 boundary

	ST_NUM=$(part_num_by_label "$disk" STATE) || return 1
	ST_PART=$(part_dev "$disk" "$ST_NUM")
	ST_START=$(part_start "$disk" "$ST_NUM")
	ST_SECTORS=$(part_size "$disk" "$ST_NUM")
	ST_BYTES=$((ST_SECTORS * ss))

	# How far STATE may extend before colliding with whatever follows it --
	# another partition (v3: MINIOS-B) or the secondary GPT table.
	boundary=$(gpt_next_boundary "$disk" "$ST_START") || boundary=$((ST_START + ST_SECTORS))
	ST_CEIL_SECTORS=$((boundary - ST_START - 1))
	[ "$ST_CEIL_SECTORS" -lt "$ST_SECTORS" ] && ST_CEIL_SECTORS=$ST_SECTORS
	ST_CEIL_BYTES=$((ST_CEIL_SECTORS * ss))

	ST_VG='' ST_LV='' ST_POOL=''
	case "$(blkid -o value -s TYPE "$ST_PART" 2>/dev/null)" in
		LVM2_member) ST_KIND='lvm' ;;
		ext2 | ext3 | ext4) ST_KIND='plain' ;;
		*)
			if lvm_ok && lvmx pvs --noheadings "$ST_PART" >/dev/null 2>&1; then
				ST_KIND='lvm'
			elif tune2fs -l "$ST_PART" >/dev/null 2>&1; then
				ST_KIND='plain'
			else
				ST_KIND='unknown'
			fi
			;;
	esac

	case "$ST_KIND" in
		plain) stateful_probe_plain ;;
		lvm) stateful_probe_lvm ;;
		*)
			ST_FS_DEV=''
			ST_USED_BYTES=0
			ST_MIN_BYTES=$ST_BYTES
			;;
	esac
	return 0
}

stateful_probe_plain() {
	local info bs total free minblocks
	ST_FS_DEV=$ST_PART
	info=$(tune2fs -l "$ST_PART" 2>/dev/null) || {
		ST_KIND='unknown'
		ST_USED_BYTES=0
		ST_MIN_BYTES=$ST_BYTES
		return 1
	}
	bs=$(printf '%s\n' "$info" | awk '/^Block size:/ {print $3; exit}')
	total=$(printf '%s\n' "$info" | awk '/^Block count:/ {print $3; exit}')
	free=$(printf '%s\n' "$info" | awk '/^Free blocks:/ {print $3; exit}')
	ST_BLOCK_SIZE=${bs:-4096}
	ST_USED_BYTES=$(((total - free) * ST_BLOCK_SIZE))

	# resize2fs' own estimate is the real floor; fall back to live usage.
	minblocks=$(resize2fs -P "$ST_FS_DEV" 2>/dev/null |
		awk '/Estimated minimum size/ {print $NF; exit}')
	case "$minblocks" in '' | *[!0-9]*) minblocks=$((total - free)) ;; esac
	ST_MIN_BYTES=$((minblocks * ST_BLOCK_SIZE))
	stateful_pad_floor
	return 0
}

# Resizing an ext4 to its exact theoretical minimum leaves a 100%-full
# filesystem that ChromeOS cannot boot into. Keep real headroom.
stateful_pad_floor() {
	local pad=$((ST_MIN_BYTES / 10))
	local gib=$((1024 * 1024 * 1024))
	[ "$pad" -lt "$gib" ] && pad=$gib
	ST_MIN_BYTES=$((ST_MIN_BYTES + pad))
	[ "$ST_MIN_BYTES" -gt "$ST_BYTES" ] && ST_MIN_BYTES=$ST_BYTES
}

# Identify the LVM stack well enough to tell the user what they have. No
# resizing happens on this path.
stateful_probe_lvm() {
	ST_FS_DEV=''
	ST_USED_BYTES=0
	ST_MIN_BYTES=$ST_BYTES # nothing is reclaimable without a rebuild

	lvm_ok || return 1

	ST_VG=$(lvmx pvs --noheadings -o vg_name "$ST_PART" 2>/dev/null | tr -d '[:space:]')
	[ -n "$ST_VG" ] || return 1

	ST_POOL=$(lvmx lvs --noheadings -o lv_name "$ST_VG" 2>/dev/null |
		awk '{$1=$1; print}' | grep -x 'thinpool' | head -1)
	ST_LV=$(lvmx lvs --noheadings -o lv_name "$ST_VG" 2>/dev/null |
		awk '{$1=$1; print}' | grep -x 'unencrypted' | head -1)
	[ -n "$ST_LV" ] && ST_FS_DEV="/dev/$ST_VG/$ST_LV"

	if [ -n "$ST_FS_DEV" ] && [ -b "$ST_FS_DEV" ]; then
		local info bs total free
		if info=$(tune2fs -l "$ST_FS_DEV" 2>/dev/null); then
			bs=$(printf '%s\n' "$info" | awk '/^Block size:/ {print $3; exit}')
			total=$(printf '%s\n' "$info" | awk '/^Block count:/ {print $3; exit}')
			free=$(printf '%s\n' "$info" | awk '/^Free blocks:/ {print $3; exit}')
			ST_BLOCK_SIZE=${bs:-4096}
			ST_USED_BYTES=$(((total - free) * ST_BLOCK_SIZE))
		fi
	fi
	return 0
}

# --- unmounting --------------------------------------------------------------

stateful_is_mounted() {
	grep -q "^${ST_PART}[[:space:]]" /proc/mounts && return 0
	[ -n "${ST_FS_DEV:-}" ] && grep -q "^${ST_FS_DEV}[[:space:]]" /proc/mounts && return 0
	grep -q '[[:space:]]/mnt/stateful_partition[[:space:]]' /proc/mounts && return 0
	return 1
}

# Tear the running session down far enough that stateful is genuinely closed.
#
# A lazy unmount (umount -l) looks like it works and is the classic way people
# corrupt their stateful partition: the filesystem stays live and dirty behind
# the detached mountpoint while resize2fs rewrites it. We never do that.
#
# ChromeOS's own shutdown path is the only thing that reliably closes every
# holder, so we drive it directly. Credit to chrultrabook/crap for working out
# that `pre-shutdown` plus a repeated `chromeos_shutdown` is what does it.
stateful_unmount() {
	stateful_is_mounted || return 0

	if [ "$IS_CROS" != 1 ]; then
		run_quiet umount -A "$ST_PART" || :
		stateful_is_mounted && return 1
		return 0
	fi

	info 'Closing the ChromeOS session so stateful can be unmounted...'
	warn 'Your desktop session ends here. Unsaved work in ChromeOS will be lost.'

	run_quiet initctl start pre-shutdown || :
	# Older builds need this twice before every holder lets go.
	run_quiet chromeos_shutdown || :
	run_quiet chromeos_shutdown || :
	run_quiet umount -A "$ST_PART" || :

	stateful_is_mounted && return 1
	return 0
}

# --- applying a new size -----------------------------------------------------

# stateful_resize <disk> <sector_size> <new_bytes>
# Caller must have unmounted first.
stateful_resize() {
	local disk=$1 ss=$2 new_bytes=$3
	local new_sectors=$((new_bytes / ss))

	[ "$new_sectors" -gt "$ST_CEIL_SECTORS" ] && new_sectors=$ST_CEIL_SECTORS

	case "$ST_KIND" in
		plain) stateful_resize_plain "$disk" "$ss" "$new_sectors" ;;
		lvm)
			oops 'This stateful partition is LVM; Glacier will not resize it.'
			say '  ChromeOS puts a thin pool across 98% of the partition, and a thin'
			say '  pool cannot be shrunk by anything on a Chromebook. See the README.'
			return 1
			;;
		*)
			oops "Don't know how to resize a '$ST_KIND' stateful partition."
			return 1
			;;
	esac
}

stateful_resize_plain() {
	local disk=$1 ss=$2 new_sectors=$3
	local new_blocks out

	new_blocks=$(((new_sectors * ss) / ST_BLOCK_SIZE))

	# Growing: enlarge the container first, then the filesystem.
	if [ "$new_sectors" -gt "$ST_SECTORS" ]; then
		run cgpt add -i "$ST_NUM" -s "$new_sectors" "$disk" || return 1
		reread_part "$disk" "$ST_NUM"
	fi

	info 'Checking the filesystem (this is the slow part)...'
	run_quiet e2fsck -f -y "$ST_PART" || :

	info "Resizing the filesystem to $(fmt_size "$((new_blocks * ST_BLOCK_SIZE))")..."
	if ! out=$(run resize2fs "$ST_PART" "$new_blocks" 2>&1); then
		oops 'resize2fs failed. Putting the partition table back as it was.'
		printf '%s\n' "$out" >&2
		if [ "$new_sectors" -gt "$ST_SECTORS" ]; then
			run cgpt add -i "$ST_NUM" -s "$ST_SECTORS" "$disk" || :
			reread_part "$disk" "$ST_NUM"
		fi
		return 1
	fi

	# Shrinking: the filesystem is already small, so now cut the container.
	if [ "$new_sectors" -lt "$ST_SECTORS" ]; then
		run cgpt add -i "$ST_NUM" -s "$new_sectors" "$disk" || return 1
		reread_part "$disk" "$ST_NUM"
	fi
	return 0
}

# --- destructive rebuild (ext4 only) -----------------------------------------

stateful_recreate_plain() {
	local mnt
	run_quiet mkfs.ext4 -F -b 4096 -L H-STATE "$ST_PART" || return 1
	mnt=$(mktemp -d) || return 1
	run mount "$ST_PART" "$mnt" || { rmdir "$mnt"; return 1; }
	run touch "$mnt/.developer_mode"
	run umount "$mnt"
	rmdir "$mnt"
	return 0
}

#
# Glacier :: lib/resize.sh -- the stateful partition resizer.
#
# Exposes resize_main(). Sourced by bin/glacier.

DISK='' SS=512

resize_usage() {
	cat <<USAGE
glacier-resize $GLACIER_VERSION

  Resize the ChromeOS stateful partition to free space on the internal disk,
  without touching ROOT-A and without disabling rootfs verification.

  Run as root from VT2 (Ctrl+Alt+Right-arrow / F2) in developer mode.

Options:
  --dry-run     Show every disk-modifying command instead of running it.
  --ascii       Draw the UI with ASCII instead of block-drawing characters.
  --debug       Echo subcommand output rather than logging it.
  -h, --help    This text.

Environment:
  GLACIER_LOG   Log file (default /tmp/glacier.log).
USAGE
}

# If we were started from a file that lives on stateful, bash would lose the
# rest of the script the moment we unmount. Re-exec from tmpfs first.
# A process substitution (bash <(curl ...)) is already safe: it is a pipe fed
# from the network, not from the disk we are about to take apart.

banner() {
	ui_clear
	printf '%s  GLACIER%s  %sstateful resizer%s  %s%s%s\n\n' \
		"$C_BOLD$C_BLU" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$GLACIER_VERSION" "$C_RESET"
}

kind_label() {
	case "$ST_KIND" in
		plain) printf 'ext4' ;;
		lvm) printf 'LVM thin pool (vg %s)' "${ST_VG:-?}" ;;
		*) printf '%sunrecognised%s' "$C_RED" "$C_RESET" ;;
	esac
}

summary() {
	local gap gap_start gap_len
	read -r gap_start gap_len < <(gpt_largest_gap "$DISK")
	gap=$((gap_len * SS))

	printf '  %-16s %s %s(%s, %s B sectors)%s\n' 'Disk' "$DISK" \
		"$C_DIM" "$(fmt_size "$(($(disk_sectors "$DISK") * SS))")" "$SS" "$C_RESET"
	printf '  %-16s %s %s(partition %s, %s)%s\n' 'Stateful' "$ST_PART" \
		"$C_DIM" "$ST_NUM" "$(kind_label)" "$C_RESET"
	printf '  %-16s %s %sof %s usable%s\n' 'Size' "$(fmt_size "$ST_BYTES")" \
		"$C_DIM" "$(fmt_size "$ST_CEIL_BYTES")" "$C_RESET"
	if [ "$ST_KIND" != unknown ]; then
		printf '  %-16s %s\n' 'In use' "$(fmt_size "$ST_USED_BYTES")"
		printf '  %-16s %s\n' 'Can shrink to' "$(fmt_size "$ST_MIN_BYTES")"
	fi
	printf '  %-16s %s\n' 'Unpartitioned' "$(fmt_size "$gap")"
	if stateful_is_mounted; then
		printf '  %-16s %smounted%s %s(must be closed before shrinking)%s\n' \
			'State' "$C_YEL" "$C_RESET" "$C_DIM" "$C_RESET"
	else
		printf '  %-16s %sunmounted%s\n' 'State' "$C_GRN" "$C_RESET"
	fi
}

explain_limits() {
	case "$ST_KIND" in
		lvm)
			printf '\n'
			warn 'This device uses an LVM stateful partition. Resizing is not supported.'
			cat <<'TXT'
  ChromeOS lays a thin pool across 98% of the partition, and a thin pool
  cannot be shrunk by anything that ships on a Chromebook -- lvreduce refuses
  outright. Only the sliver of the partition no extent occupies could be
  handed back, which measures tens of megabytes. Not worth running resize
  logic next to your data for, so Glacier stops here instead.

  Making room on this device means erasing stateful and letting ChromeOS
  provision a smaller one. Glacier does not do that for you.
TXT
			;;
		unknown)
			printf '\n'
			warn "The stateful partition holds something this tool doesn't recognise."
			say '  Resizing is disabled. Nothing here will touch the disk.'
			;;
	esac
}

do_resize() {
	local new_bytes new_sectors freed

	# LVM and unrecognised stateful partitions never reach the slider.
	if [ "$ST_KIND" != plain ]; then
		banner
		ui_title 'Resize stateful'
		explain_limits
		ui_pause
		return
	fi

	if stateful_is_mounted; then
		banner
		ui_title 'Closing the ChromeOS session'
		cat <<'TXT'
  A mounted ext4 filesystem cannot be shrunk -- that is a hard limit of ext4,
  not a missing feature here. To do this safely the running ChromeOS session
  has to be shut down first, leaving you at this shell with the disk quiet.

  What that means for you:
    * You will be logged out. Unsaved work in ChromeOS is lost.
    * The screen stays on this text console until you reboot.
    * Your files on disk are not touched by this step.

TXT
		if ! ui_confirm 'Close the ChromeOS session now?'; then
			return
		fi
		if ! stateful_unmount; then
			oops 'Could not unmount stateful. Refusing to continue.'
			say 'Shrinking a mounted filesystem would destroy it, so this is a hard stop.'
			say 'A reboot followed by running this again before logging in usually works.'
			ui_pause
			return
		fi
		good 'Stateful is unmounted.'
		stateful_probe "$DISK" "$SS"
	fi

	banner
	ui_title 'Choose a new size for the ChromeOS stateful partition'
	explain_limits

	if [ "$ST_MIN_BYTES" -ge "$ST_CEIL_BYTES" ]; then
		printf '\n'
		oops 'There is nothing to reclaim here.'
		ui_pause
		return
	fi

	printf '\n'
	if ! ui_slider "$ST_USED_BYTES" "$ST_MIN_BYTES" "$ST_CEIL_BYTES" "$ST_BYTES"; then
		say 'Cancelled. Nothing changed.'
		ui_pause
		return
	fi

	new_bytes=$SLIDER_BYTES
	new_sectors=$((new_bytes / SS))
	freed=$((ST_CEIL_BYTES - new_bytes))

	printf '\n'
	ui_title 'Review'
	printf '  stateful   %s  ->  %s\n' "$(fmt_size "$ST_BYTES")" "$(fmt_size "$new_bytes")"
	printf '  free space %s  ->  %s\n' \
		"$(fmt_size "$((ST_CEIL_BYTES - ST_BYTES))")" "$(fmt_size "$freed")"
	printf '  partition  %s sectors at %s\n\n' "$new_sectors" "$ST_START"

	if [ "$new_bytes" -lt "$ST_BYTES" ]; then
		say 'Your files are preserved: the filesystem is shrunk around them first,'
		say 'then the partition boundary is moved in to match.'
	else
		say 'The partition is grown first, then the filesystem is expanded into it.'
	fi
	printf '\n'

	if ! ui_confirm 'Write this to the disk?'; then
		say 'Cancelled. Nothing changed.'
		ui_pause
		return
	fi

	printf '\n'
	if stateful_resize "$DISK" "$SS" "$new_bytes"; then
		good 'Done.'
		stateful_probe "$DISK" "$SS"
		printf '\n'
		summary
		printf '\n'
		say 'Reboot when you are ready. ChromeOS will come back up as normal.'
	else
		oops 'The resize did not complete. The log has details:'
		say "  $GLACIER_LOG"
	fi
	ui_pause
}

do_recreate() {
	banner
	ui_title 'Re-create the stateful partition'
	cat <<'TXT'
  This erases everything ChromeOS keeps locally: downloads, local accounts,
  installed Linux (Crostini) containers, and any local-only files. It is the
  same net effect as a powerwash.

  Account-synced data comes back when you sign in again. Anything that only
  existed on this device does not.

TXT
	printf '  Target: %s%s%s (%s)\n\n' "$C_BOLD" "$ST_PART" "$C_RESET" "$(kind_label)"

	if ! ui_confirm_phrase 'ERASE' 'This cannot be undone.'; then
		say 'Aborted. Nothing changed.'
		ui_pause
		return
	fi

	if stateful_is_mounted && ! stateful_unmount; then
		oops 'Could not unmount stateful. Aborting.'
		ui_pause
		return
	fi

	printf '\n'
	local ok=1
	case "$ST_KIND" in
		lvm)
			oops "Glacier does not rebuild LVM stateful partitions."
			ok=0
			;;
		*) stateful_recreate_plain || ok=0 ;;
	esac

	if [ "$ok" = 1 ]; then
		good 'Stateful re-created. Reboot to let ChromeOS provision it.'
		stateful_probe "$DISK" "$SS"
	else
		oops 'Re-creation failed. Have recovery media ready before rebooting.'
		say "  $GLACIER_LOG"
	fi
	ui_pause
}

do_map() {
	banner
	ui_title "Partition map -- $DISK"
	print_disk_map "$DISK" "$SS"
	printf '\n'
	local gs gl
	read -r gs gl < <(gpt_largest_gap "$DISK")
	printf '  Largest unpartitioned run: %s at sector %s\n' "$(fmt_size "$((gl * SS))")" "$gs"
	ui_pause
}

resize_menu() {
	local choice
	while :; do
		banner
		summary
		printf '\n%s%s%s\n' "$C_DIM" "$(ui_rule)" "$C_RESET"
		printf '  %s1%s  Resize stateful\n' "$C_YEL" "$C_RESET"
		printf '  %s2%s  Show partition map\n' "$C_YEL" "$C_RESET"
		printf '  %s3%s  Re-create stateful %s(erases local data)%s\n' \
			"$C_YEL" "$C_RESET" "$C_RED" "$C_RESET"
		printf '  %sr%s  Reboot      %sq%s  Quit\n' "$C_YEL" "$C_RESET" "$C_YEL" "$C_RESET"
		printf '\nSelect: '
		read -r choice || choice=q
		case "$choice" in
			1) do_resize ;;
			2) do_map ;;
			3) do_recreate ;;
			r | R)
				say 'Rebooting...'
				run reboot
				exit 0
				;;
			q | Q)
				if stateful_is_mounted; then
					exit 0
				fi
				printf '\n%sStateful is unmounted; this session cannot be used normally.%s\n' \
					"$C_YEL" "$C_RESET"
				say 'Reboot when you are done.'
				exit 0
				;;
		esac
	done
}

resize_main() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--dry-run) GLACIER_DRY_RUN=1 ;;
			--ascii) GLACIER_ASCII=1 ;;
			--debug) GLACIER_DEBUG=1 ;;
			-h | --help)
				resize_usage
				exit 0
				;;
			*)
				resize_usage >&2
				exit 1
				;;
		esac
		shift
	done

	ui_init
	require_root_vt
	require_cmds cgpt blockdev awk sed grep
	require_cmds e2fsck resize2fs tune2fs mkfs.ext4


	: >"$GLACIER_LOG" 2>/dev/null || :
	log "glacier-resize $GLACIER_VERSION starting"

	# GLACIER_DISK lets the fixture harness (and anyone with more than one
	# ChromeOS disk attached) point this at a specific device.
	if [ -n "${GLACIER_DISK:-}" ]; then
		DISK=$GLACIER_DISK
		gpt_is_cros_disk "$DISK" ||
			die "$DISK does not look like a ChromeOS disk."
	else
		DISK=$(find_cros_disk) ||
			die 'No ChromeOS disk found. This tool only runs on a Chromebook.'
	fi
	SS=$(disk_sector_size "$DISK")

	stateful_probe "$DISK" "$SS" ||
		die 'Could not find a STATE partition in the GPT.'

	if [ "$ST_KIND" = lvm ] && ! lvm_ok; then
		die 'Stateful is LVM but no lvm tools are present. Cannot continue safely.'
	fi

	# Keep the fans sensible; CRAP does this and it is a kindness on a VT2
	# session that may sit at a prompt for a long time.
	if [ "$IS_CROS" = 1 ]; then
		run_quiet initctl stop powerd || :
	fi

	resize_menu
}


#
# Glacier :: lib/install.sh -- installs the Glacier boot environment into the
# KERN-C / ROOT-C partition slots.
#
# Exposes install_main(). Sourced by bin/glacier.


DEVKEYS=${DEVKEYS:-/usr/share/vboot/devkeys}
ALPINE_MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ALPINE_BRANCH=${ALPINE_BRANCH:-latest-stable}
GLACIER_LOCAL=${GLACIER_LOCAL:-/usr/local}
NO_PERSIST=${NO_PERSIST:-0}
# Overridable so the test harness can exercise both verification states and
# write the ROOT-A hook somewhere other than the running system.
GLACIER_CMDLINE=${GLACIER_CMDLINE:-/proc/cmdline}
CROS_ROOT=${GLACIER_CROS_ROOT:-}
ROOTC_MIB=${ROOTC_MIB:-1024}
KERNC_MIB=${KERNC_MIB:-64}
WORKDIR=''
MNT=''

install_usage() {
	cat <<USAGE
glacier-install $GLACIER_VERSION

  Install the Glacier boot environment into the KERN-C / ROOT-C partition
  slots. ChromeOS keeps working; rootfs verification stays on.

  Requires free unpartitioned space -- run glacier-resize first.

Options:
  --root-size MiB   Size of Glacier's root filesystem (default $ROOTC_MIB).
  --kern-size MiB   Size of Glacier's kernel partition (default $KERNC_MIB).
  --uninstall       Put KERN-C/ROOT-C back and hand booting to ChromeOS.
  --no-persist      Never touch ROOT-A, even if verification is already off.
  --dry-run         Print every disk-modifying command without running it.
  --debug           Echo subcommand output.
  -h, --help        This text.
USAGE
}

install_cleanup() {
	if [ -n "$MNT" ] && mountpoint -q "$MNT" 2>/dev/null; then
		for m in dev/pts dev sys proc; do umount "$MNT/$m" 2>/dev/null; done
		umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
	fi
	[ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}

# --- planning ----------------------------------------------------------------

align_up() { # <sector> <alignment-sectors>
	printf '%s' "$(((($1 + $2 - 1) / $2) * $2))"
}

plan() {
	local gap_start gap_len need align
	read -r gap_start gap_len < <(gpt_largest_gap "$DISK")

	KERNC_SECTORS=$((KERNC_MIB * 1024 * 1024 / SS))
	ROOTC_SECTORS=$((ROOTC_MIB * 1024 * 1024 / SS))
	align=$((1024 * 1024 / SS)) # 1 MiB

	KERNC_START=$(align_up "$gap_start" "$align")
	ROOTC_START=$((KERNC_START + KERNC_SECTORS))
	need=$((ROOTC_START + ROOTC_SECTORS - gap_start))

	if [ "$gap_len" -lt "$need" ]; then
		oops "Not enough free space on $DISK."
		say ''
		say "  needed : $(fmt_size "$((need * SS))")"
		say "  largest free run: $(fmt_size "$((gap_len * SS))")"
		say ''
		say 'Run glacier-resize first to shrink the ChromeOS stateful partition.'
		return 1
	fi
	return 0
}

# --- partition slots ---------------------------------------------------------

save_slot_backup() {
	local dir="$GLACIER_LOCAL/share/glacier"
	run mkdir -p "$dir" || return 0
	{
		printf 'KERNC_ORIG_START=%s\n' "$(part_start "$DISK" "$KERNC_NUM")"
		printf 'KERNC_ORIG_SIZE=%s\n' "$(part_size "$DISK" "$KERNC_NUM")"
		printf 'ROOTC_ORIG_START=%s\n' "$(part_start "$DISK" "$ROOTC_NUM")"
		printf 'ROOTC_ORIG_SIZE=%s\n' "$(part_size "$DISK" "$ROOTC_NUM")"
		printf 'KERNA_ORIG_PRIO=%s\n' "$(cgpt show -i "$KERNA_NUM" -P -q -n "$DISK" 2>/dev/null)"
	} >"$dir/slots.bak" 2>/dev/null || :
}

claim_slots() {
	info "Moving KERN-C into $(fmt_size "$((KERNC_SECTORS * SS))") at sector $KERNC_START"
	run cgpt add -i "$KERNC_NUM" -b "$KERNC_START" -s "$KERNC_SECTORS" \
		-t kernel -l KERN-C "$DISK" || return 1
	info "Moving ROOT-C into $(fmt_size "$((ROOTC_SECTORS * SS))") at sector $ROOTC_START"
	run cgpt add -i "$ROOTC_NUM" -b "$ROOTC_START" -s "$ROOTC_SECTORS" \
		-t rootfs -l ROOT-C "$DISK" || return 1
	reread_part "$DISK" "$KERNC_NUM"
	reread_part "$DISK" "$ROOTC_NUM"
	return 0
}

# --- kernel ------------------------------------------------------------------

build_kernel() {
	local kern_a rootc_uuid out
	kern_a=$(part_dev "$DISK" "$KERNA_NUM")
	rootc_uuid=$(part_uuid "$DISK" "$ROOTC_NUM")

	[ -r "$DEVKEYS/kernel.keyblock" ] ||
		{ oops "Developer keys not found in $DEVKEYS"; return 1; }

	# Keep a copy of what ChromeOS boots with; useful when debugging and when
	# working out what a future dual-boot entry needs.
	vbutil_kernel --verify "$kern_a" --verbose 2>/dev/null |
		sed -n '/^Config:/,$p' | tail -n +2 >"$WORKDIR/cros-cmdline" || :

	cat >"$WORKDIR/cmdline" <<CMDLINE
console=tty1 root=PARTUUID=$rootc_uuid rootwait rw init=/sbin/glacier-init loglevel=4 glacier
CMDLINE

	info 'Re-signing the ChromeOS kernel with a Glacier command line...'
	# --repack keeps the kernel body byte-for-byte and swaps the command line
	# and signature. No kernel is compiled and no driver is lost.
	if ! out=$(run vbutil_kernel --repack "$WORKDIR/glacier.kernel" \
		--oldblob "$kern_a" \
		--keyblock "$DEVKEYS/kernel.keyblock" \
		--signprivate "$DEVKEYS/kernel_data_key.vbprivk" \
		--config "$WORKDIR/cmdline" \
		--version 1 2>&1); then
		oops 'vbutil_kernel --repack failed:'
		printf '%s\n' "$out" >&2
		return 1
	fi

	if [ "$GLACIER_DRY_RUN" != 1 ]; then
		vbutil_kernel --verify "$WORKDIR/glacier.kernel" >/dev/null 2>&1 ||
			{ oops 'Re-signed kernel does not verify. Refusing to write it.'; return 1; }
	fi

	info 'Writing the kernel to KERN-C...'
	run dd if="$WORKDIR/glacier.kernel" of="$(part_dev "$DISK" "$KERNC_NUM")" \
		bs=1M conv=fsync status=none || return 1
	return 0
}

# --- root filesystem ---------------------------------------------------------

alpine_arch() {
	case "$(uname -m)" in
		x86_64) printf 'x86_64' ;;
		aarch64) printf 'aarch64' ;;
		armv7l | armv8l) printf 'armv7' ;;
		*) return 1 ;;
	esac
}

fetch_rootfs() {
	local arch base file
	arch=$(alpine_arch) || { oops "Unsupported architecture $(uname -m)"; return 1; }
	base="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$arch"

	info "Fetching the Alpine $arch base image..."
	file=$(curl -sL "$base/latest-releases.yaml" 2>/dev/null |
		awk '/minirootfs/ {f=1} f && /file:/ {print $2; exit}')
	if [ -z "$file" ]; then
		file=$(curl -sL "$base/" 2>/dev/null |
			grep -o "alpine-minirootfs-[0-9.]*-$arch\.tar\.gz" | sort -V | tail -1)
	fi
	[ -n "$file" ] || { oops 'Could not work out the Alpine image filename.'; return 1; }

	curl -fsSL -o "$WORKDIR/rootfs.tar.gz" "$base/$file" ||
		{ oops "Download failed: $base/$file"; return 1; }
	good "Got $file ($(fmt_size "$(stat -c%s "$WORKDIR/rootfs.tar.gz")"))"
	return 0
}

build_rootfs() {
	local rootc
	rootc=$(part_dev "$DISK" "$ROOTC_NUM")

	info 'Creating the Glacier filesystem...'
	run_quiet mkfs.ext4 -F -q -b 4096 -L GLACIER "$rootc" || return 1

	MNT="$WORKDIR/root"
	mkdir -p "$MNT"
	run mount "$rootc" "$MNT" || return 1

	info 'Unpacking...'
	run tar -xzf "$WORKDIR/rootfs.tar.gz" -C "$MNT" || return 1

	# Give the chroot working DNS so apk can reach the mirror.
	cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || :
	mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev"
	mount -t proc proc "$MNT/proc" 2>/dev/null || :
	mount -t sysfs sysfs "$MNT/sys" 2>/dev/null || :
	mount --bind /dev "$MNT/dev" 2>/dev/null || :

	info 'Adding the tools Glacier needs...'
	# sgdisk is how Glacier edits the GPT boot attributes. cgpt would be the
	# natural choice, but it is a glibc ChromeOS binary and this rootfs is
	# musl, so it cannot run here. Install it on its own: apk fails a whole
	# transaction if any single name is wrong, and losing sgdisk because an
	# optional extra went missing would leave the menu unable to boot ChromeOS.
	if ! chroot "$MNT" /sbin/apk add --no-cache --quiet sgdisk \
		>>"$GLACIER_LOG" 2>&1; then
		warn 'Could not install sgdisk (offline?).'
	fi
	# Nice to have; a failure here must not take sgdisk down with it.
	chroot "$MNT" /sbin/apk add --no-cache --quiet \
		e2fsprogs e2fsprogs-extra lvm2 util-linux blkid \
		>>"$GLACIER_LOG" 2>&1 ||
		warn 'Some optional tools could not be installed; the menu still works.'

	# sgdisk is how the menu hands the machine back to ChromeOS. If it is
	# missing, Glacier boots but is a one-way trip -- so say so now.
	if [ "$GLACIER_DRY_RUN" != 1 ] && ! chroot "$MNT" /bin/sh -c 'command -v sgdisk' >/dev/null 2>&1; then
		warn 'sgdisk is not present in the Glacier root filesystem.'
		warn 'The menu will boot, but "Boot ChromeOS" cannot change the boot order.'
		warn 'Re-run with a working network connection to fix this.'
	else
		good 'sgdisk present -- the menu can switch the boot order.'
	fi

	install_payload || return 1
	copy_modules || :

	for m in dev sys proc; do umount "$MNT/$m" 2>/dev/null; done
	sync
	run umount "$MNT" || :
	MNT=''
	return 0
}

install_payload() {
	local p=$GLACIER_PAYLOAD
	# In the bundled single-file build there is no payload/ directory on disk;
	# tools/bundle.sh embeds it and defines this function instead.
	if [ ! -d "$p" ] && declare -F glacier_payload_unpack >/dev/null 2>&1; then
		p=$(glacier_payload_unpack) || { oops 'Could not unpack the embedded payload.'; return 1; }
	fi
	[ -d "$p" ] || { oops "Payload directory not found: $p"; return 1; }

	install -D -m 0755 "$p/init" "$MNT/sbin/glacier-init" || return 1
	install -D -m 0755 "$p/glacier-menu" "$MNT/usr/sbin/glacier-menu" || return 1
	install -D -m 0644 "$p/glacier-gpt.sh" "$MNT/usr/share/glacier/glacier-gpt.sh" || return 1

	mkdir -p "$MNT/etc/glacier"
	cat >"$MNT/etc/glacier/config" <<CONF
# Written by glacier-install $GLACIER_VERSION on $(date -u '+%Y-%m-%d %H:%M UTC')
GLACIER_VERSION='$GLACIER_VERSION'
GLACIER_DISK='$DISK'
GLACIER_KERNC='$KERNC_NUM'
GLACIER_ROOTC='$ROOTC_NUM'
GLACIER_KERNA='$KERNA_NUM'
GLACIER_ROOTA='$ROOTA_NUM'
CONF
	[ -f "$WORKDIR/cros-cmdline" ] &&
		cp "$WORKDIR/cros-cmdline" "$MNT/etc/glacier/chromeos-cmdline" || :
	printf 'glacier\n' >"$MNT/etc/hostname"
	return 0
}

copy_modules() {
	local kver
	kver=$(uname -r)
	[ -d "/lib/modules/$kver" ] || return 0
	info "Copying kernel modules for $kver..."
	mkdir -p "$MNT/lib/modules"
	cp -a "/lib/modules/$kver" "$MNT/lib/modules/" 2>/dev/null || :
	return 0
}

# --- boot order --------------------------------------------------------------

set_boot_order() {
	local kerna_prio
	info 'Making Glacier the default boot entry...'
	run cgpt add -i "$KERNC_NUM" -P 15 -T 0 -S 1 "$DISK" || return 1
	kerna_prio=$(cgpt show -i "$KERNA_NUM" -P -q -n "$DISK" 2>/dev/null)
	case "$kerna_prio" in '' | *[!0-9]*) kerna_prio=0 ;; esac
	if [ "$kerna_prio" -ge 15 ]; then
		run cgpt add -i "$KERNA_NUM" -P 10 "$DISK" || :
	fi
	return 0
}

# ChromeOS re-prioritises its own kernel about 45 seconds into every boot
# (chromeos-setgoodkernel runs `cgpt prioritize`). That means booting ChromeOS
# from the Glacier menu makes ChromeOS the default again. This little helper,
# which lives on the stateful partition and needs no rootfs change, is how you
# come back.
install_helper() {
	local dst="$GLACIER_LOCAL/bin/glacier"
	info "Installing the return-to-Glacier helper at $dst"
	run mkdir -p "$GLACIER_LOCAL/bin" || return 0
	if [ "$GLACIER_DRY_RUN" = 1 ]; then return 0; fi
	cat >"$dst" <<'HELPER'
#!/bin/sh
# Reboot into the Glacier boot environment.
# Installed by glacier-install; lives on the stateful partition, so ChromeOS's
# read-only rootfs is untouched.
set -e
[ "$(id -u)" -eq 0 ] || { echo 'Run me as root.' >&2; exit 1; }
disk=${GLACIER_DISK:-}
[ -n "$disk" ] || for d in /sys/block/*; do
	n=${d##*/}
	case "$n" in loop* | ram* | zram* | dm-* | sr*) continue ;; esac
	[ "$(cat "$d/removable" 2>/dev/null || echo 0)" = 0 ] || continue
	cgpt find -l KERN-C "/dev/$n" >/dev/null 2>&1 || continue
	disk="/dev/$n"
	break
done
[ -n "$disk" ] || { echo 'No ChromeOS disk with a KERN-C partition found.' >&2; exit 1; }
num=$(cgpt find -n -l KERN-C "$disk" 2>/dev/null | head -1)
[ -n "$num" ] || { echo 'KERN-C not found.' >&2; exit 1; }
cgpt add -i "$num" -P 15 -T 0 -S 1 "$disk"
cgpt prioritize -i "$num" "$disk"
echo 'Next boot goes to Glacier. Rebooting...'
sync
reboot
HELPER
	chmod 0755 "$dst"
	return 0
}

# --- rootfs verification and persistence -------------------------------------
#
# Everything above works with verification on. This section is the opt-in that
# trades it away for one thing: Glacier staying the default boot entry.

# ChromeOS's own command line is the authority, and we are running on ChromeOS,
# so /proc/cmdline is it. With verification on, root is the dm-verity device.
cros_verity_on() { grep -q 'root=/dev/dm-' "$GLACIER_CMDLINE" 2>/dev/null; }

disable_verity() {
	local script=/usr/share/vboot/bin/make_dev_ssd.sh parts kb

	[ -x "$script" ] || {
		oops "Not found: $script"
		say '  This ChromeOS build does not ship the kernel re-signing script.'
		return 1
	}

	# make_dev_ssd.sh refuses to re-sign unless the firmware is willing to
	# boot a kernel it did not sign itself.
	if have crossystem && [ "$(crossystem dev_boot_signed_only 2>/dev/null)" = '1' ]; then
		info 'Setting dev_boot_signed_only=0 (required to re-sign the kernel)...'
		run crossystem dev_boot_signed_only=0 ||
			{ oops 'Could not clear dev_boot_signed_only.'; return 1; }
	fi

	# Do both ChromeOS slots, so an A/B switch doesn't silently turn
	# verification back on. Invalid or missing slots are filtered out by the
	# script itself.
	parts=$KERNA_NUM
	kb=$(part_num_by_label "$DISK" KERN-B) && parts="$parts $kb"

	info "Disabling rootfs verification on kernel partitions: $parts"
	say '  (old kernel blobs are backed up under /mnt/stateful_partition)'
	if ! run "$script" --remove_rootfs_verification --partitions "$parts"; then
		oops 'make_dev_ssd.sh failed. Nothing was changed.'
		return 1
	fi
	return 0
}

offer_persistence() {
	PERSIST=0
	[ "$NO_PERSIST" = 1 ] && return 0

	if ! cros_verity_on; then
		PERSIST=1
		good 'Rootfs verification is already off; Glacier can be made persistent.'
		return 0
	fi

	printf '\n'
	ui_title 'Make Glacier the permanent default? (optional)'
	cat <<'TXT'
  ChromeOS re-prioritises its own kernel about 45 seconds into every boot. So
  by default, choosing "Boot ChromeOS" from the Glacier menu is a one-way
  door, and you come back by running "sudo glacier" from a ChromeOS shell.

  Glacier can instead install a small job inside the ChromeOS root filesystem
  that takes the default back on every boot. Writing to ROOT-A means turning
  rootfs verification OFF, which:

    * lets anything running as root modify ChromeOS itself
    * is undone by a ChromeOS update, which re-signs the kernel
    * is reversed only by powerwashing or recovering the device
    * is NOT needed for Glacier to work

  Say no and everything still works; you just type "sudo glacier" to come
  back.

TXT
	if ! ui_confirm 'Disable rootfs verification now?'; then
		say 'Leaving verification on.'
		return 0
	fi

	printf '\n'
	if ! disable_verity; then
		warn 'Continuing without persistence.'
		return 0
	fi

	printf '\n'
	good 'Rootfs verification will be off after a reboot.'
	cat <<'TXT'

  Nothing else has been changed yet. Reboot, then run this installer again:
  it will see that verification is off and install Glacier together with the
  persistence hook.

      reboot

TXT
	exit 0
}

# A tiny script plus two upstart jobs, written into ROOT-A. Upstart is what
# ChromeOS uses, and these are the only files Glacier ever puts there.
install_persistence_hook() {
	local remounted=0

	[ "${PERSIST:-0}" = 1 ] || return 0
	cros_verity_on && return 0

	info 'Installing the ChromeOS-side persistence hook...'

	if [ -n "$CROS_ROOT" ]; then
		mkdir -p "$CROS_ROOT/usr/sbin" "$CROS_ROOT/etc/init"
	elif ! touch /usr/sbin/.glacier-rw-probe 2>/dev/null; then
		run mount -o remount,rw / 2>/dev/null || {
			warn 'ROOT-A is not writable; skipping the persistence hook.'
			return 0
		}
		remounted=1
	else
		rm -f /usr/sbin/.glacier-rw-probe
	fi

	if [ "$GLACIER_DRY_RUN" = 1 ]; then
		say '(dry-run) would write /usr/sbin/glacier-persist and /etc/init/glacier-persist*.conf'
		[ "$remounted" = 1 ] && run mount -o remount,ro / 2>/dev/null
		return 0
	fi

	cat >"$CROS_ROOT"/usr/sbin/glacier-persist <<'PERSIST'
#!/bin/sh
# Re-assert Glacier as the default boot entry.
# Installed into ROOT-A by glacier-install; removed by --uninstall.
disk=${GLACIER_DISK:-}
[ -n "$disk" ] || for d in /sys/block/*; do
	n=${d##*/}
	case "$n" in loop* | ram* | zram* | dm-* | sr*) continue ;; esac
	[ "$(cat "$d/removable" 2>/dev/null || echo 0)" = 0 ] || continue
	cgpt find -l KERN-C "/dev/$n" >/dev/null 2>&1 || continue
	disk="/dev/$n"
	break
done
[ -n "$disk" ] || exit 0
num=$(cgpt find -n -l KERN-C "$disk" 2>/dev/null | head -1)
[ -n "$num" ] || exit 0
cgpt add -i "$num" -P 15 -T 0 -S 1 "$disk" >/dev/null 2>&1 || exit 0
cgpt prioritize -i "$num" "$disk" >/dev/null 2>&1 || exit 0
PERSIST
	chmod 0755 "$CROS_ROOT"/usr/sbin/glacier-persist

	cat >"$CROS_ROOT"/etc/init/glacier-persist.conf <<'JOB'
# Keep Glacier as the default boot entry. Installed by glacier-install.
description "Re-assert Glacier as the default boot entry"
author "glacier"

start on started system-services

script
  # chromeos-setgoodkernel runs about 45 seconds after update_engine starts
  # and calls `cgpt prioritize` on the ChromeOS kernel. Wait it out, then
  # take the default back.
  sleep 150
  /usr/sbin/glacier-persist || true
end script
JOB

	cat >"$CROS_ROOT"/etc/init/glacier-persist-shutdown.conf <<'JOB'
# Belt and braces: also take the default back on the way down, in case the
# boot-time job was still sleeping when the machine was shut down.
description "Re-assert Glacier as the default boot entry at shutdown"
author "glacier"

start on starting pre-shutdown
task

exec /usr/sbin/glacier-persist
JOB

	sync
	[ "$remounted" = 1 ] && run mount -o remount,ro / 2>/dev/null
	good 'Glacier will stay the default boot entry across ChromeOS boots.'
	return 0
}

remove_persistence_hook() {
	local remounted=0
	[ -e "$CROS_ROOT"/etc/init/glacier-persist.conf ] ||
		[ -e "$CROS_ROOT"/usr/sbin/glacier-persist ] || return 0
	info 'Removing the ChromeOS-side persistence hook...'
	if [ -n "$CROS_ROOT" ]; then
		:
	elif ! touch /usr/sbin/.glacier-rw-probe 2>/dev/null; then
		run mount -o remount,rw / 2>/dev/null || {
			warn 'ROOT-A is read-only; left the persistence hook in place.'
			return 0
		}
		remounted=1
	else
		rm -f /usr/sbin/.glacier-rw-probe
	fi
	run rm -f "$CROS_ROOT"/usr/sbin/glacier-persist \
		"$CROS_ROOT"/etc/init/glacier-persist.conf \
		"$CROS_ROOT"/etc/init/glacier-persist-shutdown.conf || :
	sync
	[ "$remounted" = 1 ] && run mount -o remount,ro / 2>/dev/null
	return 0
}

# --- uninstall ---------------------------------------------------------------

do_uninstall() {
	local bak="$GLACIER_LOCAL/share/glacier/slots.bak"
	ui_title 'Removing Glacier'

	info 'Handing booting back to ChromeOS...'
	run cgpt add -i "$KERNA_NUM" -P 15 -T 0 -S 1 "$DISK" || :
	run cgpt add -i "$KERNC_NUM" -P 0 -T 0 -S 0 "$DISK" || :

	if [ -r "$bak" ]; then
		# shellcheck source=/dev/null
		. "$bak"
		info 'Restoring the original KERN-C / ROOT-C placeholders...'
		run cgpt add -i "$KERNC_NUM" -b "$KERNC_ORIG_START" -s "$KERNC_ORIG_SIZE" \
			-t kernel -l KERN-C "$DISK" || :
		run cgpt add -i "$ROOTC_NUM" -b "$ROOTC_ORIG_START" -s "$ROOTC_ORIG_SIZE" \
			-t rootfs -l ROOT-C "$DISK" || :
		reread_part "$DISK" "$KERNC_NUM"
	else
		warn 'No saved slot layout found; KERN-C/ROOT-C left where they are.'
		warn 'They are no longer bootable, and the space they use is still theirs.'
	fi

	remove_persistence_hook
	run rm -f "$GLACIER_LOCAL/bin/glacier" || :
	good 'Glacier removed. ChromeOS boots normally again.'
	return 0
}

# --- main --------------------------------------------------------------------

install_main() {
	trap install_cleanup EXIT
	local uninstall=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--root-size) ROOTC_MIB=$2; shift ;;
			--kern-size) KERNC_MIB=$2; shift ;;
			--uninstall) uninstall=1 ;;
			--no-persist) NO_PERSIST=1 ;;
			--dry-run) GLACIER_DRY_RUN=1 ;;
			--debug) GLACIER_DEBUG=1 ;;
			-h | --help) install_usage; exit 0 ;;
			*) install_usage >&2; exit 1 ;;
		esac
		shift
	done

	ui_init
	require_root_vt
	require_cmds cgpt vbutil_kernel curl tar mkfs.ext4 blockdev

	: >"$GLACIER_LOG" 2>/dev/null || :
	WORKDIR=$(mktemp -d) || die 'Could not create a work directory.'

	if [ -n "${GLACIER_DISK:-}" ]; then
		DISK=$GLACIER_DISK
		gpt_is_cros_disk "$DISK" || die "$DISK does not look like a ChromeOS disk."
	else
		DISK=$(find_cros_disk) || die 'No ChromeOS disk found.'
	fi
	SS=$(disk_sector_size "$DISK")

	KERNA_NUM=$(part_num_by_label "$DISK" KERN-A) || die 'No KERN-A partition.'
	ROOTA_NUM=$(part_num_by_label "$DISK" ROOT-A) || die 'No ROOT-A partition.'
	KERNC_NUM=$(part_num_by_label "$DISK" KERN-C) || die 'No KERN-C partition slot.'
	ROOTC_NUM=$(part_num_by_label "$DISK" ROOT-C) || die 'No ROOT-C partition slot.'

	ui_clear
	printf '%s  GLACIER%s  %sinstaller%s  %s%s%s\n\n' \
		"$C_BOLD$C_BLU" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$GLACIER_VERSION" "$C_RESET"

	if [ "$uninstall" = 1 ]; then
		do_uninstall
		exit $?
	fi

	offer_persistence

	plan || exit 1

	printf '  %-14s %s\n' 'Disk' "$DISK"
	printf '  %-14s partition %s, %s at sector %s\n' 'KERN-C' "$KERNC_NUM" \
		"$(fmt_size "$((KERNC_SECTORS * SS))")" "$KERNC_START"
	printf '  %-14s partition %s, %s at sector %s\n' 'ROOT-C' "$ROOTC_NUM" \
		"$(fmt_size "$((ROOTC_SECTORS * SS))")" "$ROOTC_START"
	printf '\n'
	cat <<'TXT'
  Glacier takes the unused C partition slots. The ChromeOS updater only ever
  uses A and B, so it will not touch them.

TXT
	if [ "${PERSIST:-0}" = 1 ]; then
		say '  Rootfs verification is off, so a small job will also be written into'
		say '  the ChromeOS root filesystem to keep Glacier the default boot entry.'
	else
		say '  ChromeOS is not modified: ROOT-A is never written to and rootfs'
		say '  verification stays on.'
	fi
	printf '\n'
	ui_confirm 'Install Glacier?' || { say 'Nothing changed.'; exit 0; }
	printf '\n'

	save_slot_backup
	claim_slots || die 'Could not claim the KERN-C / ROOT-C slots.'
	build_kernel || die 'Could not build the Glacier kernel.'
	fetch_rootfs || die 'Could not fetch the base root filesystem.'
	build_rootfs || die 'Could not build the Glacier root filesystem.'
	set_boot_order || die 'Could not set the boot order.'
	install_helper
	install_persistence_hook

	printf '\n'
	good 'Glacier is installed.'
	printf '\n  Reboot and you will land in the Glacier menu instead of ChromeOS.\n\n'
	if [ "${PERSIST:-0}" = 1 ]; then
		cat <<'TXT'
  "Boot ChromeOS" hands the machine back, and the persistence hook takes the
  default to Glacier again before the next boot. You can still force it with
  "sudo glacier" from a ChromeOS shell.

  Note that a ChromeOS update re-signs the kernel and turns rootfs
  verification back on, which disables the hook. Re-run this installer after
  an update to restore it.

TXT
	else
		cat <<'TXT'
  "Boot ChromeOS" hands the machine back. Because ChromeOS re-prioritises its
  own kernel about 45 seconds into every boot, it stays the default after
  that -- run "sudo glacier" from a ChromeOS shell to come back here.

TXT
	fi
	say '  To undo all of this:  glacier-install --uninstall'
	return 0
}


# --- end inlined libraries ---
glacier_payload_unpack() {
	local d
	d=$(mktemp -d) || return 1
	base64 -d >"$d/init" <<'GLACIER_B64'
IyEvYmluL3NoCiMKIyBHbGFjaWVyIDo6IHBheWxvYWQvaW5pdCAtLSBQSUQgMSBmb3IgdGhlIEds
YWNpZXIgYm9vdCBlbnZpcm9ubWVudC4KIwojIERlbGliZXJhdGVseSB0aW55LiBUaGVyZSBpcyBu
byBzZXJ2aWNlIG1hbmFnZXIgaGVyZTogdGhpcyBleGlzdHMgdG8gZ2V0IGEKIyBjb25zb2xlIGFu
ZCBhIG1lbnUgdXAsIG5vdGhpbmcgZWxzZS4gSWYgUElEIDEgZXZlciBleGl0cyB0aGUga2VybmVs
IHBhbmljcywKIyBzbyBldmVyeSBwYXRoIGJlbG93IGVuZHMgaW4gYSBzaGVsbCByYXRoZXIgdGhh
biBhIHJldHVybi4KCmV4cG9ydCBQQVRIPS9zYmluOi91c3Ivc2JpbjovYmluOi91c3IvYmluCmV4
cG9ydCBIT01FPS9yb290CmV4cG9ydCBURVJNPSR7VEVSTTotbGludXh9Cgptb3VudCAtdCBwcm9j
ICAgICBwcm9jICAgICAvcHJvYyAgICAyPi9kZXYvbnVsbAptb3VudCAtdCBzeXNmcyAgICBzeXNm
cyAgICAvc3lzICAgICAyPi9kZXYvbnVsbAptb3VudCAtdCBkZXZ0bXBmcyBkZXZ0bXBmcyAvZGV2
ICAgICAyPi9kZXYvbnVsbApta2RpciAtcCAvZGV2L3B0cyAvZGV2L3NobSAvbW50L2Nyb3MgL3J1
bgptb3VudCAtdCBkZXZwdHMgICBkZXZwdHMgICAvZGV2L3B0cyAyPi9kZXYvbnVsbAptb3VudCAt
dCB0bXBmcyAgICB0bXBmcyAgICAvdG1wICAgICAyPi9kZXYvbnVsbAptb3VudCAtdCB0bXBmcyAg
ICB0bXBmcyAgICAvcnVuICAgICAyPi9kZXYvbnVsbAptb3VudCAtbyByZW1vdW50LHJ3IC8gMj4v
ZGV2L251bGwKCiMgQ2xhaW0gdGhlIGNvbnNvbGUgZXhwbGljaXRseTsgd2l0aG91dCB0aGlzIHRo
ZSBtZW51J3MgcHJvbXB0cyBnbyBub3doZXJlLgpleGVjIDwvZGV2L2NvbnNvbGUgPi9kZXYvY29u
c29sZSAyPiYxCgpbIC1jIC9kZXYvbnVsbCBdIHx8IG1rbm9kIC9kZXYvbnVsbCBjIDEgMyAyPi9k
ZXYvbnVsbAoKaG9zdG5hbWUgZ2xhY2llciAyPi9kZXYvbnVsbAoKIyBLZXJuZWwgbW9kdWxlcyBj
b21lIGZyb20gdGhlIENocm9tZU9TIGtlcm5lbCB0aGlzIGVudmlyb25tZW50IHdhcyBidWlsdAoj
IGFnYWluc3Q7IGRlcG1vZCBtYXkgbm90IGhhdmUgYmVlbiBydW4gYXQgaW5zdGFsbCB0aW1lLgpb
IC1kICIvbGliL21vZHVsZXMvJCh1bmFtZSAtcikiIF0gJiYgZGVwbW9kIC1hIDI+L2Rldi9udWxs
Cgp3aGlsZSA6OyBkbwoJaWYgWyAteCAvdXNyL3NiaW4vZ2xhY2llci1tZW51IF07IHRoZW4KCQkv
dXNyL3NiaW4vZ2xhY2llci1tZW51CgllbHNlCgkJZWNobyAnZ2xhY2llcjogbWVudSBtaXNzaW5n
LCBkcm9wcGluZyB0byBhIHNoZWxsLicKCWZpCgllY2hvCgllY2hvICdnbGFjaWVyOiB0aGUgbWVu
dSBleGl0ZWQuIFN0YXJ0aW5nIGEgc2hlbGw7IGV4aXQgaXQgdG8gcmV0dXJuLicKCS9iaW4vc2gK
ZG9uZQo=
GLACIER_B64
	base64 -d >"$d/glacier-menu" <<'GLACIER_B64'
IyEvYmluL3NoCiMKIyBHbGFjaWVyIDo6IHBheWxvYWQvZ2xhY2llci1tZW51IC0tIHRoZSBib290
IG1lbnUuCiMKIyBQT1NJWCBzaCAoYnVzeWJveCBhc2gpLiBLZWVwIGl0IHRoYXQgd2F5OyB0aGlz
IHJ1bnMgYmVmb3JlIGFueXRoaW5nIGVsc2UKIyBleGlzdHMgdG8gZmFsbCBiYWNrIG9uLgoKLiAv
dXNyL3NoYXJlL2dsYWNpZXIvZ2xhY2llci1ncHQuc2gKWyAtciAvZXRjL2dsYWNpZXIvY29uZmln
IF0gJiYgLiAvZXRjL2dsYWNpZXIvY29uZmlnCgpHTEFDSUVSX1ZFUlNJT049JHtHTEFDSUVSX1ZF
UlNJT046LTAuMS4wfQoKUj0kKHByaW50ZiAnXDAzM1swbScpOyBCPSQocHJpbnRmICdcMDMzWzFt
Jyk7IEQ9JChwcmludGYgJ1wwMzNbMm0nKQpSRUQ9JChwcmludGYgJ1wwMzNbMTszMW0nKTsgR1JO
PSQocHJpbnRmICdcMDMzWzE7MzJtJykKWUVMPSQocHJpbnRmICdcMDMzWzE7MzNtJyk7IENZTj0k
KHByaW50ZiAnXDAzM1sxOzM2bScpOyBCTFU9JChwcmludGYgJ1wwMzNbMTszNG0nKQoKc2F5KCkg
IHsgcHJpbnRmICclc1xuJyAiJCoiOyB9CmluZm8oKSB7IHByaW50ZiAnJXM9PT4lcyAlc1xuJyAi
JENZTiIgIiRSIiAiJCoiOyB9Cmdvb2QoKSB7IHByaW50ZiAnJXNbb2tdJXMgJXNcbicgIiRHUk4i
ICIkUiIgIiQqIjsgfQp3YXJuKCkgeyBwcmludGYgJyVzWyEhXSVzICVzXG4nICIkWUVMIiAiJFIi
ICIkKiI7IH0Kb29wcygpIHsgcHJpbnRmICclc1t4eF0lcyAlc1xuJyAiJFJFRCIgIiRSIiAiJCoi
OyB9CnBhdXNlKCkgeyBwcmludGYgJ1xuJXNQcmVzcyBlbnRlci4lcyAnICIkRCIgIiRSIjsgcmVh
ZCAtciBfOyB9CgpESVNLPScnCgpmaW5kX2Rpc2soKSB7CglpZiBbIC1uICIkR0xBQ0lFUl9ESVNL
IiBdICYmIFsgLWIgIiRHTEFDSUVSX0RJU0siIF07IHRoZW4KCQlESVNLPSRHTEFDSUVSX0RJU0sK
CQlyZXR1cm4gMAoJZmkKCURJU0s9JChncHRfZmluZF9jcm9zX2Rpc2spICYmIHJldHVybiAwCgly
ZXR1cm4gMQp9CgojIC0tLSAxOiBoYW5kIHRoZSBtYWNoaW5lIGJhY2sgdG8gQ2hyb21lT1MgLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiMKIyBDaHJvbWVPUydzIGZpcm13YXJl
IGJvb3RzIHRoZSBrZXJuZWwgcGFydGl0aW9uIHdpdGggdGhlIGhpZ2hlc3QgcHJpb3JpdHksIHNv
CiMgc3dpdGNoaW5nIE9TIG1lYW5zIHN3YXBwaW5nIHdoaWNoIG9uZSB0aGF0IGlzIGFuZCByZWJv
b3RpbmcuCiMKIyBXb3J0aCBrbm93aW5nOiBhYm91dCA0NSBzZWNvbmRzIGludG8gZXZlcnkgYm9v
dCwgQ2hyb21lT1MgcnVucwojIGNocm9tZW9zLXNldGdvb2RrZXJuZWwsIHdoaWNoIGNhbGxzIGBj
Z3B0IHByaW9yaXRpemVgIG9uIGl0cyBvd24ga2VybmVsLgojIFVubGVzcyB0aGUgcGVyc2lzdGVu
Y2UgaG9vayBpcyBpbnN0YWxsZWQgKHdoaWNoIG5lZWRzIHJvb3RmcyB2ZXJpZmljYXRpb24KIyBv
ZmYpLCB0aGF0IG1ha2VzIENocm9tZU9TIHRoZSBkZWZhdWx0IGFnYWluIG9uIGl0cyBvd24gLS0g
Y29tZSBiYWNrIHdpdGgKIyBgc3VkbyBnbGFjaWVyYCBmcm9tIGEgQ2hyb21lT1Mgc2hlbGwuCgpi
b290X2Nocm9tZW9zKCkgewoJa2Vybl9hPSQoZ3B0X251bV9ieV9sYWJlbCAiJERJU0siIEtFUk4t
QSkKCWtlcm5fYz0kKGdwdF9udW1fYnlfbGFiZWwgIiRESVNLIiBLRVJOLUMpCglpZiBbIC16ICIk
a2Vybl9hIiBdIHx8IFsgLXogIiRrZXJuX2MiIF07IHRoZW4KCQlvb3BzICdDb3VsZCBub3QgbG9j
YXRlIEtFUk4tQSAvIEtFUk4tQyBpbiB0aGUgcGFydGl0aW9uIHRhYmxlLicKCQlwYXVzZQoJCXJl
dHVybiAxCglmaQoKCXByaW50ZiAnXG4nCglpbmZvICJNYWtpbmcgQ2hyb21lT1MgKEtFUk4tQSwg
cGFydGl0aW9uICRrZXJuX2EpIHRoZSBib290IGRlZmF1bHQuIgoJZ3B0X21hcmtfZ29vZCAiJERJ
U0siICIka2Vybl9hIgoJZ3B0X3NldF9wcmlvcml0eSAiJERJU0siICIka2Vybl9hIiAxNSB8fCB7
IG9vcHMgJ0NvdWxkIG5vdCBzZXQgcHJpb3JpdHkuJzsgcGF1c2U7IHJldHVybiAxOyB9CglncHRf
c2V0X3ByaW9yaXR5ICIkRElTSyIgIiRrZXJuX2MiIDUKCglwcmludGYgJ1xuICBUbyBjb21lIGJh
Y2sgdG8gdGhpcyBtZW51LCBydW4gJXNzdWRvIGdsYWNpZXIlcyBmcm9tIGEgQ2hyb21lT1Mgc2hl
bGxcbicgIiRCIiAiJFIiCglwcmludGYgJyAgKHVubGVzcyB0aGUgcGVyc2lzdGVuY2UgaG9vayBp
cyBpbnN0YWxsZWQsIGluIHdoaWNoIGNhc2UgR2xhY2llclxuJwoJcHJpbnRmICcgIHRha2VzIHRo
ZSBkZWZhdWx0IGJhY2sgYnkgaXRzZWxmKS5cblxuJwoKCXByaW50ZiAnUmVib290aW5nIGludG8g
Q2hyb21lT1MnCglpPTMKCXdoaWxlIFsgIiRpIiAtZ3QgMCBdOyBkbwoJCXByaW50ZiAnICVzJyAi
JGkiCgkJc2xlZXAgMQoJCWk9JCgoaSAtIDEpKQoJZG9uZQoJcHJpbnRmICdcbicKCXN5bmMKCXJl
Ym9vdCAtZgp9CgojIC0tLSAyOiBhIHNoZWxsIGluc2lkZSB0aGUgQ2hyb21lT1Mgcm9vdGZzIC0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgoKIyBNYWtlIHRoZSB1c2VyIHR5cGUg
YSB3b3JkLiBBIGJhcmUgeSBpcyB0b28gZWFzeSB0byBoaXQgYnkgcmVmbGV4IGZvcgojIHNvbWV0
aGluZyB0aGF0IGNhbiBzdG9wIHRoZSBtYWNoaW5lIGJvb3RpbmcuCmNvbmZpcm1fd29yZCgpIHsg
IyA8d29yZD4KCXByaW50ZiAnVHlwZSAlcyVzJXMgdG8gY29udGludWUsIGFueXRoaW5nIGVsc2Ug
dG8gY2FuY2VsOiAnICIkQiIgIiQxIiAiJFIiCglyZWFkIC1yIF9yZXBseQoJWyAiJF9yZXBseSIg
PSAiJDEiIF0KfQoKbW91bnRfY3JvcygpIHsgIyA8cm98cnc+Cgltb2RlPSQxCglyb290X2E9JChn
cHRfbnVtX2J5X2xhYmVsICIkRElTSyIgUk9PVC1BKQoJWyAtbiAiJHJvb3RfYSIgXSB8fCB7IG9v
cHMgJ05vIFJPT1QtQSBwYXJ0aXRpb24gZm91bmQuJzsgcmV0dXJuIDE7IH0KCXJkZXY9JChncHRf
cGFydF9kZXYgIiRESVNLIiAiJHJvb3RfYSIpCgoJbWtkaXIgLXAgL21udC9jcm9zCglpZiAhIG1v
dW50IC1vICIkbW9kZSIgIiRyZGV2IiAvbW50L2Nyb3MgMj4vZGV2L251bGw7IHRoZW4KCQlvb3Bz
ICJDb3VsZCBub3QgbW91bnQgJHJkZXYgJG1vZGUuIgoJCXJldHVybiAxCglmaQoKCXN0YXRlPSQo
Z3B0X251bV9ieV9sYWJlbCAiJERJU0siIFNUQVRFKQoJc2Rldj0kKGdwdF9wYXJ0X2RldiAiJERJ
U0siICIkc3RhdGUiKQoKCWlmIFsgLW4gIiRzdGF0ZSIgXSAmJiBbIC1iICIkc2RldiIgXTsgdGhl
bgoJCSMgTmV3ZXIgYnVpbGRzIGtlZXAgc3RhdGVmdWwgaW5zaWRlIGFuIExWTSB0aGluIHBvb2w7
IHRoZSBmaWxlc3lzdGVtCgkJIyBpcyB0aGUgInVuZW5jcnlwdGVkIiB2b2x1bWUgcmF0aGVyIHRo
YW4gdGhlIHBhcnRpdGlvbiBpdHNlbGYuCgkJaWYgYmxraWQgIiRzZGV2IiAyPi9kZXYvbnVsbCB8
IGdyZXAgLXEgTFZNMl9tZW1iZXI7IHRoZW4KCQkJaWYgY29tbWFuZCAtdiB2Z2NoYW5nZSA+L2Rl
di9udWxsIDI+JjE7IHRoZW4KCQkJCXZnY2hhbmdlIC1heSA+L2Rldi9udWxsIDI+JjEKCQkJCXZn
PSQocHZzIC0tbm9oZWFkaW5ncyAtbyB2Z19uYW1lICIkc2RldiIgMj4vZGV2L251bGwgfCB0ciAt
ZCAnWzpzcGFjZTpdJykKCQkJCVsgLW4gIiR2ZyIgXSAmJiBbIC1iICIvZGV2LyR2Zy91bmVuY3J5
cHRlZCIgXSAmJiBzZGV2PSIvZGV2LyR2Zy91bmVuY3J5cHRlZCIKCQkJZWxzZQoJCQkJc2Rldj0n
JwoJCQlmaQoJCWZpCgkJaWYgWyAtbiAiJHNkZXYiIF0gJiYgbW91bnQgIiRzZGV2IiAvbW50L2Ny
b3MvbW50L3N0YXRlZnVsX3BhcnRpdGlvbiAyPi9kZXYvbnVsbDsgdGhlbgoJCQkjIENocm9tZU9T
IGtlZXBzIC91c3IvbG9jYWwgYW5kIC9ob21lIG9uIHN0YXRlZnVsIGluIGRldiBtb2RlLgoJCQlb
IC1kIC9tbnQvY3Jvcy9tbnQvc3RhdGVmdWxfcGFydGl0aW9uL2Rldl9pbWFnZSBdICYmCgkJCQlt
b3VudCAtLWJpbmQgL21udC9jcm9zL21udC9zdGF0ZWZ1bF9wYXJ0aXRpb24vZGV2X2ltYWdlIC9t
bnQvY3Jvcy91c3IvbG9jYWwgMj4vZGV2L251bGwKCQkJWyAtZCAvbW50L2Nyb3MvbW50L3N0YXRl
ZnVsX3BhcnRpdGlvbi9ob21lIF0gJiYKCQkJCW1vdW50IC0tYmluZCAvbW50L2Nyb3MvbW50L3N0
YXRlZnVsX3BhcnRpdGlvbi9ob21lIC9tbnQvY3Jvcy9ob21lIDI+L2Rldi9udWxsCgkJZmkKCWZp
CgoJbW91bnQgLXQgcHJvYyBwcm9jIC9tbnQvY3Jvcy9wcm9jIDI+L2Rldi9udWxsCgltb3VudCAt
dCBzeXNmcyBzeXNmcyAvbW50L2Nyb3Mvc3lzIDI+L2Rldi9udWxsCgltb3VudCAtLWJpbmQgL2Rl
diAvbW50L2Nyb3MvZGV2IDI+L2Rldi9udWxsCgltb3VudCAtLWJpbmQgL3RtcCAvbW50L2Nyb3Mv
dG1wIDI+L2Rldi9udWxsCglyZXR1cm4gMAp9Cgp1bW91bnRfY3JvcygpIHsKCWZvciBtIGluIHRt
cCBkZXYvcHRzIGRldiBzeXMgcHJvYyBob21lIHVzci9sb2NhbCBtbnQvc3RhdGVmdWxfcGFydGl0
aW9uOyBkbwoJCXVtb3VudCAiL21udC9jcm9zLyRtIiAyPi9kZXYvbnVsbAoJZG9uZQoJdW1vdW50
IC9tbnQvY3JvcyAyPi9kZXYvbnVsbCB8fCB1bW91bnQgLWwgL21udC9jcm9zIDI+L2Rldi9udWxs
Cn0KCnNoZWxsX2Nyb3MoKSB7CglwcmludGYgJ1xuJwoJaW5mbyAnQ2hlY2tpbmcgd2hldGhlciBD
aHJvbWVPUyByb290ZnMgdmVyaWZpY2F0aW9uIGlzIG9uLi4uJwoKCWlmIGNyb3NfdmVyaXR5X29u
ICIkRElTSyI7IHRoZW4KCQlwcmludGYgJ1xuJwoJCXByaW50ZiAnICAlc1JPT1RGUyBWRVJJRklD
QVRJT04gSVMgU1RJTEwgT04uJXNcblxuJyAiJFJFRCIgIiRSIgoJCWNhdCA8PCdUWFQnCiAgUk9P
VC1BIGlzIHByb3RlY3RlZCBieSBkbS12ZXJpdHk6IGV2ZXJ5IGJsb2NrIGlzIGNoZWNrc3VtbWVk
IGFnYWluc3QgYSBoYXNoCiAgdHJlZSwgYW5kIHRoZSBrZXJuZWwgcmVmdXNlcyB0aGUgZmlsZXN5
c3RlbSBpZiBhIHNpbmdsZSBieXRlIGRpZmZlcnMuCgogIFdyaXRpbmcgQU5ZVEhJTkcgdG8gUk9P
VC1BIHdoaWxlIHZlcmlmaWNhdGlvbiBpcyBvbiB3aWxsIHN0b3AgQ2hyb21lT1MKICBib290aW5n
LCBhbmQgcmVjb3ZlcnkgbWVkaWEgaXMgdGhlIG9ubHkgd2F5IGJhY2suCgogIFJlYWQtb25seSBp
cyBzYWZlIGFuZCBpcyBhbG1vc3QgY2VydGFpbmx5IHdoYXQgeW91IHdhbnQuIE1vdW50aW5nCiAg
cmVhZC13cml0ZSBpcyBvbmx5IHVzZWZ1bCBpZiB5b3UgYXJlIGFib3V0IHRvIGRpc2FibGUgdmVy
aWZpY2F0aW9uIGFueXdheS4KClRYVAoJCWlmIGNvbmZpcm1fd29yZCAnUlcnOyB0aGVuCgkJCU1P
REU9cncKCQkJd2FybiAnTW91bnRpbmcgUk9PVC1BIHJlYWQtd3JpdGUgd2l0aCB2ZXJpZmljYXRp
b24gT04uJwoJCQl3YXJuICdBbnl0aGluZyB5b3UgY2hhbmdlIGhlcmUgd2lsbCBzdG9wIENocm9t
ZU9TIGZyb20gYm9vdGluZy4nCgkJZWxzZQoJCQlNT0RFPXJvCgkJCXNheSAnTW91bnRpbmcgcmVh
ZC1vbmx5LicKCQlmaQoJZWxzZQoJCU1PREU9cncKCQlnb29kICdWZXJpZmljYXRpb24gaXMgb2Zm
IC0tIG1vdW50aW5nIFJPT1QtQSByZWFkLXdyaXRlLicKCWZpCgoJcHJpbnRmICdcbicKCWlmICEg
bW91bnRfY3JvcyAiJE1PREUiOyB0aGVuCgkJdW1vdW50X2Nyb3MKCQlwYXVzZQoJCXJldHVybiAx
CglmaQoKCWlmIFsgIiRNT0RFIiA9IHJ3IF07IHRoZW4KCQlwcmludGYgJ1xuICAlc0luc2lkZSB0
aGUgQ2hyb21lT1Mgcm9vdCBmaWxlc3lzdGVtIC0tIFJFQUQtV1JJVEUuJXNcbicgIiRZRUwiICIk
UiIKCWVsc2UKCQlwcmludGYgJ1xuICAlc0luc2lkZSB0aGUgQ2hyb21lT1Mgcm9vdCBmaWxlc3lz
dGVtIC0tIHJlYWQtb25seS4lc1xuJyAiJEdSTiIgIiRSIgoJCXByaW50ZiAnICAlc2RtLXZlcml0
eSBpcyB1bnRvdWNoZWQgYW5kIFJPT1QtQSBjYW5ub3QgYmUgbW9kaWZpZWQuJXNcbicgIiREIiAi
JFIiCglmaQoJcHJpbnRmICcgICVzVHlwZSAnIiciJ2V4aXQnIiciJyB0byBjb21lIGJhY2sgdG8g
dGhlIEdsYWNpZXIgbWVudS4lc1xuXG4nICIkRCIgIiRSIgoKCWNocm9vdCAvbW50L2Nyb3MgL2Jp
bi9zaCAtbCAyPi9kZXYvbnVsbCB8fCBjaHJvb3QgL21udC9jcm9zIC9iaW4vc2gKCXN5bmMKCXVt
b3VudF9jcm9zCglyZXR1cm4gMAp9CgojIC0tLSAzOiBhIHNoZWxsIGluIEdsYWNpZXIgaXRzZWxm
IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpzaGVsbF9nbGFj
aWVyKCkgewoJcHJpbnRmICdcbiAgJXNHbGFjaWVyIHNoZWxsLiVzICBEaXNrOiAlcyVzJXNcbicg
IiRHUk4iICIkUiIgIiRCIiAiJERJU0siICIkUiIKCXByaW50ZiAnICAlc1R5cGUgJyInIidleGl0
JyInIicgdG8gY29tZSBiYWNrIHRvIHRoZSBtZW51LiVzXG5cbicgIiREIiAiJFIiCgkvYmluL3No
IC1sIDI+L2Rldi9udWxsIHx8IC9iaW4vc2gKfQoKIyAtLS0gcGFydGl0aW9uIHN1bW1hcnkgLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQoKc2hv
d19zbG90cygpIHsKCWZvciBsYmwgaW4gS0VSTi1BIEtFUk4tQiBLRVJOLUM7IGRvCgkJbj0kKGdw
dF9udW1fYnlfbGFiZWwgIiRESVNLIiAiJGxibCIpCgkJWyAtbiAiJG4iIF0gfHwgY29udGludWUK
CQlwPSQoZ3B0X2ZpZWxkICIkRElTSyIgIiRuIiBwcmlvcml0eSkKCQl0PSQoZ3B0X2ZpZWxkICIk
RElTSyIgIiRuIiB0cmllcykKCQlzPSQoZ3B0X2ZpZWxkICIkRElTSyIgIiRuIiBzdWNjZXNzZnVs
KQoJCW1hcmtlcj0nICAnCgkJWyAiJGxibCIgPSBLRVJOLUMgXSAmJiBtYXJrZXI9IiR7QkxVfT0+
JHtSfSIKCQlwcmludGYgJyAgJXMgJS04cyBwYXJ0ICUtM3MgcHJpb3JpdHkgJS0zcyB0cmllcyAl
LTNzIG9rICVzXG4nIFwKCQkJIiRtYXJrZXIiICIkbGJsIiAiJG4iICIkcCIgIiR0IiAiJHMiCglk
b25lCn0KCiMgLS0tIG1haW4gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCmlmICEgZmluZF9kaXNrOyB0aGVuCglvb3Bz
ICdObyBDaHJvbWVPUyBkaXNrIGZvdW5kLiBEcm9wcGluZyB0byBhIHNoZWxsLicKCWV4aXQgMQpm
aQoKd2hpbGUgOjsgZG8KCXByaW50ZiAnXDAzM1tIXDAzM1sySicKCXByaW50ZiAnXG4gICVzR0xB
Q0lFUiVzICAlc2Jvb3QgZW52aXJvbm1lbnQlcyAgJXMlcyVzXG5cbicgXAoJCSIkQiRCTFUiICIk
UiIgIiRCIiAiJFIiICIkRCIgIiRHTEFDSUVSX1ZFUlNJT04iICIkUiIKCXByaW50ZiAnICAlc2Rp
c2slcyAlc1xuXG4nICIkRCIgIiRSIiAiJERJU0siCglzaG93X3Nsb3RzCglwcmludGYgJ1xuJwoJ
cHJpbnRmICcgICVzMSVzICBCb290IENocm9tZU9TXG4nICIkWUVMIiAiJFIiCglwcmludGYgJyAg
JXMyJXMgIFNoZWxsICAlcyhjaHJvb3QgaW50byBDaHJvbWVPUyklc1xuJyAiJFlFTCIgIiRSIiAi
JEQiICIkUiIKCXByaW50ZiAnICAlczMlcyAgU2hlbGwgICVzKEdsYWNpZXIpJXNcbicgIiRZRUwi
ICIkUiIgIiREIiAiJFIiCglwcmludGYgJyAgJXM0JXMgIFJlYm9vdCAgICAgICAgJXM1JXMgIFBv
d2VyIG9mZlxuJyAiJFlFTCIgIiRSIiAiJFlFTCIgIiRSIgoJcHJpbnRmICdcbiAgU2VsZWN0OiAn
CglyZWFkIC1yIGNob2ljZSB8fCBjaG9pY2U9NAoJY2FzZSAiJGNob2ljZSIgaW4KCQkxKSBib290
X2Nocm9tZW9zIDs7CgkJMikgc2hlbGxfY3JvcyA7OwoJCTMpIHNoZWxsX2dsYWNpZXIgOzsKCQk0
KSBzeW5jOyByZWJvb3QgLWYgOzsKCQk1KSBzeW5jOyBwb3dlcm9mZiAtZiA7OwoJZXNhYwpkb25l
Cg==
GLACIER_B64
	base64 -d >"$d/glacier-gpt.sh" <<'GLACIER_B64'
IyBzaGVsbGNoZWNrIHNoZWxsPXNoCiMKIyBHbGFjaWVyIDo6IHBheWxvYWQvZ2xhY2llci1ncHQu
c2ggLS0gcmVhZCBhbmQgd3JpdGUgQ2hyb21lT1MgR1BUIGJvb3QKIyBhdHRyaWJ1dGVzIGZyb20g
aW5zaWRlIHRoZSBHbGFjaWVyIGVudmlyb25tZW50LCB1c2luZyBzZ2Rpc2suCiMKIyBDaHJvbWVP
UyBwYWNrcyB0aHJlZSBmaWVsZHMgaW50byB0aGUgR1BUIGF0dHJpYnV0ZSB3b3JkIG9mIGV2ZXJ5
IGtlcm5lbAojIHBhcnRpdGlvbi4gVmVyaWZpZWQgYWdhaW5zdCBjZ3B0IG9uIGEgc2NyYXRjaCBk
aXNrOgojCiMgICBiaXRzIDQ4LTUxICBwcmlvcml0eSAgICgwLTE1OyAwIG1lYW5zICJuZXZlciBi
b290IHRoaXMiKQojICAgYml0cyA1Mi01NSAgdHJpZXMgICAgICAocmVtYWluaW5nIGJvb3QgYXR0
ZW1wdHMpCiMgICBiaXQgIDU2ICAgICBzdWNjZXNzZnVsICh0aGlzIGtlcm5lbCBib290ZWQgY2xl
YW5seSBhdCBsZWFzdCBvbmNlKQojCiMgVGhlIGZpcm13YXJlIGJvb3RzIHRoZSBrZXJuZWwgcGFy
dGl0aW9uIHdpdGggdGhlIGhpZ2hlc3QgcHJpb3JpdHkgdGhhdCBoYXMKIyBzdWNjZXNzZnVsPTEg
b3IgdHJpZXM+MC4gY2dwdCBpc24ndCBpbiB0aGlzIGVudmlyb25tZW50IC0tIGl0IGlzIGEgZ2xp
YmMKIyBDaHJvbWVPUyBiaW5hcnkgYW5kIEdsYWNpZXIgaXMgbXVzbCAtLSBzbyBzZ2Rpc2sgZG9l
cyB0aGUgd29yayBpbnN0ZWFkLgoKUFJJT19TSElGVD00OApBVFRSX1BSSU9fTUFTSz0nMHgwMDBG
MDAwMDAwMDAwMDAwJwoKIyBBdHRyaWJ1dGUgd29yZCBvZiBhIHBhcnRpdGlvbiwgYXMgYSBwbGFp
biBoZXggc3RyaW5nLgpncHRfYXR0cigpIHsgIyA8ZGlzaz4gPHBhcnRudW0+CglzZ2Rpc2sgLS1p
bmZvPSIkMiIgIiQxIiAyPi9kZXYvbnVsbCB8CgkJc2VkIC1uICdzL15BdHRyaWJ1dGUgZmxhZ3M6
ICpcKFswLTlBLUZhLWZdKlwpLiovXDEvcCcKfQoKZ3B0X2ZpZWxkKCkgeyAjIDxkaXNrPiA8cGFy
dG51bT4gcHJpb3JpdHl8dHJpZXN8c3VjY2Vzc2Z1bAoJYXR0cj0kKGdwdF9hdHRyICIkMSIgIiQy
IikKCVsgLW4gIiRhdHRyIiBdIHx8IHJldHVybiAxCgl2YWw9JChwcmludGYgJyVkJyAiMHgkYXR0
ciIgMj4vZGV2L251bGwpIHx8IHJldHVybiAxCgljYXNlICIkMyIgaW4KCQlwcmlvcml0eSkgICBw
cmludGYgJyVkJyAkKCggKHZhbCA+PiA0OCkgJiAweEYgKSkgOzsKCQl0cmllcykgICAgICBwcmlu
dGYgJyVkJyAkKCggKHZhbCA+PiA1MikgJiAweEYgKSkgOzsKCQlzdWNjZXNzZnVsKSBwcmludGYg
JyVkJyAkKCggKHZhbCA+PiA1NikgJiAweDEgKSkgOzsKCQkqKSByZXR1cm4gMSA7OwoJZXNhYwp9
CgojIFJld3JpdGUgcHJpb3JpdHkgd2hpbGUgbGVhdmluZyB0cmllcyBhbmQgc3VjY2Vzc2Z1bCBh
bG9uZS4KIwojIFRoaXMgc2V0cyBhbmQgY2xlYXJzIHRoZSBmb3VyIHByaW9yaXR5IGJpdHMgaW5k
aXZpZHVhbGx5IHJhdGhlciB0aGFuCiMgYXNzaWduaW5nIHRoZSBhdHRyaWJ1dGUgd29yZCBpbiBv
bmUgZ28uIHNnZGlzaydzICI9IiBhc3NpZ25tZW50IGZvcm0gaXMgbm90CiMgYWNjZXB0ZWQgYnkg
ZXZlcnkgYnVpbGQgLS0gZ3B0ZmRpc2sgMS4wLjEwIHJlamVjdHMgaXQgd2l0aCAiQ291bGQgbm90
CiMgY29udmVydCBoZXggYXR0cmlidXRlIG1hc2siIC0tIHdoZXJlYXMgc2V0L2NsZWFyIGlzIHVu
ZGVyc3Rvb2QgZXZlcnl3aGVyZS4KZ3B0X3NldF9wcmlvcml0eSgpIHsgIyA8ZGlzaz4gPHBhcnRu
dW0+IDwwLTE1PgoJX2Q9JDEKCV9wPSQyCglfdj0kMwoJX2FyZ3M9JycKCV9pPTAKCXdoaWxlIFsg
IiRfaSIgLWx0IDQgXTsgZG8KCQlpZiBbICQoKCAoX3YgPj4gX2kpICYgMSApKSAtZXEgMSBdOyB0
aGVuCgkJCV9hcmdzPSIkX2FyZ3MgLS1hdHRyaWJ1dGVzPSRfcDpzZXQ6JCgoNDggKyBfaSkpIgoJ
CWVsc2UKCQkJX2FyZ3M9IiRfYXJncyAtLWF0dHJpYnV0ZXM9JF9wOmNsZWFyOiQoKDQ4ICsgX2kp
KSIKCQlmaQoJCV9pPSQoKF9pICsgMSkpCglkb25lCgkjIHNoZWxsY2hlY2sgZGlzYWJsZT1TQzIw
ODYKCXNnZGlzayAkX2FyZ3MgIiRfZCIgPi9kZXYvbnVsbCAyPiYxCn0KCmdwdF9tYXJrX2dvb2Qo
KSB7ICMgPGRpc2s+IDxwYXJ0bnVtPiAtLSBzdWNjZXNzZnVsPTEsIHRyaWVzPTAKCXNnZGlzayAi
LS1hdHRyaWJ1dGVzPSQyOnNldDo1NiIgXAoJCSItLWF0dHJpYnV0ZXM9JDI6Y2xlYXI6NTIiICIt
LWF0dHJpYnV0ZXM9JDI6Y2xlYXI6NTMiIFwKCQkiLS1hdHRyaWJ1dGVzPSQyOmNsZWFyOjU0IiAi
LS1hdHRyaWJ1dGVzPSQyOmNsZWFyOjU1IiBcCgkJIiQxIiA+L2Rldi9udWxsIDI+JjEKfQoKCiMg
UGFydGl0aW9uIG51bWJlciBjYXJyeWluZyBhIEdQVCBuYW1lLCBlLmcuIEtFUk4tQS4gc2dkaXNr
IHByaW50cyB0aGUgbmFtZSBpbgojIHRoZSBsYXN0IGNvbHVtbiBvZiBpdHMgcGFydGl0aW9uIGxp
c3RpbmcuCmdwdF9udW1fYnlfbGFiZWwoKSB7ICMgPGRpc2s+IDxsYWJlbD4KCXNnZGlzayAtcCAi
JDEiIDI+L2Rldi9udWxsIHwgYXdrIC12IHdhbnQ9IiQyIiAnCgkJL15bIF0qWzAtOV0rLyB7CgkJ
CW5hbWUgPSAiIgoJCQlmb3IgKGkgPSA3OyBpIDw9IE5GOyBpKyspIG5hbWUgPSBuYW1lIChuYW1l
ID8gIiAiIDogIiIpICRpCgkJCWlmIChuYW1lID09IHdhbnQpIHsgcHJpbnQgJDE7IGV4aXQgfQoJ
CX0nCn0KCmdwdF9wYXJ0dXVpZCgpIHsgIyA8ZGlzaz4gPHBhcnRudW0+CglzZ2Rpc2sgLS1pbmZv
PSIkMiIgIiQxIiAyPi9kZXYvbnVsbCB8CgkJc2VkIC1uICdzL15QYXJ0aXRpb24gdW5pcXVlIEdV
SUQ6ICovL3AnCn0KCiMgL2Rldi9zZGEgKyAzIC0+IC9kZXYvc2RhMzsgL2Rldi9tbWNibGswICsg
MyAtPiAvZGV2L21tY2JsazBwMy4KZ3B0X3BhcnRfZGV2KCkgeyAjIDxkaXNrPiA8cGFydG51bT4K
CWNhc2UgIiQxIiBpbgoJCSpbMC05XSkgcHJpbnRmICclc3AlcycgIiQxIiAiJDIiIDs7CgkJKikg
cHJpbnRmICclcyVzJyAiJDEiICIkMiIgOzsKCWVzYWMKfQoKIyBGaW5kIHRoZSBpbnRlcm5hbCBD
aHJvbWVPUyBkaXNrIGFnYWluIGF0IHJ1bnRpbWUgcmF0aGVyIHRoYW4gdHJ1c3RpbmcgYQojIGRl
dmljZSBuYW1lIHJlY29yZGVkIGF0IGluc3RhbGwgdGltZS4KZ3B0X2ZpbmRfY3Jvc19kaXNrKCkg
ewoJZm9yIGQgaW4gL2Rldi9tbWNibGtbMC05XSAvZGV2L252bWVbMC05XW5bMC05XSAvZGV2L3Nk
W2Etel07IGRvCgkJWyAtYiAiJGQiIF0gfHwgY29udGludWUKCQljYXNlICIkZCIgaW4gKmJvb3Rb
MC05XSB8ICpycG1iKSBjb250aW51ZSA7OyBlc2FjCgkJbGlzdGluZz0kKHNnZGlzayAtcCAiJGQi
IDI+L2Rldi9udWxsKSB8fCBjb250aW51ZQoJCWNhc2UgIiRsaXN0aW5nIiBpbgoJCQkqS0VSTi1B
KikgY2FzZSAiJGxpc3RpbmciIGluICpST09ULUEqKSBwcmludGYgJyVzJyAiJGQiOyByZXR1cm4g
MCA7OyBlc2FjIDs7CgkJZXNhYwoJZG9uZQoJcmV0dXJuIDEKfQoKIyBJcyBDaHJvbWVPUyBzdGls
bCBzZXQgdXAgdG8gdmVyaWZ5IGl0cyByb290IGZpbGVzeXN0ZW0/CiMKIyBHbGFjaWVyIGNhbm5v
dCByZWFkIC9wcm9jL2NtZGxpbmUgZm9yIHRoaXMgLS0gdGhhdCBpcyBHbGFjaWVyJ3Mgb3duIGNv
bW1hbmQKIyBsaW5lLCBub3QgQ2hyb21lT1Mncy4gVGhlIGF1dGhvcml0eSBpcyB0aGUgY29tbWFu
ZCBsaW5lIHN0b3JlZCBpbnNpZGUgdGhlCiMgS0VSTi1BIGJsb2IsIHdoaWNoIHNpdHMgaW4gdGhl
IHBhcnRpdGlvbiBhcyBwbGFpbiB0ZXh0LiBXaXRoIHZlcmlmaWNhdGlvbiBvbgojIGl0IHNheXMg
cm9vdD0vZGV2L2RtLTA7IG1ha2VfZGV2X3NzZC5zaCAtLXJlbW92ZV9yb290ZnNfdmVyaWZpY2F0
aW9uCiMgcmV3cml0ZXMgdGhhdCB0byBwb2ludCBzdHJhaWdodCBhdCB0aGUgcm9vdGZzIHBhcnRp
dGlvbi4KIwojIFJldHVybnMgMCAodmVyaWZpY2F0aW9uIG9uKSB3aGVuIGl0IGNhbm5vdCB0ZWxs
LCBiZWNhdXNlIHRoYXQgaXMgdGhlIGFuc3dlcgojIHRoYXQga2VlcHMgUk9PVC1BIHJlYWQtb25s
eS4KY3Jvc192ZXJpdHlfb24oKSB7ICMgPGRpc2s+CglrZXJuX2E9JChncHRfbnVtX2J5X2xhYmVs
ICIkMSIgS0VSTi1BKQoJWyAtbiAiJGtlcm5fYSIgXSB8fCByZXR1cm4gMAoJa2Rldj0kKGdwdF9w
YXJ0X2RldiAiJDEiICIka2Vybl9hIikKCVsgLWIgIiRrZGV2IiBdIHx8IFsgLWYgIiRrZGV2IiBd
IHx8IHJldHVybiAwCgkjIFJlYWQgdGhlIHBhcnRpdGlvbiBkaXJlY3RseSByYXRoZXIgdGhhbiBw
aXBpbmcgZGQgaW50byBncmVwOiBncmVwIC1xCgkjIGV4aXRzIG9uIHRoZSBmaXJzdCBtYXRjaCwg
d2hpY2ggU0lHUElQRXMgZGQsIGFuZCB1bmRlciBgc2V0IC1vIHBpcGVmYWlsYAoJIyB0aGF0IHR1
cm5zIGEgc3VjY2Vzc2Z1bCBtYXRjaCBpbnRvIGEgZmFpbGVkIHBpcGVsaW5lLgoJZ3JlcCAtYXEg
J3Jvb3Q9L2Rldi9kbS0nICIka2RldiIgMj4vZGV2L251bGwKfQo=
GLACIER_B64
	chmod 0755 "$d/init" "$d/glacier-menu"
	printf %s "$d"
}

glacier_usage() {
	cat <<USAGE
glacier $GLACIER_VERSION

  Dual-boot groundwork for Chromebooks. Run as root from VT2 in developer
  mode. With no command, opens a menu.

Commands:
  resize        Shrink the ChromeOS stateful partition to free disk space.
  install       Install the Glacier boot environment into KERN-C / ROOT-C.
  uninstall     Remove Glacier and hand booting back to ChromeOS.

Options:
  --dry-run     Print every disk-modifying command instead of running it.
  --ascii       Draw the UI with ASCII instead of block-drawing characters.
  --debug       Echo subcommand output rather than logging it.
  -h, --help    This text.

  'resize' and 'install' take further options of their own; pass --help
  after the command to see them.

Environment:
  GLACIER_LOG   Log file (default /tmp/glacier.log).
  GLACIER_DISK  Operate on a specific disk instead of autodetecting.
USAGE
}

glacier_banner() {
	ui_clear
	printf '%s  GLACIER%s  %s%s%s\n\n' \
		"$C_BOLD$C_BLU" "$C_RESET" "$C_DIM" "$GLACIER_VERSION" "$C_RESET"
}

# A one-line view of where this machine currently stands, so the menu can say
# what each option would actually do.
glacier_status() {
	local disk ss gap_start gap_len
	disk=${GLACIER_DISK:-$(find_cros_disk)} || {
		printf '  %sNo ChromeOS disk found.%s\n' "$C_RED" "$C_RESET"
		return 1
	}
	ss=$(disk_sector_size "$disk")
	stateful_probe "$disk" "$ss" || return 1
	read -r gap_start gap_len < <(gpt_largest_gap "$disk")
	: "$gap_start"

	printf '  %-16s %s\n' 'Disk' "$disk"
	printf '  %-16s %s %s(%s)%s\n' 'Stateful' "$(fmt_size "$ST_BYTES")" \
		"$C_DIM" "$(case "$ST_KIND" in
			plain) printf 'ext4' ;;
			lvm) printf 'LVM -- not resizable' ;;
			*) printf 'unrecognised' ;;
		esac)" "$C_RESET"
	printf '  %-16s %s\n' 'Free space' "$(fmt_size "$((gap_len * ss))")"

	local kc
	if kc=$(part_num_by_label "$disk" KERN-C); then
		if [ "$(part_size "$disk" "$kc")" -gt 1 ]; then
			printf '  %-16s %sinstalled%s\n' 'Glacier' "$C_GRN" "$C_RESET"
			GLACIER_PRESENT=1
		else
			printf '  %-16s %snot installed%s\n' 'Glacier' "$C_DIM" "$C_RESET"
			GLACIER_PRESENT=0
		fi
	fi
	return 0
}

glacier_menu() {
	local choice
	while :; do
		glacier_banner
		glacier_status || { ui_pause; exit 1; }
		printf '\n%s%s%s\n' "$C_DIM" "$(ui_rule)" "$C_RESET"
		printf '  %s1%s  Resize the ChromeOS stateful partition\n' "$C_YEL" "$C_RESET"
		printf '      %sfree up space for Glacier or another Linux system%s\n' "$C_DIM" "$C_RESET"
		printf '  %s2%s  Install the Glacier boot environment\n' "$C_YEL" "$C_RESET"
		printf '      %sinto the unused KERN-C / ROOT-C slots%s\n' "$C_DIM" "$C_RESET"
		if [ "${GLACIER_PRESENT:-0}" = 1 ]; then
			printf '  %s3%s  Remove Glacier\n' "$C_YEL" "$C_RESET"
		fi
		printf '  %sq%s  Quit\n' "$C_YEL" "$C_RESET"
		printf '\nSelect: '
		read -r choice || choice=q
		case "$choice" in
			1) resize_main ;;
			2) install_main ;;
			3) [ "${GLACIER_PRESENT:-0}" = 1 ] && install_main --uninstall ;;
			q | Q) exit 0 ;;
		esac
	done
}

main() {
	local cmd=''

	ui_init
	require_root_vt
	require_cmds cgpt blockdev awk sed grep

	# Do this before anything else: once stateful is unmounted, a script
	# running from it disappears mid-read, because bash reads scripts
	# incrementally. Re-exec with the ORIGINAL arguments -- doing it after the
	# parse loop below would hand the new process a list with the subcommand
	# already shifted off.
	self_relocate "$@"

	# Global flags may come before or instead of a command.
	while [ $# -gt 0 ]; do
		case "$1" in
			resize | install | uninstall)
				cmd=$1
				shift
				break
				;;
			--dry-run) GLACIER_DRY_RUN=1 ;;
			--ascii) GLACIER_ASCII=1 ;;
			--debug) GLACIER_DEBUG=1 ;;
			-h | --help)
				glacier_usage
				exit 0
				;;
			*)
				glacier_usage >&2
				exit 1
				;;
		esac
		shift
	done

	: >"$GLACIER_LOG" 2>/dev/null || :
	log "glacier $GLACIER_VERSION starting (cmd=${cmd:-menu})"

	case "$cmd" in
		resize) resize_main "$@" ;;
		install) install_main "$@" ;;
		uninstall) install_main --uninstall "$@" ;;
		*) glacier_menu ;;
	esac
}

main "$@"
