#!/bin/sh
#
# Copyright (c) 2017 Josh Hunsaker
# Copyright (c) 2005 Junio C Hamano
#
# Fetch one or more remote refs and merge it/them into the current HEAD.

cmdname=pull; CmdName=Pull; CMDNAME=PULL
USAGE='[-n | --no-stat] [--[no-]commit] [--[no-]squash] [--[no-]ff] [-s strategy]... [<fetch-options>] <repo> <head>...'
LONG_USAGE='Fetch one or more remote refs and merge it/them into the current HEAD.'
SUBDIRECTORY_OK=Yes
OPTIONS_SPEC=
. git-sh-setup
set_reflog_action "${cmdname}${1+ $*}"
require_work_tree
cd_to_toplevel


die_conflict () {
    git diff-index --cached --name-status -r --ignore-submodules HEAD --
    if [ $(git config --bool --get advice.resolveConflict || echo true) = "true" ]; then
	die "$CmdName is not possible because you have unmerged files.
Please, fix them up in the work tree, and then use 'git add/rm <file>'
as appropriate to mark resolution, or use 'git commit -a'."
    else
	die "$CmdName is not possible because you have unmerged files."
    fi
}

die_merge () {
    if [ $(git config --bool --get advice.resolveConflict || echo true) = "true" ]; then
	die "You have not concluded your merge (MERGE_HEAD exists).
Please, commit your changes before you can merge."
    else
	die "You have not concluded your merge (MERGE_HEAD exists)."
    fi
}

test -z "$(git ls-files -u)" || die_conflict
test -f "$GIT_DIR/MERGE_HEAD" && die_merge

bool_or_string_config () {
	git config --bool "$1" 2>/dev/null || git config "$1"
}

strategy_args= diffstat= no_commit= squash= no_ff= ff_only=
log_arg= verbosity= progress= recurse_submodules= verify_signatures=
merge_args= edit= rebase_args= all= append= upload_pack= force= tags= prune=
keep= depth= unshallow= update_shallow= refmap=
curr_branch=$(git symbolic-ref -q HEAD)
curr_branch_short="${curr_branch#refs/heads/}"
rebase=$(bool_or_string_config branch.$curr_branch_short.rebase)
if test -z "$rebase"
then
	rebase=$(bool_or_string_config pull.rebase)
fi

# Setup default fast-forward options via `pull.ff`
pull_ff=$(bool_or_string_config pull.ff)
case "$pull_ff" in
true)
	no_ff=--ff
	;;
false)
	no_ff=--no-ff
	;;
only)
	ff_only=--ff-only
	;;
esac


dry_run=
while :
do
	case "$1" in
	-q|--quiet)
		verbosity="$verbosity -q" ;;
	-v|--verbose)
		verbosity="$verbosity -v" ;;
	--progress)
		progress=--progress ;;
	--no-progress)
		progress=--no-progress ;;
	-n|--no-stat|--no-summary)
		diffstat=--no-stat ;;
	--stat|--summary)
		diffstat=--stat ;;
	--log|--log=*|--no-log)
		log_arg="$1" ;;
	--no-commit)
		no_commit=--no-commit ;;
	--commit)
		no_commit=--commit ;;
	-e|--edit)
		edit=--edit ;;
	--no-edit)
		edit=--no-edit ;;
	--squash)
		squash=--squash ;;
	--no-squash)
		squash=--no-squash ;;
	--ff)
		no_ff=--ff ;;
	--no-ff)
		no_ff=--no-ff ;;
	--ff-only)
		ff_only=--ff-only ;;
	-s*|--strategy=*)
		strategy_args="$strategy_args $1"
		;;
	-X*|--strategy-option=*)
		merge_args="$merge_args $(git rev-parse --sq-quote "$1")"
		;;
	-r*|--rebase=*)
		rebase="${1#*=}"
		;;
	--rebase)
		rebase=true
		;;
	--no-rebase)
		rebase=false
		;;
	--recurse-submodules)
		recurse_submodules=--recurse-submodules
		;;
	--recurse-submodules=*)
		recurse_submodules="$1"
		;;
	--no-recurse-submodules)
		recurse_submodules=--no-recurse-submodules
		;;
	--verify-signatures)
		verify_signatures=--verify-signatures
		;;
	--no-verify-signatures)
		verify_signatures=--no-verify-signatures
		;;
	--gpg-sign|-S)
		gpg_sign_args=-S
		;;
	--gpg-sign=*)
		gpg_sign_args=$(git rev-parse --sq-quote "-S${1#--gpg-sign=}")
		;;
	-S*)
		gpg_sign_args=$(git rev-parse --sq-quote "$1")
		;;
	--dry-run)
		dry_run=--dry-run
		;;
	--all|--no-all)
		all=$1 ;;
	-a|--append|--no-append)
		append=$1 ;;
	--upload-pack=*|--no-upload-pack)
		upload_pack=$1 ;;
	-f|--force|--no-force)
		force="$force $1" ;;
	-t|--tags|--no-tags)
		tags=$1 ;;
	-p|--prune|--no-prune)
		prune=$1 ;;
	-k|--keep|--no-keep)
		keep=$1 ;;
	--depth=*|--no-depth)
		depth=$1 ;;
	--unshallow|--no-unshallow)
		unshallow=$1 ;;
	--update-shallow|--no-update-shallow)
		update_shallow=$1 ;;
	--refmap=*|--no-refmap)
		refmap=$1 ;;
	-h|--help-all)
		usage
		;;
	*)
		# Pass thru anything that may be meant for fetch.
		break
		;;
	esac
	shift
done

case "$rebase" in
preserve)
	rebase=true
	rebase_args=--preserve-merges
	;;
true|false|'')
	;;
*)
	echo "Invalid value for --rebase, should be true, false, or preserve"
	usage
	exit 1
	;;
esac

error_on_no_merge_candidates () {
	exec >&2

	if test true = "$rebase"
	then
		op_type=rebase
		op_prep=against
	else
		op_type=merge
		op_prep=with
	fi

	upstream=$(git config "branch.$curr_branch_short.merge")
	remote=$(git config "branch.$curr_branch_short.remote")

	if [ $# -gt 1 ]; then
		if [ "$rebase" = true ]; then
			printf "There is no candidate for rebasing against "
		else
			printf "There are no candidates for merging "
		fi
		echo "among the refs that you just fetched."
		echo "Generally this means that you provided a wildcard refspec which had no"
		echo "matches on the remote end."
	elif [ $# -gt 0 ] && [ "$1" != "$remote" ]; then
		echo "You asked to pull from the remote '$1', but did not specify"
		echo "a branch. Because this is not the default configured remote"
		echo "for your current branch, you must specify a branch on the command line."
	elif [ -z "$curr_branch" -o -z "$upstream" ]; then
		. git-parse-remote
		error_on_missing_default_upstream "pull" $op_type $op_prep \
			"git pull <remote> <branch>"
	else
		echo "Your configuration specifies to $op_type $op_prep the ref '${upstream#refs/heads/}'"
		echo "from the remote, but no such ref was fetched."
	fi
	exit 1
}

test true = "$rebase" && {
	if ! git rev-parse -q --verify HEAD >/dev/null
	then
		# On an unborn branch
		if test -f "$(git rev-parse --git-path index)"
		then
			die "updating an unborn branch with changes added to the index"
		fi
	else
		require_clean_work_tree "pull with rebase" "Please commit or stash them."
	fi
	oldremoteref= &&
	test -n "$curr_branch" &&
	. git-parse-remote &&
	remoteref="$(get_remote_merge_branch "$@" 2>/dev/null)" &&
	oldremoteref="$(git rev-parse -q --verify "$remoteref")" &&
	for reflog in $(git rev-list -g $remoteref 2>/dev/null)
	do
		if test "$reflog" = "$(git merge-base $reflog $curr_branch)"
		then
			oldremoteref="$reflog"
			break
		fi
	done
}
orig_head=$(git rev-parse -q --verify HEAD)
git fetch $verbosity $progress $dry_run $recurse_submodules $all $append \
${upload_pack:+"$upload_pack"} $force $tags $prune $keep $depth $unshallow $update_shallow \
$refmap --update-head-ok "$@" || exit 1
test -z "$dry_run" || exit 0

curr_head=$(git rev-parse -q --verify HEAD)
if test -n "$orig_head" && test "$curr_head" != "$orig_head"
then
	# The fetch involved updating the current branch.

	# The working tree and the index file is still based on the
	# $orig_head commit, but we are merging into $curr_head.
	# First update the working tree to match $curr_head.

	echo >&2 "Warning: fetch updated the current branch head."
	echo >&2 "Warning: fast-forwarding your working tree from"
	echo >&2 "Warning: commit $orig_head."
	git update-index -q --refresh
	git read-tree -u -m "$orig_head" "$curr_head" ||
		die 'Cannot fast-forward your working tree.
After making sure that you saved anything precious from
$ git diff '$orig_head'
output, run
$ git reset --hard
to recover.'

fi

merge_head=$(sed -e '/	not-for-merge	/d' \
	-e 's/	.*//' "$GIT_DIR"/FETCH_HEAD | \
	tr '\012' ' ')

case "$merge_head" in
'')
	error_on_no_merge_candidates "$@"
	;;
?*' '?*)
	if test -z "$orig_head"
	then
		die "Cannot merge multiple branches into empty head"
	fi
	if test true = "$rebase"
	then
		die "Cannot rebase onto multiple branches"
	fi
	;;
esac

# Pulling into unborn branch: a shorthand for branching off
# FETCH_HEAD, for lazy typers.
if test -z "$orig_head"
then
	# Two-way merge: we claim the index is based on an empty tree,
	# and try to fast-forward to HEAD.  This ensures we will not
	# lose index/worktree changes that the user already made on
	# the unborn branch.
	empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
	git read-tree -m -u $empty_tree $merge_head &&
	git update-ref -m "initial pull" HEAD $merge_head "$curr_head"
	exit
fi

if test true = "$rebase"
then
	o=$(git show-branch --merge-base $curr_branch $merge_head $oldremoteref)
	if test "$oldremoteref" = "$o"
	then
		unset oldremoteref
	fi
fi

case "$rebase" in
true)
	eval="git-rebase $diffstat $strategy_args $merge_args $rebase_args $verbosity"
	eval="$eval $gpg_sign_args"
	eval="$eval --onto $merge_head ${oldremoteref:-$merge_head}"
	;;
*)
	eval="git-merge $diffstat $no_commit $verify_signatures $edit $squash $no_ff $ff_only"
	eval="$eval $log_arg $strategy_args $merge_args $verbosity $progress"
	eval="$eval $gpg_sign_args"
	eval="$eval FETCH_HEAD"
	;;
esac
eval "exec $eval"
