#!/bin/sh

# load helpers
source ${0%/*}/hlp.sh

# stricter scripting env: switches that turn some bugs into errors
set -o errexit
set -o pipefail
# set -o noclobber, so bash does not overwrite with >, >> or <>
set -o nounset

# -allow a command to fail with !’s side effect on errexit
# -use return value from ${PIPESTATUS[0]}, because ! hosed $?
! getopt --test > /dev/null
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
    echo 'I’m sorry, `getopt --test` failed in this environment.'
    exit 1
fi

# basic input
declare -a gts                  # genotype (multiple)
idv=                            # individual ID filter
out=                            # output
bat=
wrk=                            # working directory
vbs=                            # verbose?
erase=                          # erase existing files?
retain=n                        # retain temp files?

SOPT=i:g:b:o:evc
LOPT=idv:,gen:,batchsize:,out:,workdir,erase,verbose,retain

# -regarding ! and PIPESTATUS see above
# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly
! PARSED=$(getopt --options=$SOPT --longoptions=$LOPT --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    # e.g. return value  is 1, then getopt has complained  about wrong arguments
    #  to stdout
    exit 2
fi

# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

# now enjoy the options in order and nicely split until we see --
echo "$0: parsing command line:"
while true; do
    # echo "$1 $2"
    case "$1" in
        -g|--gen)          s=2; gts+=("$2") ;;
        -i|--idv)          s=2; idv="$2" ;;
        -o|--out)          s=2; out="$2" ;;
        -b|--bat)          s=2; bat="$2" ;;
        -e|--erase)        s=1; erase=y  ;;
        -v|--verbose)      s=1; vbs=1 ;;
        --retain)          s=1; retain=y ;;
        --)                shift; break ;;
        * ) echo "$0: unrecognized option \"$1\""; exit 3 ;;
    esac
    echo -n "  $1"
    [ $s -ge 2 ] && echo -n " $2"
    shift $s
    echo
done
# display unused arguments:
echo "  -- $@"; HR


# work

## gather genotype words
ngt=${#gts[@]}                  # number of words
[ $ngt -gt 0 ] || (echo "$0: need at least one genotype via -g|--gen." >&2; exit 4)
[ $vbs ] && echo "$0: $ngt genotype term(s) specified:"
[ $vbs ] && (for _ in ${gts[@]}; do echo '  '$_; done; HR)

## make directories
[ $vbs ] && echo "$0: create directory"
[ -z "$out" ] && out="."
mkdir -m0775 -p $out
[ $vbs ] && echo "  out=$out"
[ -z "$wrk" ] && wrk="${out:-.}/wrk"
mkdir -m0775 -p $wrk
[ $vbs ] && (echo "  wrk=$wrk"; HR)

## locate genotype files
for i in $(seq 0 $[$ngt-1]); do
    ! eval ls ${gts[$i]}.{bed,pgen} 2>/dev/null
done | sed -r 's/[.](bed|pgen)$//' | sort -u > "$wrk/gls"
ngt=$(cat "$wrk/gls" | wc -l)
[ $ngt -gt 0 ] || (echo "$0: found no genotype file" >$2; exit 4)
[ $vbs ] && echo "$0: $ngt genotype found (see $wrk/gls):"
[ $vbs ] && (peek "$wrk/gls" 3 "  "; HR)

## genotyped individuals
[ $vbs ] && echo "$0: gather individuals appeared in all genotype:"
if [ -s "$wrk/gid" ]; then      # exist/erase?
    s=$([ $erase ] && echo ERASE || echo EXIST)
else
    s=CREATE                    # or new?
fi
if [ $s = ERASE -o $s = CREATE ]; then
    # get both fid and iid
    while IFS= read -r g; do
        if   [ -f "$g.fam"  ]; then awk <"$g.fam"  '{print $1,$2}'
        elif [ -f "$g.psam" ]; then awk <"$g.psam" '{print $1,$2}'
        else
            echo "$0: can not locate \"$g.fam\" or \"$g.pasm\"" &>2
            exit 4
        fi
    done < "$wrk/gls" | sort | uniq -c \
        | awk -v m=$ngt '$1==m {print $2,$3}' > "$wrk/bid"
    # get genotyped iid
    awk <"$wrk/bid" '{print $2}' | sort > "$wrk/gid"
    r=$?
else
    r=PASS
fi
[ $vbs ] && echo "$s $r $wrk/gid"     # report, exit on error
[ $r = "0" ] || [ $r = PASS ] || exit $r

ind=$(cat "$wrk/gid" | wc -l)   # report
[ $vbs ] && peek "$wrk/gid" 3 "  "
[ $vbs ] && (echo "N=$ind genotyed individual gathered in \"$wrk/gid\"."; HR)

## individual discription
if [ "$idv" ]; then
    [ $vbs ] && echo "$0: check individuals in \"$idv\" (--idv|-i):"
    [ -f "$idv" ] || (echo "$0: \"$idv\" is not a file!" &>2; exit 4)

    if [ -s "$wrk/iid" ]; then
        s=$([ $erase ] && echo ERASE || echo EXIST)
    else
        s=CREATE
    fi

    if [ $s = ERASE -o $s = CREATE ]; then
        [ $vbs ] && echo "$0: sort idv spec by IID (1st column)"
        sort -k1,1 -u "$idv" > "$wrk/idv.srt"
        r=$?; [ ! $r -eq 0 ] && echo ERR: $r && exit $r

        [ $vbs ] && echo "$0: join idv spec with genotyped IID"
        join "$wrk/idv.srt" "$wrk/gid" > "$wrk/idv.jnt"
        r=$?; [ ! $r -eq 0 ] && echo ERR: $r && exit $r

        [ $vbs ] && echo "$0: sort idv spec for distribution"
        col=$(head -n 1 "$wrk/idv.jnt" | wc -w) # number of column
        if [ $col -gt 1 ]; then
            sort <"$wrk/idv.jnt" -k2,$col >"$wrk/iid"
        else
            cp "$wrk/idv.jnt" "$wrk/iid"
        fi
        r=$?; [ ! $r -eq 0 ] && echo ERR: $r && exit $r
    else
        r=PASS
    fi
else
    [ $vbs ] && echo -n "$0: no individual specified (--idv|i), "
    [ $vbs ] && echo    "copy \"wrk/gid\" to \"wrk/iid".
    s=COPY
    cp "$wrk/gid" "$wrk/iid"
fi
ind=$(cat "$wrk/iid" | wc -l)       # final number of individuals
[ $vbs ] && echo "$s $r $wrk/iid"
[ $vbs ] && peek "$wrk/iid" 3 "  "
[ $vbs ] && echo "N=$ind final individuals retained in \"$wrk/iid\"." && HR


## batches
[ $vbs ] && echo -n "$0: batch division syntax"
if [ -z $bat ]; then
    bat=4
    [ $vbs ] && echo " unspecified, use \"--bat|-b 4\""
else
    [ $vbs ] && echo ": \"$bat\""
fi

val=${bat#*[/=]}                # value
bat=${bat%%[/=0-9]*}            # type: number, size, or none
if   [ "$bat" = n -o -z "$bat" ]; then
    nbt=$val;                   # number by n={} or {}
elif [ "$bat" = s ]; then
    nbt=$[$ind/$val];           # size by s={}
else
    echo "$0: unrecognized batch syntax \"$bat\""  >&2
    exit 4
fi
bsz=$[$ind/$nbt]                # recalculate batch size
[ $vbs ] && echo "$0: batch = $nbt, size ~ $bsz" && HR
exit 0

## restore fid and iid
[ $vbs ] && "$0: restore fid and iid pairs:"
join <$wrk/{bid,iid}
sort -R "$wrk/iid" | awk '{print $1,$1}'> "$wrk/cid"
echo "$wrk/cid": $_n shuffled FID and IID saved.
[ $vbs ] && peek "$wrk/cid"
echo



# batch division, also get the number of batches
echo MSG: divide $_n IID into batches of $bsz each
_q=$[ $_n / $bsz ]
if [ -d "$wrk/div" ] && \
       [ $(find "$wrk/div" -name "*.cid" | wc -l) -eq $_q ] && \
       [ $(cat "$wrk/div/"*.cid | wc -l) -eq $_n ]; then
    s=$([ $erase ] && echo ERASE || echo EXIST)
else
    mkdir -p "$wrk/div"
    s=CREATE                    # or new?
fi
if [ $s = CREATE -o $s = ERASE ]; then
    split -n l/$_q -d -a3 "$wrk/cid" "$wrk/div/" --additional-suffix ".cid"
    r=$?
else
    r=PASS
fi
echo "$s    $r    $wrk/div"
[ $r = "0" -o $r = PASS ] || exit $r
echo "$wrk/div/": $_q batches
wc -l "$wrk/div"/*.cid | head -n-1 | awk '{print $1,$2}' > "$wrk/bsz"
[ $vbs ] && peek "$wrk/bsz"
echo


echo "MSG: divide genotype accordingly"
while IFS= read -r f            # genotype files
do
    g=${f//[ \/]/_}             # genotype id
    t="$wrk/div/gno.$g"          # genotype extract
    echo GNO: $f $t
    if [ -s "$t.bed" -a -s "$t.bim" -a -s "$t.fam" ]; then
        s=$([ $erase ] && echo ERASE || echo EXIST)
    else
        s=CREAT; fi
    
    if [ $s = ERASE -o $s = CREAT ]; then
        plink --bfile "$f" --keep "$wrk/cid" --keep-allele-order \
          --make-bed --out "$t" &> /dev/null
        r=$?
    else
        r=PASS; fi
    echo "$s    $r    $t"   # report, exit on error
    [ $r = "0" ] || [ $r = PASS ] || exit $r

    # divide the extracted genotype
    for b in "$wrk/div/"*.cid    # batch numbers
    do
        o="${b%.cid}.${g}"
        if [ -s "$o.bed" -a -s "$o.bim" -a -s "$o.fam" ]
        then
            s=$([ $erase ] && echo ERASE || echo EXIST)
        else
            s=CREAT
        fi

        # commence batch extraction?
        r=PASS
        if [ $s = ERASE -o $s = CREAT ]; then
            # preserve allele ordering
            plink --bfile "$t" --keep "$b" --keep-allele-order \
                  --make-bed --out "$o" &> /dev/null
            r=${PIPESTATUS[0]}
        fi
        echo "$s    $r    $o"   # report, exit on error
        [ $r = "0" ] || [ $r = PASS ] || exit $r
    done
    # rm "$t".*                   # remove extract
done < "$wrk/gls"
echo


# merge into one genome for each batch
echo MSG: merge genotype genome-wise:
for b in $(seq -w 000 $[$_q-1])
do
    o="$out"/$b
    for f in "$wrk/div/"$b.*.bed
    do
        echo ${f%.bed}
    done > "$o.lst"

    pass=n
    if [ -s "$o.bed" -a -s "$o.bim" -a -s "$o.fam" ]
    then
        if [ -z $erase ]
        then
            echo -ne EXIST\\t
            pass=y
        else
            echo -ne ERASE\\t
        fi
    else
        echo -ne CREAT\\t
    fi

    # do not pass the batch extraction
    if [ $pass = y ]
    then
        echo -ne PASS\\t
    else
        plink --merge-list "$o.lst" --keep-allele-order --make-bed --out "$o" \
            &>/dev/null
        echo -ne $?\\t
    fi
    echo "$o"
done
echo "result is written to" "$out"


# reaching this point, the sample division is successful,
# therefore we can safely delete intermediate files.
if [ $retain = y ]
then
    [ $vbs ] && echo MSG: "$wrk" - retained.
else
    [ $vbs ] && echo MSG: "$wrk" - clean up.
    rm -rf "$wrk" "$out"/*.{log,lst}
fi
