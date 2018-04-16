#!/bin/sh

#set -o errexit
#set -o nounset
#set -x

: ${HIDE_BUILD:=}
: ${PM_EXCL:=}
: ${REPLACE_ORIGIN:=}
: ${UPDATE_ALL:=}

# ----------------------------------------------------------------------------------
# main program (after options processing)
trap_exit () {
	pm_rmtemp FETCH_RE
	pm_rmtemp FETCH_ACK
	exit 0
}

trap_int () {
	pm_rmtemp FETCH_RE
	pm_rmtemp FETCH_ACK
	exit 1
}

trap trap_exit EXIT
trap trap_int INT

# ----------------------------------------------------------------------------------
#
read_nl () {
	local dummy

	pm_msg -n "$@"
	read dummy
}

# read "y" or "n" from STDIN, with default provided for empty input lines
read_yn () {
	local default="$1"
	shift
	local prompt="$*"
	local default_txt

	case $default in
	Y|y)
		default_txt=" [Y/n]" ;;
	N|n)
		default_txt=" [y/N]" ;;
	*)
		default_txt=" [y/n]" ;;
	esac
	while true; do
		echo -n "$prompt$default_txt: "
		read reply
		[ -n "$reply" ] || reply="$default"
		case $reply in
		Y|y)
			return 0 ;;
		N|n)
			return 1 ;;
		"")
			[ "$default" ]
		esac
	done
	return 1
}

# ----------------------------------------------------------------------------------
#
worklist_add () {
	local origin="$1"

	WORKLIST="$WORKLIST $origin "
}

worklist_remove () {
	local origin="$1"

	case "$WORKLIST" in
	*" $origin "*)
		WORKLIST="${WORKLIST% $origin *}${WORKLIST#* $origin }"
	esac
}

# return the make variable named "$var" for port in "$dir"
origin_var () {
	local dir=$(dir_part "$1")
	local flavor=$(flavor_part "$1")
	shift
	local var query_list=

	[ -d "$dir" ] || dir="$pd/$dir"
	for var in "$@"; do
		query_list="$query_list -V $var"
	done
#	local result=$(FLAVOR=$flavor make -D BEFOREPORTMK -C "$dir" $query_list 2>/dev/null)
	local result=$(FLAVOR=$flavor make -C "$dir" $query_list 2>/dev/null)
	case $result in
	""|"
make: "*)
		return 1 ;;
	esac
	echo "$result"
}

# check conflicts of new port with installed ports
check_conflicts () {
	local origin_new="$1"
	local dir=$(dir_part "$1")
	local conflicts glob conflicting_pkg

	conflicts=$(port_make "$origin_new" check-conflicts ) && return 1
	while read line; do
		[ -z "$line" ] && continue
		[ "${line%% *}" = "===>" ] && continue
		# return only first conflicting package
		if [ -n "$line" ]; then
			echo $line 
			return 0
		fi
	done <<EOF
$conflicts
EOF
	return 1
}

# check parameter against PM_EXCL set
check_exclude () {
	local pattern

	[ -z "$PM_EXCL" ] && return 1
	for name in "$@"; do
		set_contains SKIPPED "$name" && return 0
		for pattern in " $PM_EXCL"; do
			case "$name" in
			*" ${pattern} "*)
				set_add SKIPPED "$name"
				pm_m "===>>> Skipping $name because it matches the pattern: *${pattern}*"
				pm_m
				return 0 ;;
			esac
		done
	done
	return 1
}

# return true (exit code 0) if named package was only installed as a dependency
pkgdb_check_automatic () {
	local pkgname="$1"

	[ "$(pkg query %a "$pkgname")" = "1" ]
}

# return true (exit code 0) if named package is locked
pkgdb_check_locked () {
	local pkgname="$1"

	[ "$(pkg query %k "$pkgname")" = "1" ] || [ -e "$pdb/$pkgname/+IGNOREME" ]
}

# return all installed flavors of the named port or package
pkgdb_flavors () {
	pkg annotate -Sq "$1" flavor
}

# return origin with optional flavor for given specific (!) pkgname
pkgdb_origin_flavor () {
	local pkgname="$1"
	local origin flavor

	origin=$(pkg query "%o" "$pkgname") || return 1
	case $origin in
	*" "*)
		return 1 ;;
	esac
	flavor=$(pkg annotate -Sq "$pkgname" flavor)
set -x
	echo "$origin${flavor:+@$flavor}"
set +x
}

# return pkgname(s) for origin(globs) with optional flavor
pkgdb_pkgnames () {
	local dir=$(dir_part "$1")
	local flavor=$(flavor_part "$1")
	local pkgname result

	[ -z "$dir" ] && return 1
	if [ -n "$flavor" ]; then
		while read pkgname tag value; do
			[ "$tag" = "flavor" -a "$value" = "$flavor" ] && result="$result $pkgname"
		done <<EOF
		$(pkg query -g "%n-%v %At %Av" "$dir")
EOF
	fi
	[ -n "$result" ] || result=$(pkg query -g "%n-%v" "$dir") || return 1
	echo $result
}

# return the single pkgname for origin(globs) with optional flavor or false status (for 0 or >=2 matechs)
pkgdb_pkgname () {
	local origin_old="$1"
	local origin_new="$2"
	local pkgname

	if pkgname=$(pkgdb_pkgnames "$origin_old") && [ "$(echo $pkgname)" = "${pkgname%* }" ]; then
		echo $pkgname
		return 0
	fi
	[ "$origin_old" = "$origin_new" ] && return 1
	if pkgname=$(pkgdb_pkgnames "$1") && [ "$(echo $pkgname)" = "${pkgname%* }" ]; then
		echo $pkgname
		return 0
	fi
	return 1
}

# query package DB for passed port (with optional flavor) or package
pkgdb_var () {
	local name="$1"
	local fields="$2"
	local pkgname

	pkgname=$(pkgdb_pkgname "$name") || return 1
	pkg query "$fields" "$pkgname"
}

# return new origin@flavor for given old origin@flavor
origin_new_from_port () {
	local origin=$(dir_part "$1")
	local flavor=$(flavor_part "$1")
	local flavors origin_new line reason

	if [ -z "$flavor" ]; then
		flavors="$(origin_var "$origin" FLAVORS)" && flavor=${flavors%% *}
	fi	
	origin_new="$origin"
	while : ;do
		line="$(grep -m 1 "^${origin_new}|" /usr/ports/MOVED)" || break
		line=${line#*|}
		origin_new=${line%%|*}
		reason=${line#$origin_new|*|}
		dict_set REASON_MOVED "$origin_new" "$reason"
	done
	case $origin_new in
	*@*)	;;
	*)	[ -n "$flavor" ] && origin_new="$origin_new@$flavor" ;;
	esac
	if [ -n "$reason" ]; then
		pm_msg
		if [ -n "$origin_new" ]; then
			pm_msg "===>>> The $origin_old port has been moved to $origin_new"
		else
			pm_msg "===>>> The $origin_old port has been deleted"
		fi
		pm_msg "===>>> Reason:" $reason
		pm_msg
	fi
	echo $origin_new
}

# return new origin@flavor for given old origin@flavor
origin_old_from_origin_new () {
	local origin="$1"
	local line origin_old

	while : ;do
		line="$(grep -m 1 "^[^|]*|${origin}|" /usr/ports/MOVED)" || break
		origin=${line%%|*}
		if origin_old=$(pkgdb_var "$origin" "%o"); then
			echo $origin_old
			return
		fi
	done
}

# return origin corresponding to given relative or absolute directory
origin_from_dir () {
	local dir_glob="$1"
	local dir

	for dir in $dir_glob $pd/$dir_glob; do
		if ! [ -d "$dir" ]; then
			while [ "${dir#*/*/}" != "$dir" ]; do
				dir=${dir#*/}
			done
		fi
		origin_var "$dir" PKGORIGIN
	done | sort -u
}

# return all origin@flavor for port(s) in relative or absolute directory "$dir"
origin_old_from_port () {
	local dir_glob=$(dir_part "$1")
	local flavors=$(flavor_part "$1")
	local origin flavor

	for origin in $(origin_from_dir "$dir_glob"); do
		[ -n "$flavors" ] ||
			flavors=$(origin_var "$origin" FLAVORS) ||
			flavors=$(pkgdb_flavors $origin)
		if [ -n "$flavors" ]; then
			for flavor in $flavors; do
				
				echo $origin@$flavor
			done
		else
			echo $origin
		fi
	done
}

add_skipped () {
	PM_EXCL="$PM_EXCL $1"
} 

add_one_build_dep () {
	local make_target="$1"
	local dep_origin="$2"

pm_msg "ADD_ONE_BUILD_DEP make -C $dep_origin $make_target"
}

RECURSIVE_MSG="===>>>"

# ----------------------------------------------------------------------------------
# register build dependencies for given origin
register_depends () {
pm_msg "REGISTER_DEPENDS $*"
	local phase="$1"
	local origin="$2"
	shift 2
	local deps="$*"
	local dep conflicting_pkg dep_origin make_target origin_old origin_new
	local recursive_msg_save="$RECURSIVE_MSG"
	RECURSIVE_MSG="$RECURSIVE_MSG $origin >>"
set -x
	for dep in $deps; do
		dep_origin=${dep%:*}
		make_target=$(target_part $dep)
		case make_target in
		extract|patch)
			add_one_build_dep "$make_target" "$dep_origin" ;;
		*)
			add_one_port auto "" $dep_origin ;;
		esac
	done
set +x
	RECURSIVE_MSG="$recursive_msg_save"
	return 0
}

# list dependencies for given origin
list_depends () {
	local origin="$1"
	shift
	local vars="$*"
	local dep cond dep_origin make_target

	for dep in $(origin_var "$origin" $vars); do
		echo ${dep#*:}
	done
}

register_build_depends () {
	register_depends BUILD "$1" $(list_depends "$1" BUILD_DEPENDS EXTRACT_DEPENDS \
					FETCH_DEPENDS LIB_DEPENDS PATCH_DEPENDS PKG_DEPENDS)
#	register_depends BUILD "$1" $(port_make "$1" build-depends)
}

register_run_depends () {
	register_depends RUN "$1" $(list_depends "$1" LIB_DEPENDS RUN_DEPENDS)
}

register_test_depends () {
	register_depends TEST "$1" $(list_depends "$1" TEST_DEPENDS)
}

# update port origin in installed package
register_moved () {
	local origin_old="$1"
	local origin_new="$2"
	local pkgname_old="$3"

	set_contains MOVES "$origin_new" && return

	if check_exclude "$pkgname_new" "$origin_new"; then
		add_skipped "$origin_new"
		return 1
	fi
	
	set_add MOVES "$origin_new"
	dict_set ORIGIN_OLD "$origin_new" "$origin_old"
	dict_set PKGNAME_OLD "$origin_new" "$pkgname_old"
	pm_msg "MOVED ORIGIN $pkgname_old ($origin_old -> $origin_new)"
}

# rename package without version change
register_pkgname_chg () {
	local origin_new="$1"
	local pkgname_old="$2"
	local pkgname_new="$3"

	set_contains PKG_RENAMES "$origin_new" && return
	if check_exclude "$pkgname_new" "$origin_new"; then
		add_skipped "$origin_new"
		return 1
	fi

	set_add PKG_RENAMES "$origin_new"
	dict_set PKGNAME_OLD "$origin_new" "$pkgname_old"
	dict_set PKGNAME_NEW "$origin_new" "$pkgname_new"
	pm_msg "RENAME $pkgname_old -> $pkgname_new ($origin_new)"
}

# delete installed package
register_delete () {
	local pkgname_old="$1"

	set_contains DELETES "$pkgname_old" && return 0

	set_add DELETES "$pkgname_old"
	pm_msg "DELETE $pkgname_old"
}

# execute passed arguments as root
sudo () {
	eval "$@"
}

# call make for origin with arguments
port_make () {
	local dir=$(dir_part "$1")
	local flavor=$(flavor_part "$1")
	shift

	FLAVOR=$flavor make -C $pd/$dir "$@"
}

#
port_make_s () {
	local dir=$(dir_part "$1")
	local flavor=$(flavor_part "$1")
	shift

	sudo env FLAVOR=$flavor make -C $pd/$dir "$@"
}

# optionally or forcefully configure port
configure_port () {
	local origin_new="$1"
	local force="$2"

	if [ -n "$force" ]; then
		port_make_s "$origin_new" config
	else
		port_make_s "$origin_new" config-conditional
	fi
}

# check whether port is marked BROKEN, IGNORE, or FORBIDDEN
check_forbidden () {
	local origin="$1"
	local dir=$(dir_part "$1")
	local ignore_type ignore_reason

	if egrep -ql '^(FORBIDDEN|BROKEN|IGNORE)' $pd/$dir/Makefile; then
		for ignore_type in FORBIDDEN BROKEN IGNORE; do
			ignore_reason=$(origin_var $origin $ignore_type)
			if [ -n "$ignore_reason" ]; then
				pm_msg "	===>>> This port is marked $ignore_type"
				pm_msg "	===>>> $ignore_reason"
				pm_msg
				return 0
			fi
		done
	fi
	return 1
}

#
port_has_options () {
	local dir=$(dir_part "$1")

	grep -ql '^OPTIONS' $pd/$dir/Makefile
}

#
port_is_interactive () {
	local dir=$(dir_part "$1")

	grep -ql '^IS_INTERACTIVE' $pd/$dir/Makefile
}

#
background_fetch () {
	local INP="$1"
	local OUTP="$2"
	local origin fetchlog
	
	tail -f $INP | while read origin; do
		[ -z "$origin" ] && break	# stop on empty input line
		[ -f "$INP" ] || break		# stop if input file has been removed
		if fetchlog=$(port_make "$origin" -DBATCH -DDISABLE_CONFLICTS checksum); then
			echo "OK $origin"
pm_msg "CHECKSUM OK $origin"
		else
			echo "NOTOK $origin"
pm_msg "CHECKSUM NOTOK $origin"
			fetchlog=$(echo "fetchlog"|grep '^=> '|grep -v " Checksum OK "|sort -u)
			echo "$fetchlog"
#			pm_msg "$fetchlog"
			echo "/NOTOK"
		fi
	done > $OUTP
	echo "%%EOF%%" >> $OUTP
}

# fetch and check distfiles (in background?)
fetch_check_distfiles () {
	local origin="$1"
	local fetchlog

	# global variables
	if [ -z "$BACKGROUND_FETCH_PID" ]; then
		TMPFILE_FETCH_REQ=$(pm_mktemp FETCH_REQ)
		TMPFILE_FETCH_ACK=$(pm_mktemp FETCH_ACK)
		: > $TMPFILE_FETCH_REQ
		background_fetch $TMPFILE_FETCH_REQ $TMPFILE_FETCH_ACK &
		BACKGROUND_FETCH_PID=$!
	fi
	echo "$origin" >> $TMPFILE_FETCH_REQ
}

# OLD DISTFILES #### <se> should be called with origin_new !!! ???
list_old_distfiles () {
	local pkgname="$1"
	local dist_info_file line distfile_name

	[ -n "$DONT_SCRUB_DISTFILES" ] && return
	dist_info_file="$pdb/$pkgname/distfiles"
	while read line; do
pm_msg "$line"
		case $line in
		DISTFILE*)
			distfile_name=${line#*:}
			set_add DISTFILES_OLD ${line%%:*} ;; ### ???
		esac
	done < $dist_info_file
}

# install or upgrade named port
register_upgrade () {
	local origin_old="$1"
	local origin_new="$2"
	local pkgname_old="$3"
	local pkgname_new="$4"

	set_add UPGRADES "$origin_new"
	pm_msg "$RECURSIVE_MSG $origin_new"
	pm_msg

	[ -n "$pkgname_old" ] && pm_msg "===>>> Currently installed version: $pkgname_old"
	pm_msg "===>>> Port directory: $origin_new"
	pm_msg

	# register new package name and (old origin and package name, if applicable and changed)
	dict_set PKGNAME_NEW "$origin_new" "$pkgname_new"

	if [ -n "$origin_old" ]; then
		[ -n "$pkgname_old" ] || fail "ERROR no package name for port $origin_old"
		dict_set PKGNAME_OLD "$origin_new" "$pkgname_old"
		[ "$origin_old" != "$origin_new" ] &&
			dict_set ORIGIN_OLD "$origin_new" "$origin_old"
	fi
	# make config
	configure_port "$origin_new" $PM_FORCE_CONFIG
	if check_forbidden "$origin_new" && port_has_options "$origin_new"; then
		sleep 4
		pm_msg "===>>>	You may try to change the port options to allow this port to build"
		pm_msg
		configure_port "$origin_new" force
		if check_forbidden "$origin_new"; then
			pm_msg "===>>> If you are sure you can build this port, remove the"
			pm_msg "       $state line in the Makefile and try again."
			return 1
		fi
	fi

	# warn if port is interactive
	if port_is_interactive "$origin_new"; then
		local DISCARD
		pm_msg
		pm_msg "===>>>	Warning: $origin_new is interactive, and will likely"
		pm_msg "	require attention during the build"
		read_nl "===>>>	Press the [Enter] or [Return] key to continue "
		pm_msg
	fi

	# fetch and check distfiles in background
	####list_old_distfiles "$pkgname_old"
#set -x
if false; then	
	fetch_check_distfiles "$origin_new"
fi
#	local err_msg=$(fetch_check_distfiles "$origin_new") ||
#		fail "error fetching distfile for "$origin_new": $err_msg"
#set +x
	# add build dependencies (and stop if a dependency is missing)
	register_build_depends "$origin_new"

	# add to WORKLIST behind (!) the (recursive) build dependencies
	worklist_add "$origin_new"

	register_run_depends "$origin_new"
# ----------------------------------------------------------------------------------
# fetch+checksum distfiles (in background)
# check IS_INTERACTIVE / acknowledge
# make config (again???)
# recurse build-depends-list run-depends-list (run-depends only if build-depends installed from packages)
# check_fetch_only?
# post_first_pass
# NO_ACTION --> exit (on -n flag)
# --- start build ---
	return 0
}

# check what to do for given old and new origin and old package name
# check LOCKED/IGNOREME
register_update () {
	local build_type="$1"	# <se> CURRENTLY IGNORED: FIX!!!
	local origin_old="$2"
	local origin_new="$3"
	local pkgname_old="$4"
	local pkgname_new version_new version_new

pm_msg "REGISTER_UPDATE '$origin_old' '$origin_new' '$pkgname_old'"
	# expect to be called with at least eather an old package name or a new port origin
	[ -n "$origin_new" -o -n "$pkgname_old" ] ||
		fail "INTERNAL ERROR: register_new called with ($origin_old,$origin_new,$pkgname_old)"

	if [ -n "$origin_new" ]; then
		set_contains SEEN $origin_new && return
		set_add SEEN "$origin_new"
	fi

	[ -z "$pkgname_old" ] && pkgname_old=$(pkgdb_pkgname "$origin_old" "$origin_new")
	if [ -n "$pkgname_old" ]; then
		pkgdb_check_locked $pkgname_old && return 0
		check_exclude $pkgname_old && return 0
	fi

	[ -z "$origin_new" ] && register_delete "$pkgname_old"

	# skip if this port has already been processed
	set_contains UPGRADES "$origin_new" && return 0

	pkgname_new=$(origin_var "$origin_new" PKGNAME) ||
		fail "ERROR port $origin_new does not exist"

	if check_exclude "$pkgname_new" "$origin_new"; then
		add_skipped "$origin_new"
		return 1
	fi

	version_old=${pkgname_old##*-}
	version_new=${pkgname_new##*-}
	if [ "$version_old" = "$version_new" ]; then
		# no actual upgrade required, just changes to the package registry ...
		if [ "$origin_old" != "$origin_new" ]; then
			register_moved $origin_old $origin_new $pkgname_old || return $?
		fi
		if [ "$pkgname_old" != "$pkgname_new" ]; then 
			register_pkgname_chg $origin_new $pkgname_old $pkgname_new || return $?
		fi
		return 0
	else
		register_upgrade "$origin_old" "$origin_new" "$pkgname_old" "$pkgname_new"
	fi
}

# ----------------------------------------------------------------------------------
# verify that passed origin (with optional flavor) belonh to an installed package
origin_check_installed () {
	local name="$1"

	[ "$(echo $name)" = "${name%* }" ] || return 1
	local dir=$(dir_part "$name")
	local flavor=$(flavor_part "$name")
	local flavors f

	if [ -n "$flavor" ]; then
		flavors=$(pkg annotate -Sq "$dir" flavor)
		for f in ""$flavors; do
			[ "$flavor" = "$f" ] && return 0
		done
	fi
	[ "$(pkg query "%o" "$dir")" = "$dir" ]
}

# find old and new port origin and pkgname for passed port/pkg and optional new origin
add_one_port () {
set -x
	local build_type="$1"
	local origin_old="$2" # just a single origin, no glob allowed!!!
	local origin_new="$3"
	local pkgname_old="$4"
	local flavor

	# short-cut common case that this port is a repeated dependency
	if [ -n "$origin_new" ]; then
		set_contains SEEN $origin_new && return
	fi
	[ -n "$pkgname_old" -a -z "$origin_old" ] && origin_old=$(pkgdb_origin_flavor "pkgname_old")
	if [ -z "$origin_old" ]; then
		origin_old=$(origin_old_from_port "$origin_new") && \
						origin_check_installed "$origin_old" ||
		origin_old=$(pkgdb_origin_flavor "$origin_new") ||
		origin_old=$(origin_old_from_origin_new "$origin_new")
	fi
	if [ -n "$origin_new" ]; then
		case $origin_new in
		*@*)
			;; # keep passed-in flavor
		*)
			flavor=$(flavor_part $origin_old)
			[ -n "$flavor" ] && origin_new="$origin_new@$flavor" ;;
		esac
	else
		origin_new=$(origin_new_from_port "$origin_old")
	fi
		if conflicting_pkg=$(check_conflicts "$origin_new"); then
			# if this conflicting port was specifically requested by the user or it replaces
			# an automatic package then replace the conflicting package by the requested one
			if [ "$build_type" = user ] || pkgdb_check_automatic "$conflicting_pkg"; then
				# replace automatically installed package by new dependency
				origin_old=$(pkgdb_origin_flavor "$conflicting_pkg")
				###set_add SEEN "$origin_old" # <se> this would prevent later demand building of this port
				pm_msg ''
				pm_msg "===>>>	$conflicting_pkg will be deinstalled"
				pm_msg "	$origin_new will replace this conflicting package installed from $origin_old"
				pm_msg ''
				# removed conflicting port from worklist, if it has already been added
				worklist_remove "$origin_old"
				# sleep in case there will be a config screen for the new package
				sleep 4
			else
				# keep conflicting package which seems to be preferred by the user
				pm_msg ''
				pm_msg "===>>>	The dependency for $origin_new"
				origin_new=$(pkgdb_origin_flavor "$conflicting_pkg")
				pm_msg "	seems to be handled by $conflicting_pkg built from $origin_new"
				pm_msg ''
				origin_old=
			fi
		fi
	[ -z "$pkgname_old" ] && pkgname_old=$(pkgdb_pkgname "$origin_old" "$origin_new")
	[ -z "$origin_old" -a -n "$pkgname_old" ] && origin_old=$(pkgdb_origin_flavor "$pkgname_old") # actually user? <se>
set +x
	register_update "$build_type" "$origin_old" "$origin_new" "$pkgname_old"
}

# add the one port identified by the installed package name to the worklist
add_one_pkg () {
	add_one_port auto $(pkgdb_origin_flavor "$1") "$2" $1
}

# expand passed in pkgname or port glob (port glob with optional flavor)
add_with_globbing () {
	local dir_glob=$(dir_part "$1")
	local flavor=$(flavor_part "$1")
	local origin_new="${2:-}"
	local matches origin_old

	# first try to find installed packages matching the glob pattern
	matches=$(pkg query -g "%n-%v" "$dir_glob") || true
	if [ -n "$matches" ]; then
	        for name in $matches; do
			add_one_pkg "$name" $origin_new
		done
		return
	fi
	# then try parameter as port directory or origin of uninstalled port(s)
	matches=""
	for origin_new in $(origin_from_dir "$1"); do
#set -x
		add_one_port user "" $origin_new && matches="$matches $new_origin"
#set +x
	done
	[ -n "$matches" ] && return 0
	return 1
}

# add installed package or all ports for the given origin (with optional flavor)
add_ports_matching () {
	local name="$1"
	local origin_new="$2"
	local matched

	matched=0
	# first try to find installed packages matching "$name"
	for origin_old in $(pkgdb_origins_flavor "$name"); do
		add_one_port auto "$origin_old" $origin_new && matched=1
	done
	[ "$matched" = 1 ] && return

	# else try to find ports matching "$name"
	for origin_old in $(origin_old_from_port "$name"); do
		add_one_port user "$origin_old" $origin_new && matched=1
	done

	[ "$matched" = 1 ] || fail "Could not find package or port matching $name"
}

# add all matching ports identified by pkgnames and/or portnames with optional flavor
add_multiple_ports () {
	local name_glob name

	for name_glob in "$@"; do
		add_with_globbing "$name_glob"
	done
}

add_all_outdated () {
	local pkgname_old origin_old flavor origin_new

	while read pkgname_old origin_old; do
		flavor=$(pkgdb_flavors $pkgname_old)
		[ -n "$flavor" ] && origin_old="$origin_old@$flavor"
		origin_new=$(origin_new_from_port "$origin_old")
		register_update user "$origin_old" "$origin_new" "$pkgname_old"
	done <<-EOF
	$(all_pkgs_by_origin "%a=0")
	EOF
return
	while read pkgname_old origin_old; do
		flavor=$(pkgdb_flavors $pkgname_old)
		[ -n "$flavor" ] && origin_old="$origin_old@$flavor"
		origin_new=$(origin_new_from_port "$origin_old")
		register_update auto "$origin_old" "$origin_new" "$pkgname_old"
	done <<-EOF
	$(all_pkgs_by_origin "%a=1")
	EOF
}

prepare_tasks () {
	:
} 

# ----------------------------------------------------------------------------------
# display actions that will be performed

show_tasks () {
	local pkgname_old origin_new num_deletes num_renames num_installs num_upgrades
	local deletes moves pkg_renames

	deletes=$(set_print DELETES)
	moves=$(set_print MOVES)
	pkg_renames=$(set_print PKG_RENAMES)

	if [ -z "$deletes$moves$pkg_renames$WORKLIST" ]; then
		pm_msg
		pm_msg "No upgrades required"
		return 0
	fi

	pm_msg
	pm_msg "The following actions are required to perform the requested upgrade:"
	pm_msg

	# delete obsolete packages
	num_deletes=0
	for pkgname_old in $(set_print DELETES); do
		pm_msg "	De-install $pkgname_old"
		num_deletes=$((num_deletes + 1))
	done

	num_renames=0
	# register new port origins (must come before package renames, if any)
	for origin_new in $(set_print MOVES); do
		local origin_old=$(dict_get ORIGIN_OLD $origin_new)
		local pkgname_old=$(dict_get PKGNAME_OLD $origin_new)
		pm_msg "	Change origin of $pkgname_old from $origin_old to $origin_new"
		num_renames=$((num_renames + 1))
	done
	# rename package in registry and/or repository
	for origin_new in $(set_print PKG_RENAMES); do
		local pkgname_old=$(dict_get PKGNAME_OLD $origin_new)
		local pkgname_new=$(dict_get PKGNAME_NEW $origin_new)
		pm_msg "	Rename installed package $pkgname_old to $pkgname_new"
		num_renames=$((num_renames + 1))
	done

	num_installs=0
	num_upgrades=0
	# install or upgrade required packages
	for origin_new in $WORKLIST; do
		local origin_old=$(dict_get ORIGIN_OLD $origin_new)
		local pkgname_old=$(dict_get PKGNAME_OLD $origin_new)
		local pkgname_new=$(dict_get PKGNAME_NEW $origin_new)
		[ -z "$origin_old" -a -n "$pkgname_old" ] && origin_old="$origin_new"

		case $origin_old in
		"")
			pm_msg "	Install $pkgname_new from $origin_new"
			num_installs=$((num_installs + 1)) ;;
		$origin_new)
			pm_msg "	Upgrade $pkgname_old to $pkgname_new"
			num_upgrades=$((num_upgrades + 1)) ;;
		*)
			pm_msg "	Upgrade $pkgname_old to $pkgname_new (origin changed from $origin_old to $origin_new)"
			num_upgrades=$((num_upgrades + 1));;
		esac
	done

	if [ $((num_deletes + num_renames + num_upgrades)) -gt 0 ]; then
		pm_msg
		[ $num_installs -eq 1 ] && pm_msg "1 package will be installed"
		[ $num_installs -gt 1 ] && pm_msg "$num_installs packages will be installed"
		[ $num_upgrades -eq 1 ] && pm_msg "1 package will be upgraded"
		[ $num_upgrades -gt 1 ] && pm_msg "$num_upgrades packages will be upgraded"
		[ $num_renames  -eq 1 ] && pm_msg "1 package will receive changes in the package DB"
		[ $num_renames  -gt 1 ] && pm_msg "$num_renames packages will receive changes in the package DB"
		[ $num_deletes  -eq 1 ] && pm_msg "1 package will be deleted"
		[ $num_deletes  -gt 1 ] && pm_msg "$num_deletes packages will be deleted"
		pm_msg
	fi
}

# ----------------------------------------------------------------------------------
# register new origin in package registry (must be performed before package rename, if any)
pkgdb_set_origin () {
	local origin_new="$1"
	local origin_old="$2"
	local pkgname="$3"
	
	pm_msg "===>>>	Change origin of $pkgname from $origin_old to $origin_new"
echo 	pkg set --change-origin "$origin_old:$origin_new" "$pkgname" ||
		fail "could not set origin to $origin:_new in $pkgname"
}

#
perform_origin_change () {
	local origin_new="$1"
	local origin_old pkgname_old

	origin_old=$(dict_get ORIGIN_OLD $origin_new)
	pkgname_old=$(dict_get PKGNAME_OLD $origin_new)
	pkgdb_set_origin $origin_new $origin_old $pkgname_old
}

# rename package in package DB
pkgdb_set_pkgname () {
	local pkgname_new="$1"
	local pkgname_old="$2"

	pm_msg "===>>>	Rename installed package $pkgname_old to $pkgname_new"
echo	pkg set --change-name "$pkgname_old:$pkgname_new" "$pkgname_old" ||
		fail "could not update package name from $pkgname_old to $pkgname_new in packsage DB"
}

# rename package files (including package backups)
pkgfiles_rename () {
	:
}

# rename package in package DBN and stored package files
perform_pkg_rename () {
	local origin_new="$1"
	local pkgname_old pkgname_new

	pkgname_old=$(dict_get PKGNAME_OLD $origin_new)
	pkgname_new=$(dict_get PKGNAME_NEW $origin_new)
	pkgdb_set_pkgname "$pkgname_new" "$pkgname_old" || fail "could not update package name in packsage DB"
	pkgfiles_rename "$pkgname_new" "$pkgname_old"
}

# deinstall package
perform_pkg_deinstall () {
	local pkgname="$1"

	pm_msg "===>>>	De-install $pkgname_old"
echo	pkg delete -f "$pkgname" || fail "cannot delete package $pkgname"
}

#
perform_install_or_upgrade () {
	local origin_new="$1"
	local origin_old pkgname_old pkgname_new

	origin_old=$(dict_get ORIGIN_OLD $origin_new)
	pkgname_old=$(dict_get PKGNAME_OLD $origin_new)
	pkgname_new=$(dict_get PKGNAME_NEW $origin_new)
	[ -z "$origin_old" -a -n "$pkgname_old" ] && origin_old="$origin_new"

	case $origin_old in
	"")
		pm_msg "===>>>	Install $pkgname_new from $origin_new" ;;
	$origin_new)
		pm_msg "===>>>	Upgrade $pkgname_old to $pkgname_new" ;;
	*)
		pm_msg "===>>>	Upgrade $pkgname_old to $pkgname_new (origin changed from $origin_old to $origin_new)" ;;
	esac

if false; then
	# check for special license and ask user to accept it (may contain make extract/patch)
	check_license "$origin" || return 1
# ALTERNATIVELY INSTALL FROM PACKAGE
	# extract and patch the port and all special build dependencies ($make_target=extract/patch)
	local special_depends=$(dict_get SPECIAL_DEPENDS "$origin_new")
	port_extract "$origin_new" $special_depends

	# build and stage port
	port_build_stage "$origin_new"

	local automatic
	if [ -n "$pkgname_old" ]; then
		# link (with cpio -pmdl) all paxckage files in case of install failure
		[] && preserve_packagefiles

		# create backup package file from installed files // <se> check name of control variable
		[ -z "$NO_BACKUPS" ] && package_backup "$pkgname_old"

		# preserve currently installed shared libraries // <se> check name of control variable
		[ -n "$SAVE_SHARED" ] && shlibs_backup "$pkgname_old"

		# delete old distfiles
		[] && delete_old_distfiles "$pkgname_old" "$origin_new"

		# preserve auto-install state
		automatic=$(pkg query "%A" "$pkgname_old")

		# delete old package
		package_deinstall "$pkgname_old"
	fi
	if port_install "$origin_new" $automatic; then
		# remove hard-linked / preserved files after successful installation of new port
	else
		# ALTERNATIVE recover from hard-linked / preserved files
		port_deinstall "$new_origin"
		package_recover "$pkgname_old"
	fi
	# remove from shlib backup directory all shared libraries replaced by new versions
	shlibs_remove_stale_backups $XXX

	# preserve file names and hashes of distfiles from new port
	update_distinfo_cache "$origin_new" "$pkgname_new"

	# create package file from staging area
	package_create "$origin_new" "$pkgname_new"

	# backup clean port directory and special build depends (might also be delayed to just before program exit)
	port_clean "$origin_new" $special_depends

	# update pkg registry to new origin and package name
	pkgdb_update_dependencies "$pkgname_old" "$pkgname_new"

	# delete stale distfiles in the background
	distfiles_delete_stale $YYY

	# record and report success
	pm_msg "===>>>	install/upgrade of $pkname_new has been successfully completed"
	pm_msg
fi
				
}

perform_tasks () {
	local pkgname_old origin_new

	# delete obsolete packages
	for pkgname_old in $(set_print DELETES); do
		perform_pkg_deinstall "$pkgname_old"
	done
	# register new port origins (must come before package renames, if any)
	for origin_new in $(set_print MOVES); do
		perform_origin_change "$origin_new"
	done
	# rename package in registry and repitory
	for origin_new in $(set_print PKG_RENAMES); do
		perform_pkg_rename "$origin_new"
	done
	# install or upgrade required packages
	for origin_new in $WORKLIST; do
		perform_install_or_upgrade "$origin_new"
	done
}

#
# fetch package
#

if [ -n "$REPLACE_ORIGIN" ]; then
	[ "$#" -eq 1 ] || fail "Exactly one port or packages required with -o"
	add_ports_matching "$1" "$REPLACE_ORIGIN"
elif [ -n "$UPDATE_ALL" ]; then
	add_all_outdated
else
	add_multiple_ports "$@"
fi

# empty line is "end of input" signal for background distfile checksum process
[ -f "$TMPFILE_FETCH_REQ" ] && echo > "$TMPFILE_FETCH_REQ"

# ----------------------------------------------------------------------------------
#
prepare_tasks
show_tasks
#read_yn y "Perform these upgrades now?"
perform_tasks
